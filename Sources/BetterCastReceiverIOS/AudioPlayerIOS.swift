#if canImport(UIKit)
import Foundation
import AVFoundation
import AudioToolbox
import BetterCastShared

/// Decodes timed AAC-LC packets and plays them via AVAudioEngine.
/// The AAC payload remains raw (no ADTS headers).
final class AudioPlayerIOS: @unchecked Sendable {

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioConverter: AudioConverterRef?

    fileprivate let outputSampleRate: Double = AudioStreamFormat.sampleRate
    fileprivate let outputChannels: UInt32 = AudioStreamFormat.channelCount

    private var outputFormat: AVAudioFormat?
    private var engineStarted = false
    private var decodeCount = 0
    private var droppedCount = 0
    private var underrunCount = 0
    private var sequenceTracker = AudioSequenceTracker()
    private var isInterrupted = false
    private let queue = DispatchQueue(label: "com.bettercast.audio-player", qos: .userInteractive)
    fileprivate let queueKey = DispatchSpecificKey<Void>()
    /// Seen by the free converter-input callback for its queue assertion.
    fileprivate let converterQueue: DispatchQueue
    private var notificationObservers: [NSObjectProtocol] = []
    /// Earliest allowed engine-start retry. A dead audio session fails every
    /// attempt, so retrying per packet (~21 ms) just spun syscalls; events that
    /// can actually fix the session force an immediate retry.
    private var earliestNextEngineStartAttempt = Date.distantPast

    private var jitterBuffer = AudioJitterBufferState()

    // Shared state for the converter input callback
    fileprivate var currentPacketData: Data?
    fileprivate var currentPacketConsumed: Bool = false
    fileprivate var packetDesc = AudioStreamPacketDescription()

    init() {
        queue.setSpecific(key: queueKey, value: ())
        converterQueue = queue
        setupEngine()
        observeAudioSession()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        stop()
        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }
    }

    // MARK: - Setup

    private func setupEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        // Standard format: non-interleaved float32 (AVAudioEngine default)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate,
                                          channels: AVAudioChannelCount(outputChannels)) else {
            LogManager.shared.log("AudioPlayer: Failed to create output format")
            return
        }

        outputFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: format)

        self.audioEngine = engine
        self.playerNode = player
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        )
        // mediaserverd crashes invalidate every AVAudioEngine and AudioConverter
        // without necessarily emitting an interruption or route change. Missing
        // this left engineStarted == true on dead objects: permanent silence
        // until the next full reconnect.
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                self?.handleMediaServicesReset()
            }
        )
    }

    private func handleMediaServicesReset() {
        queue.async { [weak self] in
            guard let self else { return }
            // Apple requires apps to recreate audio objects and re-establish
            // AVAudioSession properties after media services reset:
            // https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification
            LogManager.shared.log("AudioPlayer: Media services were reset — rebuilding engine and converter")
            self.resetPlaybackQueue()
            if let converter = self.audioConverter {
                AudioConverterDispose(converter)
            }
            self.audioConverter = nil
            do {
                let session = try configureReceiverAudioSession()
                LogManager.shared.log(
                    "AudioPlayer: Reconfigured audio session after reset — sampleRate=\(Int(session.sampleRate))Hz"
                )
            } catch {
                LogManager.shared.log("AudioPlayer: Could not reconfigure audio session after reset: \(error)")
            }
            self.setupEngine()
            self.isInterrupted = false
            self.restartEngine(reason: "media services reset")
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                self.isInterrupted = true
                self.resetPlaybackQueue()
                LogManager.shared.log("AudioPlayer: Playback interrupted")
            case .ended:
                self.isInterrupted = false
                self.restartEngine(reason: "interruption ended")
            @unknown default:
                break
            }
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))

        queue.async { [weak self] in
            guard let self, !self.isInterrupted else { return }
            self.restartEngine(reason: "route changed (\(reason?.rawValue ?? 0))")
        }
    }

    private func resetPlaybackQueue() {
        // Invalidate old completion callbacks before stop() asks the player to
        // deliver them. Otherwise callbacks from the previous connection can
        // decrement the next connection's newly scheduled buffers.
        jitterBuffer.reset()
        playerNode?.stop()
        audioEngine?.stop()
        engineStarted = false
        sequenceTracker.reset()
        currentPacketData = nil
        currentPacketConsumed = false
    }

    private func restartEngine(reason: String) {
        resetPlaybackQueue()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            startEngineIfNeeded(force: true)
            LogManager.shared.log("AudioPlayer: Recovered after \(reason)")
        } catch {
            LogManager.shared.log("AudioPlayer: Could not reactivate after \(reason): \(error)")
        }
    }

    private func setupConverter() {
        if audioConverter != nil { return }

        // Input: AAC-LC
        var inputDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Output: PCM float32 non-interleaved (matches AVAudioEngine standard format)
        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputDesc, &outputDesc, &converter)
        if status != noErr {
            LogManager.shared.log("AudioPlayer: Failed to create AudioConverter: \(status)")
            return
        }

        audioConverter = converter
        LogManager.shared.log(
            "AudioPlayer: AAC decoder ready (48kHz stereo, start \(AudioJitterBufferState.startPendingBuffers), "
                + "max \(AudioJitterBufferState.maxPendingBuffers) buffers)"
        )
    }

    private func startEngineIfNeeded(force: Bool = false) {
        guard !engineStarted, let engine = audioEngine else { return }
        if !force, Date() < earliestNextEngineStartAttempt { return }
        do {
            try engine.start()
            engineStarted = true
            LogManager.shared.log("AudioPlayer: Engine started")
        } catch {
            earliestNextEngineStartAttempt = Date().addingTimeInterval(1.0)
            LogManager.shared.log("AudioPlayer: Engine start failed: \(error)")
        }
    }

    // MARK: - Public API

    func decode(packet: FramedAudioPacket) {
        queue.async { [weak self] in
            self?.decodeOnQueue(packet: packet)
        }
    }

    private func decodeOnQueue(packet: FramedAudioPacket) {
        guard packet.header.codec == .aacLC else { return }
        recordSequence(packet.header.sequence)

        let aacData = packet.payload
        // Skip tiny silence frames (< 10 bytes)
        guard aacData.count >= 10, !isInterrupted else { return }

        setupConverter()
        startEngineIfNeeded()

        guard engineStarted,
              let converter = audioConverter,
              let format = outputFormat else { return }

        // Drop frames if too many buffers are queued (prevents latency buildup)
        if jitterBuffer.shouldDropIncomingBuffer {
            droppedCount += 1
            if droppedCount % 50 == 1 {
                LogManager.shared.log("AudioPlayer: Dropping audio packet to cap latency (pending: \(jitterBuffer.pendingBuffers), dropped: \(droppedCount))")
            }
            return
        }

        // Store packet for converter callback
        currentPacketData = aacData
        currentPacketConsumed = false

        // Decode one AAC frame (1024 samples)
        let frameCount = UInt32(packet.header.sampleCount)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        var outputDataPacketSize: UInt32 = frameCount
        let userData = Unmanaged.passUnretained(self).toOpaque()

        let status = AudioConverterFillComplexBuffer(
            converter,
            audioPlayerConverterInputCallback,
            userData,
            &outputDataPacketSize,
            pcmBuffer.mutableAudioBufferList,
            nil
        )

        currentPacketData = nil

        if status == noErr && outputDataPacketSize > 0 {
            pcmBuffer.frameLength = outputDataPacketSize
            let shouldStartPlayback = jitterBuffer.bufferScheduled()
            let playbackGeneration = jitterBuffer.playbackGeneration
            // The default scheduleBuffer completion is `dataConsumed`, which
            // Apple documents may run before rendering starts. Pending depth
            // must track rendered audio or it reports false underruns and may
            // pause a player that still has audio queued.
            // https://developer.apple.com/documentation/avfaudio/avaudioplayernode/schedulebuffer(_:completioncallbacktype:completionhandler:)
            playerNode?.scheduleBuffer(
                pcmBuffer,
                completionCallbackType: .dataRendered
            ) { [weak self] callbackType in
                guard callbackType == .dataRendered else { return }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if self.jitterBuffer.bufferCompleted(scheduledIn: playbackGeneration) {
                        self.playerNode?.pause()
                        self.underrunCount += 1
                        LogManager.shared.log(
                            "AudioPlayer: Underrun \(self.underrunCount); buffering \(AudioJitterBufferState.startPendingBuffers) packets before resume"
                        )
                    }
                }
            }
            if shouldStartPlayback, let player = playerNode {
                player.play()
                LogManager.shared.log(
                    "AudioPlayer: Playback started/resumed with \(jitterBuffer.pendingBuffers) buffered packets"
                )
            }

            decodeCount += 1
            if decodeCount % 100 == 1 {
                LogManager.shared.log("AudioPlayer: Decoded packet \(decodeCount), \(outputDataPacketSize) frames, pending: \(jitterBuffer.pendingBuffers)")
            }
        } else if status != noErr {
            decodeCount += 1
            if decodeCount % 50 == 1 {
                LogManager.shared.log("AudioPlayer: Decode failed (status \(status))")
            }
        }
    }

    private func recordSequence(_ sequence: UInt32) {
        switch sequenceTracker.observe(sequence) {
        case .gap(let expected, let received, let missing):
            LogManager.shared.log(
                "AudioPlayer: Sequence gap — expected \(expected), received \(received), missing \(missing)"
            )
        case .nonMonotonic(let expected, let received):
            LogManager.shared.log(
                "AudioPlayer: Non-monotonic sequence — expected \(expected), received \(received)"
            )
        case nil:
            break
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            resetPlaybackQueue()
        } else {
            queue.sync {
                resetPlaybackQueue()
            }
        }
    }
}

// MARK: - AudioConverter Input Callback (must be a free function)

private func audioPlayerConverterInputCallback(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let player = Unmanaged<AudioPlayerIOS>.fromOpaque(userData).takeUnretainedValue()

    // The input callback runs synchronously inside AudioConverterFillComplexBuffer,
    // which decodeOnQueue invokes on the player's serial queue. Assert that
    // contract so a future change that moves decode (or parallelizes the
    // converter) fails loudly here instead of racing on currentPacketData.
    dispatchPrecondition(condition: .onQueue(player.converterQueue))

    // Only provide data once per decode call
    guard let data = player.currentPacketData, !player.currentPacketConsumed else {
        ioNumberDataPackets.pointee = 0
        return 1
    }

    player.currentPacketConsumed = true

    data.withUnsafeBytes { rawBuffer in
        let ptr = rawBuffer.baseAddress!
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(data.count)
        ioData.pointee.mBuffers.mNumberChannels = player.outputChannels
    }

    // Packet description for variable-bitrate AAC
    player.packetDesc = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 0,
        mDataByteSize: UInt32(data.count)
    )
    if let descPtr = outDataPacketDescription {
        withUnsafeMutablePointer(to: &player.packetDesc) { ptr in
            descPtr.pointee = ptr
        }
    }

    ioNumberDataPackets.pointee = 1
    return noErr
}
#endif
