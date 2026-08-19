import Foundation
import CoreAudio
import BetterCastSenderSupport

enum ProcessAudioTapCaptureError: LocalizedError {
    case unsupportedOS
    case noMatchingAudioApplication([String])
    case createTapFailed(OSStatus)
    case readTapFormatFailed(OSStatus)
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startDeviceFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Process audio capture requires macOS 14.2 or newer"
        case .noMatchingAudioApplication(let applicationIDs):
            return "No active audio process matched \(applicationIDs.joined(separator: ", "))"
        case .createTapFailed(let status):
            return "Unable to create process audio tap (\(status))"
        case .readTapFormatFailed(let status):
            return "Unable to read process audio tap format (\(status))"
        case .createAggregateFailed(let status):
            return "Unable to create private process audio aggregate device (\(status))"
        case .createIOProcFailed(let status):
            return "Unable to create process audio IO callback (\(status))"
        case .startDeviceFailed(let status):
            return "Unable to start process audio capture device (\(status))"
        }
    }
}

/// Captures and optionally mutes audio from selected macOS processes using Core Audio process taps.
///
/// ScreenCaptureKit can copy system audio, but Core Audio taps can mute selected
/// applications while still delivering their samples to a receiver.
final class ProcessAudioTapCapture {
    typealias AudioHandler = (UnsafePointer<AudioBufferList>, AudioStreamBasicDescription, AudioTimeStamp) -> Void

    private let targetApplicationIDs: Set<String>
    private let muteProcess: Bool
    private let audioHandler: AudioHandler
    private let queue = DispatchQueue(label: "com.bettercast.process-audio-tap", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var streamFormat = AudioStreamBasicDescription()
    private var isRunning = false
    private var capturedProcessIDs: Set<AudioObjectID> = []
    private var observedReplacementProcessIDs: Set<AudioObjectID>?
    private var replacementObservationCount = 0

    /// Application IDs are stable, user-facing identities produced by
    /// `AudioApplicationCatalog`. The catalog resolves each identity back to
    /// the current Core Audio process objects, including helper processes.
    init(applicationIDs: Set<String>, muteProcess: Bool, audioHandler: @escaping AudioHandler) {
        self.targetApplicationIDs = applicationIDs
        self.muteProcess = muteProcess
        self.audioHandler = audioHandler
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else {
            throw ProcessAudioTapCaptureError.unsupportedOS
        }

        let processIDs = try AudioApplicationCatalog.processObjectIDs(
            matchingApplicationIDs: targetApplicationIDs
        )
        guard !processIDs.isEmpty else {
            throw ProcessAudioTapCaptureError.noMatchingAudioApplication(targetApplicationIDs.sorted())
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapDescription.name = "Screen Bridge App Audio"
        tapDescription.isPrivate = true
        // `.mutedWhenTapped` is fail-safe: selected apps are local-muted while
        // this aggregate device is actively reading, then return to the Mac if
        // capture stops unexpectedly.
        tapDescription.muteBehavior = muteProcess ? .mutedWhenTapped : .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            throw ProcessAudioTapCaptureError.createTapFailed(status)
        }
        tapID = newTapID

        do {
            streamFormat = try Self.readTapFormat(tapID: tapID)
            aggregateDeviceID = try Self.createAggregateDevice(for: tapDescription)
            try createAndStartIOProc()
            isRunning = true
            capturedProcessIDs = Set(processIDs)
            observedReplacementProcessIDs = nil
            replacementObservationCount = 0

            LogManager.shared.log("ProcessAudioTap: Started capture for \(processIDs.count) selected audio process(es)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        isRunning = false
        capturedProcessIDs.removeAll()
        observedReplacementProcessIDs = nil
        replacementObservationCount = 0
    }

    /// A process tap captures the concrete Core Audio process objects supplied
    /// when it is created. Applications can replace those objects as helper or
    /// renderer processes start, stop, or restart, so a long-lived tap must be
    /// rebuilt when the matching process set changes.
    ///
    /// Require the same replacement set twice before rebuilding. This avoids
    /// interrupting audio for a one-poll process transition while an app and
    /// its helper processes are still settling.
    func requiresRebuildForCurrentProcesses() -> Bool {
        guard isRunning else { return false }

        let currentProcessIDs: Set<AudioObjectID>
        do {
            currentProcessIDs = Set(
                try AudioApplicationCatalog.processObjectIDs(
                    matchingApplicationIDs: targetApplicationIDs
                )
            )
        } catch {
            return false
        }

        guard currentProcessIDs != capturedProcessIDs else {
            observedReplacementProcessIDs = nil
            replacementObservationCount = 0
            return false
        }

        if observedReplacementProcessIDs == currentProcessIDs {
            replacementObservationCount += 1
        } else {
            observedReplacementProcessIDs = currentProcessIDs
            replacementObservationCount = 1
        }

        return replacementObservationCount >= 2
    }

    private func createAndStartIOProc() throws {
        var newIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            self.audioHandler(inputData, self.streamFormat, inputTime.pointee)
        }

        guard status == noErr, let newIOProcID else {
            throw ProcessAudioTapCaptureError.createIOProcFailed(status)
        }

        ioProcID = newIOProcID
        let startStatus = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        guard startStatus == noErr else {
            throw ProcessAudioTapCaptureError.startDeviceFailed(startStatus)
        }
    }

    private static func createAggregateDevice(for tapDescription: CATapDescription) throws -> AudioObjectID {
        let aggregateUID = "com.yichen.yccast.process-audio.\(UUID().uuidString)"
        let tapUID = tapDescription.uuid.uuidString

        let tapDictionary: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]

        let aggregateDictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Screen Bridge Process Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [tapDictionary]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregateDictionary as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw ProcessAudioTapCaptureError.createAggregateFailed(status)
        }

        return aggregateID
    }

    private static func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw ProcessAudioTapCaptureError.readTapFormatFailed(status)
        }
        return format
    }

}
