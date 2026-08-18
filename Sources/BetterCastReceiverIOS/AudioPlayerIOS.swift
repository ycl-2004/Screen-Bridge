#if canImport(UIKit)
import Foundation
import AVFoundation
import AudioToolbox

/// Decodes raw AAC-LC frames and plays them via AVAudioEngine.
/// Expects raw AAC packets (no ADTS headers) as produced by the Mac audio encoder.
final class AudioPlayerIOS: @unchecked Sendable {

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioConverter: AudioConverterRef?

    fileprivate let outputSampleRate: Double = 48000
    fileprivate let outputChannels: UInt32 = 2

    private var outputFormat: AVAudioFormat?
    private var engineStarted = false
    private var playerStarted = false
    private var decodeCount = 0
    private var droppedCount = 0
    private var isInterrupted = false
    private let queue = DispatchQueue(label: "com.bettercast.audio-player", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private var notificationObservers: [NSObjectProtocol] = []

    // Jitter buffer management
    // At 48kHz with 1024-frame AAC packets, each buffer is ~21ms.
    // Start after ~64ms and cap around ~213ms. This trades a small latency bump
    // for much better continuity when video packets briefly block the TCP stream.
    private var pendingBuffers: Int = 0
    private let startPendingBuffers: Int = 3
    private let maxPendingBuffers: Int = 10

    // Shared state for the converter input callback
    fileprivate var currentPacketData: Data?
    fileprivate var currentPacketConsumed: Bool = false
    fileprivate var packetDesc = AudioStreamPacketDescription()

    init() {
        queue.setSpecific(key: queueKey, value: ())
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

        // Keep the hardware buffer low; continuity is handled by our packet jitter buffer.
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredIOBufferDuration(BCConstants.audioIOBufferDuration)

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
        playerNode?.stop()
        audioEngine?.stop()
        engineStarted = false
        playerStarted = false
        pendingBuffers = 0
        currentPacketData = nil
        currentPacketConsumed = false
    }

    private func restartEngine(reason: String) {
        resetPlaybackQueue()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            startEngineIfNeeded()
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
        LogManager.shared.log("AudioPlayer: AAC decoder ready (48kHz stereo, start \(startPendingBuffers), max \(maxPendingBuffers) buffers)")
    }

    private func startEngineIfNeeded() {
        guard !engineStarted, let engine = audioEngine else { return }
        do {
            try engine.start()
            engineStarted = true
            LogManager.shared.log("AudioPlayer: Engine started")
        } catch {
            LogManager.shared.log("AudioPlayer: Engine start failed: \(error)")
        }
    }

    private func startPlaybackIfReady() {
        guard !playerStarted, pendingBuffers >= startPendingBuffers, let player = playerNode else { return }
        player.play()
        playerStarted = true
        LogManager.shared.log("AudioPlayer: Playback started with \(pendingBuffers) buffered packets")
    }

    // MARK: - Public API

    func decode(aacData: Data) {
        queue.async { [weak self] in
            self?.decodeOnQueue(aacData: aacData)
        }
    }

    private func decodeOnQueue(aacData: Data) {
        // Skip tiny silence frames (< 10 bytes)
        guard aacData.count >= 10, !isInterrupted else { return }

        setupConverter()
        startEngineIfNeeded()

        guard let converter = audioConverter,
              let format = outputFormat else { return }

        // Drop frames if too many buffers are queued (prevents latency buildup)
        if pendingBuffers >= maxPendingBuffers {
            droppedCount += 1
            if droppedCount % 50 == 1 {
                LogManager.shared.log("AudioPlayer: Dropping audio packet to cap latency (pending: \(pendingBuffers), dropped: \(droppedCount))")
            }
            return
        }

        // Store packet for converter callback
        currentPacketData = aacData
        currentPacketConsumed = false

        // Decode one AAC frame (1024 samples)
        let frameCount: UInt32 = 1024
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
            pendingBuffers += 1
            playerNode?.scheduleBuffer(pcmBuffer) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.pendingBuffers = max(self.pendingBuffers - 1, 0)
                }
            }
            startPlaybackIfReady()

            decodeCount += 1
            if decodeCount % 100 == 1 {
                LogManager.shared.log("AudioPlayer: Decoded packet \(decodeCount), \(outputDataPacketSize) frames, pending: \(pendingBuffers)")
            }
        } else if status != noErr {
            decodeCount += 1
            if decodeCount % 50 == 1 {
                LogManager.shared.log("AudioPlayer: Decode failed (status \(status))")
            }
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
