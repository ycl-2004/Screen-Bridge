import Foundation
import VideoToolbox
import CoreMedia

/// Runs the frame owner's cleanup exactly once after VideoToolbox finishes
/// with an asynchronously submitted image buffer.
private final class VideoFrameCompletionToken {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    deinit {
        completion()
    }
}

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    let connectionId: UUID
    private var compressionSession: VTCompressionSession?
    private var frameCount = 0
    private var bitrate: Int

    /// Guards the session against use after teardown.
    ///
    /// The VideoToolbox callback is registered with `passUnretained(self)`, so a
    /// session that outlives this object would call back into freed memory.
    /// `invalidate()` drains and tears the session down before that can happen,
    /// and `deinit` is the backstop for callers that forget.
    private let encoderQueue = DispatchQueue(label: "com.yccast.video-encoder.lifecycle")
    private let encoderQueueKey = DispatchSpecificKey<UInt8>()
    private let callbackQueue = DispatchQueue(label: "com.yccast.video-encoder.callback")
    private var isInvalidated = false

    // Cache for headers so we can re-send them if needed
    private var cachedSPS: Data?
    private var cachedPPS: Data?

    private var pendingKeyFrameRequest = false
    private var lastKeyFrameTime: Date = Date.distantPast
    private let keyframeThrottleInterval: TimeInterval

    private var expectedFPS: Int

    init(connectionId: UUID, width: Int, height: Int, bitrate: Int = 20_000_000, expectedFPS: Int = 120, keyframeIntervalSeconds: Double = 10.0, rateLimitWindow: Double = 1.0) {
        self.connectionId = connectionId
        self.bitrate = bitrate
        self.expectedFPS = expectedFPS
        self.keyframeThrottleInterval = max(0.3, keyframeIntervalSeconds / 3.0) // Allow forced keyframes at 1/3 the interval
        encoderQueue.setSpecific(key: encoderQueueKey, value: 1)
        
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
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        
        if status != noErr {
            LogManager.shared.log("VideoEncoder: Failed to create session \(status)")
            return
        }
        
        guard let session = compressionSession else { return }
        
        // Configuration for Low-Latency Real-Time Encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        // CABAC costs a little encode time and buys roughly 10% bitrate at equal
        // quality versus CAVLC. On screen content — text, thin UI lines, large flat
        // areas — that budget goes straight into sharper edges.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        // Emit each frame as soon as it is encoded. Anything above 0 trades
        // latency for compression efficiency, which is the wrong trade for a
        // screen the user is actively working on.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        
        let bitrateCF = bitrate as CFNumber
        // DataRateLimits uses BYTES per period. Shorter windows = tighter per-frame control.
        // P2P uses 0.1s (prevents AWDL buffer bloat), infrastructure uses 1.0s (more flexible).
        let bytesPerWindow = Int(Double(bitrate / 8) * 1.5 * rateLimitWindow)
        let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateCF)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
        
        // Keyframe Control — shorter interval = faster error recovery at cost of bandwidth
        let maxKeyFrameInterval = Int(keyframeIntervalSeconds * Double(expectedFPS))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeIntervalSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // Crucial for Real-Time
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFPS as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        LogManager.shared.log("VideoEncoder: Initialized (\(bitrate/1_000_000)Mbps, KF every \(keyframeIntervalSeconds)s)")
    }
    
    deinit {
        invalidate()
        LogManager.shared.log("VideoEncoder: Deallocated")
    }

    /// Drains in-flight frames and tears the compression session down.
    ///
    /// Idempotent and safe to call from any thread. After this returns,
    /// VideoToolbox will not deliver further callbacks for this encoder, which is
    /// what makes the unretained callback reference safe.
    func invalidate() {
        let session: VTCompressionSession? = syncOnEncoderQueue {
            guard !isInvalidated else { return nil }
            isInvalidated = true
            let current = compressionSession
            compressionSession = nil
            return current
        }

        guard let session else { return }
        // Order matters: finish outstanding frames first, otherwise their
        // callbacks fire against a session that is already being invalidated.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        delegate = nil
    }

    func forceKeyframe() {
        encoderQueue.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            LogManager.shared.log("VideoEncoder: Keyframe Requested")
            self.pendingKeyFrameRequest = true
        }
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        encoderQueue.async { [weak self] in
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
        onCompleted: @escaping () -> Void
    ) {
        encoderQueue.async { [weak self] in
            guard let self else {
                onCompleted()
                return
            }

            self.encode(
                imageBuffer: pixelBuffer,
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
        completion: (() -> Void)?
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
            lastKeyFrameTime = Date()
        } else if pendingKeyFrameRequest {
            LogManager.shared.log("VideoEncoder: Keyframe Request Throttled (Last: \(timeSinceLastKeyFrame)s ago)")
            pendingKeyFrameRequest = false
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
        callbackQueue.async { [weak self] in
            self?.processEncodedSampleBuffer(sampleBuffer)
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
             // Convert PTS to UInt64 nanoseconds (8 bytes)
             var ptsNanos = UInt64(presentationTimeStamp.seconds * 1_000_000_000)
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
