import Foundation
import CoreAudio

enum ProcessAudioTapCaptureError: LocalizedError {
    case unsupportedOS
    case noMatchingAudioProcess([String])
    case createTapFailed(OSStatus)
    case readTapFormatFailed(OSStatus)
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startDeviceFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Process audio capture requires macOS 14.2 or newer"
        case .noMatchingAudioProcess(let bundleIDs):
            return "No active audio process matched \(bundleIDs.joined(separator: ", "))"
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
/// This is the path we need for "Chrome plays on iPad only": ScreenCaptureKit can copy system
/// audio, but Core Audio taps can mute the tapped process while still delivering its samples.
final class ProcessAudioTapCapture {
    typealias AudioHandler = (UnsafePointer<AudioBufferList>, AudioStreamBasicDescription) -> Void

    private let bundleIDPrefixes: [String]
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

    init(bundleIDPrefixes: [String], muteProcess: Bool, audioHandler: @escaping AudioHandler) {
        self.bundleIDPrefixes = bundleIDPrefixes
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

        let processIDs = try Self.audioProcessIDs(matchingBundleIDPrefixes: bundleIDPrefixes)
        guard !processIDs.isEmpty else {
            throw ProcessAudioTapCaptureError.noMatchingAudioProcess(bundleIDPrefixes)
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapDescription.name = "ScreenBridge Chrome Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = muteProcess ? .muted : .unmuted

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

            LogManager.shared.log("ProcessAudioTap: Started muted capture for \(processIDs.count) Chrome audio process(es)")
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
    /// when it is created. Chrome replaces those objects as renderer processes
    /// start, stop, or restart, so a long-lived tap must be rebuilt when the
    /// matching process set changes.
    ///
    /// Require the same replacement set twice before rebuilding. This avoids
    /// interrupting audio for a one-poll process transition while Chrome is
    /// creating a renderer.
    func requiresRebuildForCurrentProcesses() -> Bool {
        guard isRunning else { return false }

        let currentProcessIDs: Set<AudioObjectID>
        do {
            currentProcessIDs = Set(try Self.audioProcessIDs(matchingBundleIDPrefixes: bundleIDPrefixes))
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
        let status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, queue) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.audioHandler(inputData, self.streamFormat)
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
            kAudioAggregateDeviceNameKey: "ScreenBridge Process Audio",
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

    private static func audioProcessIDs(matchingBundleIDPrefixes prefixes: [String]) throws -> [AudioObjectID] {
        let processIDs = try allAudioProcessIDs()

        return processIDs.filter { processID in
            guard let bundleID = stringProperty(processID, selector: kAudioProcessPropertyBundleID) else {
                return false
            }
            guard prefixes.contains(where: { bundleID.hasPrefix($0) }) else {
                return false
            }
            return true
        }
    }

    private static func allAudioProcessIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processIDs
        )
        guard status == noErr else { return [] }

        return processIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

}
