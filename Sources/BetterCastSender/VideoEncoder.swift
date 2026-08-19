import Foundation
@preconcurrency import VideoToolbox
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo

/// Runs the frame owner's cleanup exactly once after VideoToolbox finishes
/// with an asynchronously submitted image buffer.
private final class VideoFrameCompletionToken: @unchecked Sendable {
    private let completion: @Sendable () -> Void

    init(completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    deinit {
        completion()
    }
}

/// CoreMedia/CoreVideo reference types are retainable across dispatch queues
/// but do not declare Sendable in the current SDK. This box makes that single
/// ownership transfer explicit at the queue boundary.
private struct VideoTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// Shared launch-scoped de-duplication for hardware-property diagnostics.
/// The lock is part of the value's synchronization contract, so the wrapper is
/// explicitly unchecked-Sendable instead of exposing a mutable static `Set` to
/// Swift 6's global-state checker.
private final class VideoEncoderUnsupportedPropertyLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: Set<String> = []

    func insertIfNew(_ label: String) -> Bool {
        lock.withLock {
            labels.insert(label).inserted
        }
    }
}

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool)
}

final class VideoEncoder: @unchecked Sendable {
    weak var delegate: VideoEncoderDelegate?
    let connectionId: UUID
    private var compressionSession: VTCompressionSession?
    private var frameCount = 0
    private var bitrate: Int

    /// The output callback holds a **retained** reference (`passRetained`) that
    /// only `invalidate()` releases, so an owner that drops the encoder without
    /// invalidating leaks rather than letting VideoToolbox call back into freed
    /// memory. Every owner path invalidates before dropping.
    private let encoderQueue = DispatchQueue(label: "com.yccast.video-encoder.lifecycle")
    private let encoderQueueKey = DispatchSpecificKey<UInt8>()
    private let callbackQueue = DispatchQueue(label: "com.yccast.video-encoder.callback")
    private var isInvalidated = false
    private var retainedCallbackPointer: UnsafeMutableRawPointer?

    // Cache for headers so we can re-send them if needed
    private var cachedSPS: Data?
    private var cachedPPS: Data?

    private var pendingKeyFrameRequest = false
    private var lastKeyFrameTime: Date = Date.distantPast
    private let keyframeThrottleInterval: TimeInterval
    /// One log per throttle episode instead of one per throttled frame.
    private var keyframeThrottleLogged = false

    private var expectedFPS: Int

    init(connectionId: UUID, width: Int, height: Int, bitrate: Int = 20_000_000, expectedFPS: Int = 120, keyframeIntervalSeconds: Double = 10.0, rateLimitWindow: Double = 1.0) {
        self.connectionId = connectionId
        self.bitrate = bitrate
        self.expectedFPS = expectedFPS
        self.keyframeThrottleInterval = max(0.3, keyframeIntervalSeconds / 3.0) // Allow forced keyframes at 1/3 the interval
        encoderQueue.setSpecific(key: encoderQueueKey, value: 1)

        let selfPointer = Unmanaged.passRetained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, flags, sampleBuffer) in
                // The source-frame token is independent of the encoder object:
                // always release it even if the session reports an error.
                if let sourceFrameRefCon {
                    Unmanaged<VideoFrameCompletionToken>
                        .fromOpaque(sourceFrameRefCon)
                        .release()
                }
                guard let refCon = outputCallbackRefCon else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
                encoder.compressionCallback(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: selfPointer,
            compressionSessionOut: &compressionSession
        )

        if status != noErr {
            LogManager.shared.log("VideoEncoder: Failed to create session \(status)")
            // The retained callback reference must go away with the session
            // that was never created.
            Unmanaged<VideoEncoder>.fromOpaque(selfPointer).release()
            return
        }
        retainedCallbackPointer = selfPointer

        guard let session = compressionSession else { return }

        // Configuration for Low-Latency Real-Time Encoding. Failures here only
        // degrade quality/latency, but silently: log each miss so the selected
        // profile can be trusted in diagnostics.
        setSessionProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        setSessionProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel, "ProfileLevel")

        // CABAC costs a little encode time and buys roughly 10% bitrate at equal
        // quality versus CAVLC. On screen content — text, thin UI lines, large flat
        // areas — that budget goes straight into sharper edges.
        setSessionProperty(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC, "CABAC")

        // Emit each frame as soon as it is encoded. Anything above 0 trades
        // latency for compression efficiency, which is the wrong trade for a
        // screen the user is actively working on.
        setSessionProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber, "MaxFrameDelayCount")

        let bitrateCF = bitrate as CFNumber
        // DataRateLimits uses BYTES per period. Shorter windows = tighter per-frame control.
        // P2P uses 0.1s (prevents AWDL buffer bloat), infrastructure uses 1.0s (more flexible).
        let bytesPerWindow = Int(Double(bitrate / 8) * 1.5 * rateLimitWindow)
        let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray

        setSessionProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrateCF, "AverageBitRate")
        setSessionProperty(session, kVTCompressionPropertyKey_DataRateLimits, limitCF, "DataRateLimits")

        // Keyframe Control — shorter interval = faster error recovery at cost of bandwidth
        let maxKeyFrameInterval = Int(keyframeIntervalSeconds * Double(expectedFPS))
        setSessionProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, maxKeyFrameInterval as CFNumber, "MaxKeyFrameInterval")
        setSessionProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeIntervalSeconds as CFNumber, "MaxKeyFrameIntervalDuration")
        setSessionProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering") // Crucial for Real-Time
        setSessionProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, expectedFPS as CFNumber, "ExpectedFrameRate")

        VTCompressionSessionPrepareToEncodeFrames(session)
        LogManager.shared.log("VideoEncoder: Initialized (\(bitrate/1_000_000)Mbps, KF every \(keyframeIntervalSeconds)s)")
    }

    /// Properties this machine's encoder has already reported as unsupported.
    ///
    /// `kVTPropertyNotSupportedErr` is a fixed fact about the hardware encoder,
    /// not an event: Apple silicon's H.264 encoder rejects `MaxFrameDelayCount`
    /// on every session. Logging it per session buried real failures in noise,
    /// so an unsupported property is reported once per launch and a genuine
    /// failure still logs every time.
    private static let unsupportedPropertyLogger = VideoEncoderUnsupportedPropertyLogger()

    private func setSessionProperty(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef, _ label: String) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status != noErr else { return }

        if status == kVTPropertyNotSupportedErr {
            let isFirstReport = Self.unsupportedPropertyLogger.insertIfNew(label)
            guard isFirstReport else { return }
            // Low latency does not depend on this property alone: frame
            // reordering is already disabled and RealTime is set, so the encoder
            // still emits each frame as it finishes.
            LogManager.shared.log("VideoEncoder: \(label) is not supported by this hardware encoder — leaving it at the encoder default")
            return
        }

        LogManager.shared.log("VideoEncoder: Could not set \(label) (\(status)) — output may differ from the selected profile")
    }

    deinit {
        invalidate()
        LogManager.shared.log("VideoEncoder: Deallocated")
    }

    /// Drains in-flight frames and tears the compression session down.
    ///
    /// Idempotent and safe to call from any thread. After this returns,
    /// VideoToolbox will not deliver further callbacks for this encoder, which
    /// is what makes the callback's retained reference safe to release.
    func invalidate() {
        let teardown: (session: VTCompressionSession?, pointer: UnsafeMutableRawPointer?) = syncOnEncoderQueue {
            guard !isInvalidated else { return (nil, nil) }
            isInvalidated = true
            let current = compressionSession
            compressionSession = nil
            let pointer = retainedCallbackPointer
            retainedCallbackPointer = nil
            return (current, pointer)
        }

        guard let session = teardown.session else { return }
        // Order matters: finish outstanding frames first, otherwise their
        // callbacks fire against a session that is already being invalidated.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        if let pointer = teardown.pointer {
            Unmanaged<VideoEncoder>.fromOpaque(pointer).release()
        }
    }

    func forceKeyframe() {
        encoderQueue.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            LogManager.shared.log("VideoEncoder: Keyframe Requested")
            self.pendingKeyFrameRequest = true
        }
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        let transfer = VideoTransfer(value: sampleBuffer)
        encoderQueue.async { [weak self] in
            let sampleBuffer = transfer.value
            guard let self,
                  !self.isInvalidated,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)

            self.encode(
                imageBuffer: imageBuffer,
                presentationTimestamp: presentationTimestamp,
                duration: duration,
                completion: nil
            )
        }
    }

    /// Encodes a pixel buffer whose backing storage has an external lifetime.
    /// `onCompleted` is called exactly once after VideoToolbox is finished with
    /// it, including early rejection during teardown.
    func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTimestamp: CMTime,
        duration: CMTime,
        onCompleted: @escaping @Sendable () -> Void
    ) {
        let transfer = VideoTransfer(value: pixelBuffer)
        encoderQueue.async { [weak self] in
            guard let self else {
                onCompleted()
                return
            }

            self.encode(
                imageBuffer: transfer.value,
                presentationTimestamp: presentationTimestamp,
                duration: duration,
                completion: onCompleted
            )
        }
    }

    private func encode(
        imageBuffer: CVImageBuffer,
        presentationTimestamp: CMTime,
        duration: CMTime,
        completion: (@Sendable () -> Void)?
    ) {
        guard !isInvalidated, let session = compressionSession else {
            completion?()
            return
        }

        frameCount += 1
        var frameProperties: [String: Any] = [:]

        // Force keyframe if requested or first frame. These fields have the
        // same serial owner as encode and invalidate.
        let timeSinceLastKeyFrame = Date().timeIntervalSince(lastKeyFrameTime)

        if frameCount == 1 || (pendingKeyFrameRequest && timeSinceLastKeyFrame > keyframeThrottleInterval) {
            LogManager.shared.log("VideoEncoder: Forcing Keyframe (Frame \(frameCount))")
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = kCFBooleanTrue
            pendingKeyFrameRequest = false
            keyframeThrottleLogged = false
            lastKeyFrameTime = Date()
        } else if pendingKeyFrameRequest {
            // Keep the request pending instead of clearing it: a receiver
            // request that lands inside the throttle window (P2P/wired links
            // throttle for ~3.3s) used to be silently swallowed, leaving the
            // picture corrupted until the receiver re-requested or the next
            // GOP. The request fires as soon as the window clears.
            if !keyframeThrottleLogged {
                keyframeThrottleLogged = true
                LogManager.shared.log("VideoEncoder: Keyframe Request Throttled (Last: \(timeSinceLastKeyFrame)s ago); will fire when the window clears")
            }
        }

        let completionToken = completion.map(VideoFrameCompletionToken.init)
        let completionRef = completionToken.map {
            Unmanaged.passRetained($0).toOpaque()
        }

        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: duration,
            frameProperties: frameProperties as CFDictionary,
            sourceFrameRefcon: completionRef,
            infoFlagsOut: &infoFlags
        )

        if status != noErr || infoFlags.contains(.frameDropped) {
            // A synchronously rejected/dropped frame never reaches the output
            // callback, so release its external surface here.
            if let completionRef {
                Unmanaged<VideoFrameCompletionToken>
                    .fromOpaque(completionRef)
                    .release()
            }
            if status != noErr {
                LogManager.shared.log("VideoEncoder: Encode failed \(status)")
            }
        }
    }

    func updateBitrate(_ newBitrate: Int, rateLimitWindow: Double) {
        encoderQueue.async { [weak self] in
            guard let self,
                  !self.isInvalidated,
                  let session = self.compressionSession else { return }
            self.bitrate = newBitrate
            let bitrateCF = newBitrate as CFNumber
            let bytesPerWindow = Int(Double(newBitrate / 8) * 1.5 * rateLimitWindow)
            let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateCF)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
            LogManager.shared.log("VideoEncoder: Updated bitrate to \(newBitrate / 1_000_000)Mbps")
        }
    }

    private func syncOnEncoderQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: encoderQueueKey) != nil {
            return work()
        }
        return encoderQueue.sync(execute: work)
    }
    
    private func compressionCallback(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard let sampleBuffer, status == noErr else { return }
        let transfer = VideoTransfer(value: sampleBuffer)
        callbackQueue.async { [weak self] in
            self?.processEncodedSampleBuffer(transfer.value)
        }
    }

    private func processEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        
        // Extract timestamp
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Check if keyframe using Swift casting (Safe)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync
        
        // 1. Extract and Cache Headers from this frame if present
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            extractAndCacheParameterSets(from: description)
        }
        
        var coalescedData = Data()
        
        // 2. Handle Header Bundling for Keyframes
        if isKeyframe {
            
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var pCount: size_t = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &pCount, nalUnitHeaderLengthOut: nil)
                
                if pCount >= 2 {
                    // Extract from description
                     for i in 0..<pCount {
                        var pointer: UnsafePointer<UInt8>?
                        var size: Int = 0
                        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                        if let pointer = pointer {
                            var len = UInt32(size).bigEndian
                            coalescedData.append(Data(bytes: &len, count: 4))
                            coalescedData.append(Data(bytes: pointer, count: size))
                        }
                    }
                } else if let sps = cachedSPS, let pps = cachedPPS {
                    // Inject from cache
                    var lenSPS = UInt32(sps.count).bigEndian
                    coalescedData.append(Data(bytes: &lenSPS, count: 4))
                    coalescedData.append(sps)

                    var lenPPS = UInt32(pps.count).bigEndian
                    coalescedData.append(Data(bytes: &lenPPS, count: 4))
                    coalescedData.append(pps)
                    LogManager.shared.log("VideoEncoder: Injected Cached SPS/PPS")
                } else {
                    // A keyframe with no parameter sets — in band or cached — is
                    // undecodable on the receiver. Drop it and force a fresh one
                    // instead of shipping a black picture until the next GOP.
                    LogManager.shared.log("VideoEncoder: Dropping keyframe without parameter sets; forcing a new keyframe")
                    forceKeyframe()
                    return
                }
            }
        }
        
        // 3. Append the Frame Data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr {
            
            var bufferOffset = 0
            let headerLength = 4 // AVCC 4 bytes length
            
            while bufferOffset < totalLength - headerLength {
                var atomLength: UInt32 = 0
                memcpy(&atomLength, dataPointer! + bufferOffset, 4)
                atomLength = UInt32(bigEndian: atomLength)
                
                bufferOffset += 4 // Skip length
                
                if bufferOffset + Int(atomLength) > totalLength { break }
                
                let nalData = Data(bytes: dataPointer! + bufferOffset, count: Int(atomLength))
                
                // Append [Len][NALU]
                var avccLen = UInt32(atomLength).bigEndian
                coalescedData.append(Data(bytes: &avccLen, count: 4))
                coalescedData.append(nalData)
                
                bufferOffset += Int(atomLength)
            }
        }
        
        // 4. Send One Megapacket (with PTS Header)
        if !coalescedData.isEmpty {
             var packetWithPTS = Data()
             // Convert PTS to UInt64 nanoseconds (8 bytes). CMTime.seconds is
             // NaN for invalid timestamps and can exceed UInt64's range for
             // pathological inputs; UInt64(Double) traps on both.
             let ptsSeconds = presentationTimeStamp.seconds
             guard ptsSeconds.isFinite, ptsSeconds >= 0,
                   ptsSeconds * 1_000_000_000 < Double(UInt64.max) else { return }
             var ptsNanos = UInt64(ptsSeconds * 1_000_000_000)
             packetWithPTS.append(Data(bytes: &ptsNanos, count: 8))
             packetWithPTS.append(coalescedData)

             delegate?.videoEncoder(self, didEncode: packetWithPTS, for: connectionId, isKeyframe: isKeyframe)
        }
    }
    
    private func extractAndCacheParameterSets(from description: CMVideoFormatDescription) {
        var parameterSetCount: size_t = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        
        if parameterSetCount < 2 { return }
        
        // Extract SPS (Index 0)
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        
        // Extract PPS (Index 1)
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        
        if let spsP = spsPointer, let ppsP = ppsPointer {
            let spsData = Data(bytes: spsP, count: spsSize)
            let ppsData = Data(bytes: ppsP, count: ppsSize)
            
            // Only update if changed
            if spsData != cachedSPS || ppsData != cachedPPS {
                cachedSPS = spsData
                cachedPPS = ppsData
                LogManager.shared.log("VideoEncoder: Cached new SPS/PPS headers")
            }
        }
    }
}
