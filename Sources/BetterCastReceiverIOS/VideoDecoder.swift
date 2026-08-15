#if canImport(UIKit)
import Foundation
import VideoToolbox
import CoreMedia
import BetterCastShared

protocol VideoDecoderDelegate: AnyObject {
    func didDecode(sampleBuffer: CMSampleBuffer)
    /// Called when a frame fails to decode (e.g. broken reference chain after a
    /// dropped P-frame on a congested link). Gives the listener a chance to
    /// request a fresh keyframe instead of showing artifacts until the next GOP.
    func didFailToDecodeFrame(status: OSStatus)
}

extension VideoDecoderDelegate {
    func didFailToDecodeFrame(status: OSStatus) {}
}

private final class VideoDecoderCallbackContext {
    weak var decoder: VideoDecoder?
    let generation: UInt64

    init(decoder: VideoDecoder, generation: UInt64) {
        self.decoder = decoder
        self.generation = generation
    }
}

class VideoDecoder {
    
    weak var delegate: VideoDecoderDelegate?
    private var decompressionSession: VTDecompressionSession?
    private let decoderQueue = DispatchQueue(label: "com.yccast.video-decoder.lifecycle")
    private let decoderQueueKey = DispatchSpecificKey<UInt8>()
    private var generation: UInt64 = 0
    private var callbackContext: VideoDecoderCallbackContext?
    
    deinit {
        syncOnDecoderQueue {
            invalidateCurrentSession()
        }
        LogManager.shared.log("VideoDecoder: Deallocated")
    }
    
    private var formatDescription: CMVideoFormatDescription?
    
    // NALU buffer management
    private var sps: Data?
    private var pps: Data?
    private var configuredSPS: Data?
    private var configuredPPS: Data?
    
    private var timeOffset: Double = 0
    
    init() {
        decoderQueue.setSpecific(key: decoderQueueKey, value: 1)
    }

    func decode(data: Data) {
        decoderQueue.async { [weak self] in
            self?.decodeOnQueue(data: data)
        }
    }

    private func decodeOnQueue(data: Data) {
        // Expected format: [PTS: 8 bytes][AVCC NALUs...]
        guard let payload = StreamFraming.splitVideoPayload(data) else { return }

        // Parsing is validated up front rather than inline. The previous scanner
        // read the NALU header byte after only checking
        // `offset + 4 + naluLen > totalLen`, which passes for a zero-length NALU
        // at the end of the buffer and traps on the read.
        let parsed = AVCCParser.parse(payload.accessUnit)
        guard !parsed.isMalformed else {
            LogManager.shared.log("VideoDecoder: Dropped malformed access unit (\(payload.accessUnit.count) bytes)")
            // Ask for a fresh keyframe rather than feeding VideoToolbox garbage.
            reportDecodeFailure(status: kVTVideoDecoderBadDataErr)
            return
        }

        if let newSPS = parsed.sps { sps = newSPS }
        if let newPPS = parsed.pps { pps = newPPS }

        createDecompressionSessionIfReady()

        if decompressionSession != nil {
            decodeFrame(data: payload.accessUnit, ptsNanos: payload.presentationTimeNanos)
        }
    }

    /// Drops the decoder state so a new session starts from a fresh keyframe.
    ///
    /// Without this, reconnecting reused SPS/PPS and the decompression session
    /// from the previous session, which produced artifacts until the next GOP.
    func reset() {
        syncOnDecoderQueue {
            invalidateCurrentSession()
            formatDescription = nil
            sps = nil
            pps = nil
            configuredSPS = nil
            configuredPPS = nil
            timeOffset = 0
        }
        LogManager.shared.log("VideoDecoder: Reset for new session")
    }

    private func syncOnDecoderQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: decoderQueueKey) != nil {
            return work()
        }
        return decoderQueue.sync(execute: work)
    }

    private func invalidateCurrentSession() {
        generation &+= 1
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        callbackContext = nil
    }
    
    private func createDecompressionSessionIfReady() {
        guard let sps = sps, let pps = pps else { return }
        if decompressionSession != nil,
           configuredSPS == sps,
           configuredPPS == pps {
            return
        }
        
        let parameterSets = [sps, pps]
        let parameterSetPointers = parameterSets.map { ($0 as NSData).bytes.bindMemory(to: UInt8.self, capacity: $0.count) }
        let parameterSetSizes = parameterSets.map { $0.count }
        
        var _formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &_formatDescription
        )
        
        guard status == noErr, let formatDesc = _formatDescription else {
            LogManager.shared.log("VideoDecoder: Failed to create format description \(status)")
            return
        }
        
        // Parameter sets may change without a dimension change. Recreate for
        // either case so the decoder never runs with stale codec state.
        var needsNewSession = decompressionSession == nil
        if let oldFormat = self.formatDescription, decompressionSession != nil {
            let oldDim = CMVideoFormatDescriptionGetDimensions(oldFormat)
            let newDim = CMVideoFormatDescriptionGetDimensions(formatDesc)
            if oldDim.width != newDim.width || oldDim.height != newDim.height {
                LogManager.shared.log("VideoDecoder: Dimensions changed \(oldDim.width)x\(oldDim.height) -> \(newDim.width)x\(newDim.height), recreating session")
            }
            needsNewSession = true
            invalidateCurrentSession()
            timeOffset = 0
        }

        self.formatDescription = formatDesc

        if needsNewSession {
            let decoderSpecification: [String: Any] = [:]

            let destinationImageBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferOpenGLCompatibilityKey as String: true
            ]

            generation &+= 1
            let context = VideoDecoderCallbackContext(decoder: self, generation: generation)
            callbackContext = context
            var outputCallback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: decompressionCallback,
                decompressionOutputRefCon: Unmanaged.passUnretained(context).toOpaque()
            )

            var _session: VTDecompressionSession?
            let sessionStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDesc,
                decoderSpecification: decoderSpecification as CFDictionary,
                imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
                outputCallback: &outputCallback,
                decompressionSessionOut: &_session
            )

            if sessionStatus == noErr, let session = _session {
                self.decompressionSession = session
                configuredSPS = sps
                configuredPPS = pps
                VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                LogManager.shared.log("VideoDecoder: Session Ready")
            } else {
                callbackContext = nil
                LogManager.shared.log("VideoDecoder: Failed to create session \(sessionStatus)")
            }
        }
    }
    
    private func decodeFrame(data: Data, ptsNanos: UInt64) {
        guard let session = decompressionSession else { return }
        
        var blockBuffer: CMBlockBuffer?
        let nalData = Data(data)
        
        let status = nalData.withUnsafeBytes { bufferPointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: nalData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: nalData.count,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )
        }
        
        guard status == noErr, let buffer = blockBuffer else { return }
        
        nalData.withUnsafeBytes { rawBufferPointer in
            if let address = rawBufferPointer.baseAddress {
                 CMBlockBufferReplaceDataBytes(with: address, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: nalData.count)
            }
        }
        
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [nalData.count]
        
             // Time Synchronization logic (Mac Port)
             if self.timeOffset == 0 {
                 let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                 let senderTime = Double(ptsNanos) / 1_000_000_000.0
                 self.timeOffset = now - senderTime
             }
             
             let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
             // 50ms buffer
             let presentationTime = CMTimeAdd(hostTime, CMTime(seconds: 0.05, preferredTimescale: 1_000_000_000))
             
             var timing = CMSampleTimingInfo(
                 duration: CMTime.invalid,
                 presentationTimeStamp: presentationTime,
                 decodeTimeStamp: .invalid
             )
        
             let sbStatus = CMSampleBufferCreateReady(
              allocator: kCFAllocatorDefault,
              dataBuffer: buffer,
              formatDescription: formatDescription,
              sampleCount: 1,
              sampleTimingEntryCount: 1,
              sampleTimingArray: &timing,
              sampleSizeEntryCount: 1,
              sampleSizeArray: sampleSizeArray,
              sampleBufferOut: &sampleBuffer
          )
          
          if sbStatus == noErr, let sb = sampleBuffer {
             let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
             var infoFlags: VTDecodeInfoFlags = []
             
             let status = VTDecompressionSessionDecodeFrame(
                 session,
                 sampleBuffer: sb,
                 flags: flags,
                 frameRefcon: nil,
                 infoFlagsOut: &infoFlags
             )
             
             if status != noErr {
                 LogManager.shared.log("VideoDecoder: Decode Fail \(status)")
                 reportDecodeFailure(status: status)
             }
         }
    }

    fileprivate func handleDecodedOutput(
        imageBuffer: CVImageBuffer,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime,
        generation callbackGeneration: UInt64
    ) {
        decoderQueue.async { [weak self] in
            guard let self, self.generation == callbackGeneration else { return }

            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: presentationDuration,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: .invalid
            )
            var formatDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard let desc = formatDesc else { return }

            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: desc,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )

            guard let sampleBuffer else { return }
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didDecode(sampleBuffer: sampleBuffer)
            }
        }
    }

    fileprivate func reportDecodeFailure(status: OSStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didFailToDecodeFrame(status: status)
        }
    }
}

private func decompressionCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let context = Unmanaged<VideoDecoderCallbackContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let decoder = context.decoder else { return }
    guard status == noErr, let imageBuffer = imageBuffer else {
        if status != noErr {
            decoder.reportDecodeFailure(status: status)
        }
        return
    }

    decoder.handleDecodedOutput(
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        presentationDuration: presentationDuration,
        generation: context.generation
    )
}
#endif
