import Foundation
import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia
import BetterCastShared

protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(
        _ encoder: AudioEncoder,
        didEncode data: Data,
        sampleTime: UInt64?,
        for connectionId: UUID
    )
}

final class AudioEncoder: @unchecked Sendable {
    weak var delegate: AudioEncoderDelegate?
    let connectionId: UUID

    private var converter: AudioConverterRef?
    private var inputFormat: AudioStreamBasicDescription?
    private var outputFormat: AudioStreamBasicDescription?
    private var frameCount = 0
    private var hasLoggedUnsupportedFormat = false
    /// Converter creation backoff: a persistently failing AudioConverterNew
    /// must not retry (and log) on every tap callback (~46x/s).
    private var lastConverterCreationAttempt = Date.distantPast
    private var hasLoggedConverterFailure = false
    private static let converterRetryInterval: TimeInterval = 5.0

    // Reusable PCM FIFO — accumulates until the converter has enough source
    // frames for one 1024-frame AAC packet.
    private var pcmAccumulator = AudioPCMByteRingBuffer()
    private var interleavedScratch: [Float32] = []
    private var pcmAccumulatorStartSampleTime: UInt64?
    private var interleavedChannels: UInt32 = 2
    private var bytesPerInterleavedFrame: Int = 8 // channels * sizeof(Float32)
    private let outputBufferSize: UInt32 = 8192
    private var aacOutputBuffer: UnsafeMutableRawPointer?
    private var inputFramesNeededForAACPacket = Int(BCConstants.aacFrameSize)
    private var converterInputOffset = 0
    private var converterInputBytesConsumed = 0
    private var hasLoggedConcurrentEncode = false

    /// Encode is owned by exactly one queue (the tap's IO callback queue).
    /// The accumulator and converter state are manually managed, so a second
    /// concurrent caller would corrupt them. Contend-detect and drop rather
    /// than block a realtime audio thread.
    private let encodeLock = NSLock()

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        guard let srcFormat = asbd else { return }

        // Get the required AudioBufferList size (may need multiple buffers for non-interleaved)
        var ablSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        // Allocate properly-sized AudioBufferList
        let ablMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: ablSize)
        defer { ablMemory.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let ablPtr = UnsafeMutableRawPointer(ablMemory).bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return }

        encode(audioBufferList: UnsafePointer(ablPtr), sourceFormat: srcFormat, inputTime: nil)
    }

    func encode(
        audioBufferList: UnsafePointer<AudioBufferList>,
        sourceFormat srcFormat: AudioStreamBasicDescription,
        inputTime: AudioTimeStamp? = nil
    ) {
        guard encodeLock.try() else {
            if !hasLoggedConcurrentEncode {
                hasLoggedConcurrentEncode = true
                LogManager.shared.log("AudioEncoder: Dropped audio delivered from a second concurrent caller")
            }
            return
        }
        defer { encodeLock.unlock() }

        let isFloatPCM = srcFormat.mFormatID == kAudioFormatLinearPCM
            && (srcFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && srcFormat.mBitsPerChannel == 32
        guard isFloatPCM, (1...2).contains(srcFormat.mChannelsPerFrame) else {
            if !hasLoggedUnsupportedFormat {
                hasLoggedUnsupportedFormat = true
                LogManager.shared.log(
                    "AudioEncoder: Unsupported tap PCM format — rate=\(Int(srcFormat.mSampleRate))Hz, "
                        + "channels=\(srcFormat.mChannelsPerFrame), bits=\(srcFormat.mBitsPerChannel), "
                        + "formatID=\(srcFormat.mFormatID), flags=0x\(String(srcFormat.mFormatFlags, radix: 16))"
                )
            }
            return
        }

        // A converter built for a different source rate pitch-shifts every
        // packet after the output device switches (e.g. 44.1 kHz ↔ 48 kHz).
        // Rebuild it and drop the stale buffered PCM instead.
        if let inputFormat, inputFormat.mSampleRate != srcFormat.mSampleRate {
            LogManager.shared.log(
                "AudioEncoder: Source rate changed \(Int(inputFormat.mSampleRate))Hz -> \(Int(srcFormat.mSampleRate))Hz; rebuilding converter"
            )
            disposeConverterAndBuffers()
        }

        // Initialize converter on first audio frame, with a retry backoff so a
        // persistently failing creation doesn't run at callback rate.
        if converter == nil,
           Date().timeIntervalSince(lastConverterCreationAttempt) >= Self.converterRetryInterval {
            lastConverterCreationAttempt = Date()
            setupConverter(sourceFormat: srcFormat)
            if converter != nil, hasLoggedConverterFailure {
                hasLoggedConverterFailure = false
                LogManager.shared.log("AudioEncoder: AAC converter recovered")
            }
        }

        guard let converter = converter else { return }

        let channels = Int(srcFormat.mChannelsPerFrame)
        let isNonInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = Int(srcFormat.mBitsPerChannel / 8)
        guard channels > 0, bytesPerSample > 0 else { return }

        let captureSampleTime: UInt64?
        if let inputTime, inputTime.mFlags.contains(.sampleTimeValid) {
            captureSampleTime = AudioSampleTimingPolicy.outputSampleTime(
                inputSampleTime: inputTime.mSampleTime,
                inputSampleRate: srcFormat.mSampleRate,
                outputSampleRate: BCConstants.audioSampleRate
            )
        } else {
            captureSampleTime = nil
        }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))

        let accumulatorWasEmpty = pcmAccumulator.isEmpty

        if isNonInterleaved && channels == 2 {
            // Non-interleaved: each buffer is one channel's float samples
            guard abl.count >= 2 else { return }
            let leftBuf = abl[0]
            let rightBuf = abl[1]

            guard let leftData = leftBuf.mData, let rightData = rightBuf.mData else { return }

            let leftFrames = Int(leftBuf.mDataByteSize) / bytesPerSample
            let rightFrames = Int(rightBuf.mDataByteSize) / bytesPerSample
            let framesPerChannel = min(leftFrames, rightFrames)
            guard framesPerChannel > 0 else { return }
            ensureInterleavedScratchCapacity(for: framesPerChannel * channels)
            interleavedScratch.withUnsafeMutableBufferPointer { scratch in
                let out = scratch.baseAddress!
                let left = leftData.assumingMemoryBound(to: Float32.self)
                let right = rightData.assumingMemoryBound(to: Float32.self)

                for i in 0..<framesPerChannel {
                    out[i * 2] = left[i]
                    out[i * 2 + 1] = right[i]
                }
                pcmAccumulator.append(
                    UnsafeRawPointer(out),
                    byteCount: framesPerChannel * channels * bytesPerSample
                )
            }
        } else if channels == 1 {
            // The wire format is always stereo. Duplicate mono rather than
            // silently creating a mono AAC packet the receiver would decode as 2ch.
            guard abl.count > 0 else { return }
            let buf = abl[0]
            guard let data = buf.mData else { return }
            let frames = Int(buf.mDataByteSize) / bytesPerSample
            guard frames > 0 else { return }
            ensureInterleavedScratchCapacity(for: frames * 2)
            interleavedScratch.withUnsafeMutableBufferPointer { scratch in
                let source = data.assumingMemoryBound(to: Float32.self)
                let destination = scratch.baseAddress!
                for frame in 0..<frames {
                    destination[frame * 2] = source[frame]
                    destination[frame * 2 + 1] = source[frame]
                }
                pcmAccumulator.append(
                    UnsafeRawPointer(destination),
                    byteCount: frames * 2 * bytesPerSample
                )
            }
        } else {
            // Interleaved stereo can be copied directly.
            guard abl.count > 0, let data = abl[0].mData else { return }
            let byteCount = Int(abl[0].mDataByteSize)
            guard byteCount > 0 else { return }
            pcmAccumulator.append(UnsafeRawPointer(data), byteCount: byteCount)
        }

        if accumulatorWasEmpty, pcmAccumulator.count > 0 {
            pcmAccumulatorStartSampleTime = captureSampleTime
        }

        // Produce AAC packets while we have enough source PCM frames buffered.
        // At 44.1 kHz, fewer than 1024 source frames represent one 48 kHz AAC
        // packet; the converter callback below still caps each request.
        let bytesNeeded = inputFramesNeededForAACPacket * bytesPerInterleavedFrame

        while pcmAccumulator.count >= bytesNeeded {
            guard let outputBuffer = aacOutputBuffer else { return }
            converterInputOffset = 0
            converterInputBytesConsumed = 0
            let outBuffer = AudioBuffer(
                mNumberChannels: interleavedChannels,
                mDataByteSize: outputBufferSize,
                mData: outputBuffer
            )
            var outBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: outBuffer)

            var ioOutputDataPacketSize: UInt32 = 1

            let convertStatus = AudioConverterFillComplexBuffer(
                converter,
                { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                    guard let userData = inUserData else {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }
                    let encoder = Unmanaged<AudioEncoder>.fromOpaque(userData).takeUnretainedValue()
                    return encoder.provideInputData(ioNumberDataPackets: ioNumberDataPackets,
                                                     ioData: ioData,
                                                     outDataPacketDescription: outDataPacketDescription)
                },
                Unmanaged.passUnretained(self).toOpaque(),
                &ioOutputDataPacketSize,
                &outBufferList,
                nil
            )
            let consumedBytes = converterInputBytesConsumed
            if consumedBytes > 0 {
                pcmAccumulator.consume(consumedBytes)
            }
            if consumedBytes == 0 {
                break
            }

            if convertStatus == noErr && outBufferList.mBuffers.mDataByteSize > 0 {
                let aacData = Data(bytes: outBufferList.mBuffers.mData!,
                                  count: Int(outBufferList.mBuffers.mDataByteSize))
                let packetSampleTime = pcmAccumulatorStartSampleTime

                frameCount += 1
                if frameCount % 100 == 1 {
                    LogManager.shared.log("AudioEncoder: Encoded AAC packet \(frameCount), \(aacData.count) bytes")
                }

                delegate?.audioEncoder(
                    self,
                    didEncode: aacData,
                    sampleTime: packetSampleTime,
                    for: connectionId
                )
                if let packetSampleTime {
                    pcmAccumulatorStartSampleTime = packetSampleTime &+ UInt64(BCConstants.aacFrameSize)
                }
            } else if convertStatus != noErr {
                frameCount += 1
                if frameCount % 200 == 1 {
                    LogManager.shared.log("AudioEncoder: Convert failed (status \(convertStatus))")
                }
                // AudioConverter may have consumed input before reporting an
                // error. Avoid attaching an unverified timestamp to the next
                // packet; the sender will use its safe synthetic fallback.
                pcmAccumulatorStartSampleTime = nil
            }
        }
    }

    private func provideInputData(ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                   ioData: UnsafeMutablePointer<AudioBufferList>,
                                   outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard pcmAccumulator.count > 0 else {
            ioNumberDataPackets.pointee = 0
            return -1
        }

        let requestedFrames = Int(ioNumberDataPackets.pointee)
        let availableFrames = pcmAccumulator.withContiguousReadableBytes(
            offset: converterInputOffset
        ) { _, byteCount in
            byteCount / bytesPerInterleavedFrame
        } ?? 0
        let framesToProvide = AudioConverterFramePolicy.framesToProvide(
            requested: requestedFrames,
            available: availableFrames
        )
        guard framesToProvide > 0 else {
            ioNumberDataPackets.pointee = 0
            return -1
        }

        let bytesToProvide = framesToProvide * bytesPerInterleavedFrame
        let status: OSStatus = pcmAccumulator.withContiguousReadableBytes(
            offset: converterInputOffset
        ) { pointer, _ in
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: pointer)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytesToProvide)
            ioData.pointee.mBuffers.mNumberChannels = interleavedChannels
            ioNumberDataPackets.pointee = UInt32(framesToProvide)
            return noErr
        } ?? -1
        if status == noErr {
            converterInputOffset += bytesToProvide
            converterInputBytesConsumed += bytesToProvide
        }

        return status
    }

    private func ensureInterleavedScratchCapacity(for floatCount: Int) {
        if interleavedScratch.count < floatCount {
            interleavedScratch = Array(repeating: 0, count: floatCount)
        }
    }

    private func setupConverter(sourceFormat: AudioStreamBasicDescription) {
        let bytesPerSample = sourceFormat.mBitsPerChannel / 8

        interleavedChannels = 2
        bytesPerInterleavedFrame = Int(bytesPerSample * interleavedChannels)

        // Input: interleaved float32 (we interleave non-interleaved data ourselves)
        var src = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerSample * interleavedChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * interleavedChannels,
            mChannelsPerFrame: interleavedChannels,
            mBitsPerChannel: sourceFormat.mBitsPerChannel,
            mReserved: 0
        )

        var dst = AudioStreamBasicDescription(
            mSampleRate: BCConstants.audioSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: BCConstants.aacFrameSize,
            mBytesPerFrame: 0,
            mChannelsPerFrame: interleavedChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let status = AudioConverterNew(&src, &dst, &converter)
        if status != noErr {
            if !hasLoggedConverterFailure {
                hasLoggedConverterFailure = true
                LogManager.shared.log(
                    "AudioEncoder: Failed to create AAC converter: \(status) "
                        + "(retrying every \(Int(Self.converterRetryInterval))s)"
                )
            }
            return
        }

        var bitrate: UInt32 = BCConstants.aacBitrate
        AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)

        inputFormat = src
        outputFormat = dst
        inputFramesNeededForAACPacket = AudioConverterFramePolicy.inputFramesNeeded(
            forOutputFrames: Int(BCConstants.aacFrameSize),
            inputSampleRate: sourceFormat.mSampleRate,
            outputSampleRate: BCConstants.audioSampleRate
        ) ?? Int(BCConstants.aacFrameSize)
        aacOutputBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(outputBufferSize),
            alignment: MemoryLayout<UInt8>.alignment
        )

        let isNonInterleaved = (sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        LogManager.shared.log(
            "AudioEncoder: Tap format rate=\(Int(sourceFormat.mSampleRate))Hz, channels=\(sourceFormat.mChannelsPerFrame), "
                + "bits=\(sourceFormat.mBitsPerChannel), bytesPerFrame=\(sourceFormat.mBytesPerFrame), "
                + "nonInterleaved=\(isNonInterleaved), flags=0x\(String(sourceFormat.mFormatFlags, radix: 16)); "
                + "output=AAC-LC \(Int(BCConstants.audioSampleRate))Hz stereo \(BCConstants.aacBitrate / 1_000)kbps"
        )
    }

    private func disposeConverterAndBuffers() {
        if let converter = converter {
            AudioConverterDispose(converter)
        }
        aacOutputBuffer?.deallocate()
        aacOutputBuffer = nil
        converter = nil
        // Intentional rebuilds (source rate changed) retry immediately; the
        // backoff only throttls persistent creation failures.
        lastConverterCreationAttempt = .distantPast
        inputFormat = nil
        outputFormat = nil
        pcmAccumulator.removeAll()
        pcmAccumulatorStartSampleTime = nil
        converterInputOffset = 0
        converterInputBytesConsumed = 0
    }

    deinit {
        aacOutputBuffer?.deallocate()
        if let converter = converter {
            AudioConverterDispose(converter)
        }
    }
}
