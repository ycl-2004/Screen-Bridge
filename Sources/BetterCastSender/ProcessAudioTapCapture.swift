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
    case startAlreadyInFlight
    case cancelledDuringStart

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
        case .startAlreadyInFlight:
            return "Process audio capture is already starting"
        case .cancelledDuringStart:
            return "Process audio capture start was cancelled"
        }
    }
}

/// Owns the Core Audio objects behind a process tap so they can be destroyed
/// deterministically and idempotently. All `destroy()` calls are serialized on
/// the capture's IO queue (including the one dispatched from the capture's
/// `deinit`), so no destroy can race an in-flight IO callback.
///
/// Swift permits `@unchecked Sendable` for reference types whose mutable state
/// is protected by internal synchronization:
/// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md
private final class ProcessAudioTapHandles: @unchecked Sendable {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    var ioProcID: AudioDeviceIOProcID?
    var streamFormat = AudioStreamBasicDescription()

    /// Written only before the IO block that reads it is created, from the same
    /// thread that registers the block — the format is immutable once live.
    func destroy() {
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
    }
}

/// Captures and optionally mutes audio from selected macOS processes using Core Audio process taps.
///
/// ScreenCaptureKit can copy system audio, but Core Audio taps can mute selected
/// applications while still delivering their samples to a receiver.
///
/// Threading contract:
/// - All mutable state is confined to `queue`, which is also the queue Core
///   Audio delivers IO callbacks on. Teardown runs on `queue`, so when `stop()`
///   returns no callback is executing or can still arrive — callers may then
///   safely detach delegates the callbacks were reading.
/// - Process enumeration and Core Audio object creation are synchronous mach
///   IPC (tens to hundreds of milliseconds) and run on `lifecycleQueue`,
///   keeping both the main thread and the real-time IO queue free.
final class ProcessAudioTapCapture: @unchecked Sendable {
    typealias AudioHandler = @Sendable (UnsafePointer<AudioBufferList>, AudioStreamBasicDescription, AudioTimeStamp) -> Void
    typealias StartCompletion = @Sendable (Result<Void, Error>) -> Void

    private let targetApplicationIDs: Set<String>
    private let muteProcess: Bool
    private let audioHandler: AudioHandler
    private let queue = DispatchQueue(label: "com.bettercast.process-audio-tap", qos: .userInteractive)
    private static let lifecycleQueue = DispatchQueue(
        label: "com.bettercast.process-audio-tap.lifecycle",
        qos: .userInitiated
    )

    // Mutable state — confined to `queue`.
    private var handles: ProcessAudioTapHandles?
    private var isRunning = false
    private var isStarting = false
    private var startCancelled = false
    private var capturedProcessIDs: Set<AudioObjectID> = []
    private var observedReplacementProcessIDs: Set<AudioObjectID>?
    private var replacementObservationCount = 0
    /// Consecutive process-list read failures. A sustained failure (e.g.
    /// coreaudiod restarting) must not silently pin a tap to a dead process
    /// set forever — after a few in a row, force a rebuild so the failure is
    /// observable instead of an endless mute with no audio flowing.
    private var consecutiveEnumerationFailures = 0
    private static let enumerationFailureRebuildThreshold = 3

    /// Application IDs are stable, user-facing identities produced by
    /// `AudioApplicationCatalog`. The catalog resolves each identity back to
    /// the current Core Audio process objects, including helper processes.
    init(applicationIDs: Set<String>, muteProcess: Bool, audioHandler: @escaping AudioHandler) {
        self.targetApplicationIDs = applicationIDs
        self.muteProcess = muteProcess
        self.audioHandler = audioHandler
    }

    deinit {
        // The handles box is captured strongly so it outlives `self`; destroying
        // on the queue serializes against any in-flight IO callback. Async (not
        // sync) because deinit may run on the queue itself via the callback's
        // temporary strong reference.
        let handles = self.handles
        queue.async {
            handles?.destroy()
        }
    }

    /// Starts capture asynchronously. Enumeration, tap/aggregate creation, and
    /// device start are synchronous IPC that must stay off the main thread;
    /// `completion` is always invoked on the main queue.
    func start(completion: StartCompletion? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isRunning {
                DispatchQueue.main.async { completion?(.success(())) }
                return
            }
            guard !self.isStarting else {
                DispatchQueue.main.async { completion?(.failure(ProcessAudioTapCaptureError.startAlreadyInFlight)) }
                return
            }
            guard #available(macOS 14.2, *) else {
                DispatchQueue.main.async { completion?(.failure(ProcessAudioTapCaptureError.unsupportedOS)) }
                return
            }
            self.isStarting = true
            // A stop() that ran after this start was enqueued but before its
            // entry block executed left the cancel flag set — honor it instead
            // of wiping it, or a stopped-and-dropped capture would still come
            // up live and muted.
            if self.startCancelled {
                self.startCancelled = false
                self.isStarting = false
                DispatchQueue.main.async {
                    completion?(.failure(ProcessAudioTapCaptureError.cancelledDuringStart))
                }
                return
            }

            let targetApplicationIDs = self.targetApplicationIDs
            let muteProcess = self.muteProcess
            let queue = self.queue

            // Strong self on purpose: if the app drops this capture while
            // creation is in flight, the object stays alive until the partial
            // Core Audio objects reach a teardown path.
            Self.lifecycleQueue.async {
                let created = ProcessAudioTapHandles()
                var committedProcessIDs: Set<AudioObjectID> = []
                let outcome: Result<Void, Error>
                do {
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
                    created.tapID = newTapID

                    created.streamFormat = try Self.readTapFormat(tapID: created.tapID)
                    created.aggregateDeviceID = try Self.createAggregateDevice(for: tapDescription)

                    var newIOProcID: AudioDeviceIOProcID?
                    let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, created.aggregateDeviceID, queue) { [weak self] _, inputData, inputTime, _, _ in
                        guard let self else { return }
                        // Tolerate both optional and implicitly-unwrapped
                        // imports of the timestamp pointer across SDKs.
                        guard let inputTime = inputTime as UnsafePointer<AudioTimeStamp>? else { return }
                        self.audioHandler(inputData, created.streamFormat, inputTime.pointee)
                    }
                    guard ioProcStatus == noErr, let newIOProcID else {
                        throw ProcessAudioTapCaptureError.createIOProcFailed(ioProcStatus)
                    }
                    created.ioProcID = newIOProcID
                    let startStatus = AudioDeviceStart(created.aggregateDeviceID, newIOProcID)
                    guard startStatus == noErr else {
                        throw ProcessAudioTapCaptureError.startDeviceFailed(startStatus)
                    }

                    committedProcessIDs = Set(processIDs)
                    outcome = .success(())
                } catch {
                    // Destroy partial objects immediately on failure; the
                    // commit below only sees a fully-created set.
                    created.destroy()
                    outcome = .failure(error)
                }

                queue.async { [weak self, committedProcessIDs, outcome] in
                    guard let self else {
                        // Nobody left to own the created objects; destroy them
                        // here rather than leaking live Core Audio handles.
                        created.destroy()
                        DispatchQueue.main.async {
                            completion?(.failure(ProcessAudioTapCaptureError.cancelledDuringStart))
                        }
                        return
                    }
                    self.isStarting = false
                    if self.startCancelled {
                        self.startCancelled = false
                        created.destroy()
                        DispatchQueue.main.async {
                            completion?(.failure(ProcessAudioTapCaptureError.cancelledDuringStart))
                        }
                        return
                    }
                    switch outcome {
                    case .success:
                        self.handles = created
                        self.capturedProcessIDs = committedProcessIDs
                        self.observedReplacementProcessIDs = nil
                        self.replacementObservationCount = 0
                        self.isRunning = true
                        LogManager.shared.log("ProcessAudioTap: Started capture for \(committedProcessIDs.count) selected audio process(es)")
                    case .failure:
                        break
                    }
                    DispatchQueue.main.async { completion?(outcome) }
                }
            }
        }
    }

    /// Stops capture and destroys the underlying Core Audio objects. Safe to
    /// call from any thread except the tap's own IO queue, and safe to call
    /// while `start()` is still in flight (the start is then cancelled and its
    /// partial objects destroyed). When this returns, no IO callback is
    /// running, so callers can detach delegates the callbacks were using.
    func stop() {
        queue.sync {
            startCancelled = true
            guard !isStarting else {
                // Commit path of the in-flight start observes the flag,
                // destroys its partial objects, and reports cancellation.
                return
            }
            handles?.destroy()
            handles = nil
            isRunning = false
            capturedProcessIDs.removeAll()
            observedReplacementProcessIDs = nil
            replacementObservationCount = 0
        }
    }

    /// A process tap captures the concrete Core Audio process objects supplied
    /// when it is created. Applications can replace those objects as helper or
    /// renderer processes start, stop, or restart, so a long-lived tap must be
    /// rebuilt when the matching process set changes.
    ///
    /// Require the same replacement set twice before rebuilding. This avoids
    /// interrupting audio for a one-poll process transition while an app and
    /// its helper processes are still settling.
    ///
    /// Enumeration happens off the main thread; `completion` runs on the main
    /// queue with the rebuild decision.
    func requiresRebuildForCurrentProcesses(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isRunning, !self.isStarting else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let targetApplicationIDs = self.targetApplicationIDs

            Self.lifecycleQueue.async { [weak self] in
                let enumerated = Result {
                    Set(try AudioApplicationCatalog.processObjectIDs(
                        matchingApplicationIDs: targetApplicationIDs
                    ))
                }

                self?.queue.async { [weak self] in
                    guard let self else {
                        DispatchQueue.main.async { completion(false) }
                        return
                    }
                    let decision = self.evaluateRebuild(enumerated: enumerated)
                    DispatchQueue.main.async { completion(decision) }
                }
            }
        }
    }

    /// Queue-confined decision step of the rebuild check.
    private func evaluateRebuild(enumerated: Result<Set<AudioObjectID>, Error>) -> Bool {
        switch enumerated {
        case .success(let currentProcessIDs):
            consecutiveEnumerationFailures = 0
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

        case .failure(let error):
            consecutiveEnumerationFailures += 1
            guard consecutiveEnumerationFailures >= Self.enumerationFailureRebuildThreshold else {
                return false
            }
            consecutiveEnumerationFailures = 0
            LogManager.shared.log(
                "ProcessAudioTap: Process list unreadable \(Self.enumerationFailureRebuildThreshold)x in a row (\(error.localizedDescription)); forcing tap rebuild"
            )
            return true
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
