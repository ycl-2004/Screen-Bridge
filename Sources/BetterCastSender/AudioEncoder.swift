import Foundation
import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia

protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(_ encoder: AudioEncoder, didEncode data: Data, for connectionId: UUID)
}

final class AudioEncoder: @unchecked Sendable {
    weak var delegate: AudioEncoderDelegate?
    let connectionId: UUID

    private var converter: AudioConverterRef?
    private var inputFormat: AudioStreamBasicDescription?
    private var outputFormat: AudioStreamBasicDescription?
    private var frameCount = 0
    private var hasLoggedUnsupportedFormat = false

    // Interleaved PCM ring buffer — accumulates until we have 1024+ frames for AAC
    private var pcmAccumulator = Data()
    private var interleavedChannels: UInt32 = 2
    private var bytesPerInterleavedFrame: Int = 8 // channels * sizeof(Float32)

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

        encode(audioBufferList: UnsafePointer(ablPtr), sourceFormat: srcFormat)
    }

    func encode(audioBufferList: UnsafePointer<AudioBufferList>, sourceFormat srcFormat: AudioStreamBasicDescription) {
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

        // Initialize converter on first audio frame
        if converter == nil {
            setupConverter(sourceFormat: srcFormat)
        }

        guard let converter = converter else { return }

        let channels = Int(srcFormat.mChannelsPerFrame)
        let isNonInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = Int(srcFormat.mBitsPerChannel / 8)
        guard channels > 0, bytesPerSample > 0 else { return }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))

        if isNonInterleaved && channels == 2 && abl.count >= 2 {
            // Non-interleaved: each buffer is one channel's float samples
            let leftBuf = abl[0]
            let rightBuf = abl[1]

            guard let leftData = leftBuf.mData, let rightData = rightBuf.mData else { return }

            let framesPerChannel = Int(leftBuf.mDataByteSize) / bytesPerSample
            var interleaved = Data(count: framesPerChannel * channels * bytesPerSample)

            interleaved.withUnsafeMutableBytes { outBuf in
                let out = outBuf.baseAddress!.assumingMemoryBound(to: Float32.self)
                let left = leftData.assumingMemoryBound(to: Float32.self)
                let right = rightData.assumingMemoryBound(to: Float32.self)

                for i in 0..<framesPerChannel {
                    out[i * 2] = left[i]
                    out[i * 2 + 1] = right[i]
                }
            }

            pcmAccumulator.append(interleaved)
        } else if channels == 1 {
            // The wire format is always stereo. Duplicate mono rather than
            // silently creating a mono AAC packet the receiver would decode as 2ch.
            guard abl.count > 0 else { return }
            let buf = abl[0]
            guard let data = buf.mData else { return }
            let frames = Int(buf.mDataByteSize) / bytesPerSample
            var stereo = Data(count: frames * 2 * bytesPerSample)
            stereo.withUnsafeMutableBytes { output in
                let source = data.assumingMemoryBound(to: Float32.self)
                let destination = output.baseAddress!.assumingMemoryBound(to: Float32.self)
                for frame in 0..<frames {
                    destination[frame * 2] = source[frame]
                    destination[frame * 2 + 1] = source[frame]
                }
            }
            pcmAccumulator.append(stereo)
        } else {
            // Interleaved stereo can be copied directly.
            guard abl.count > 0, let data = abl[0].mData else { return }
            pcmAccumulator.append(Data(bytes: data, count: Int(abl[0].mDataByteSize)))
        }

        // Produce AAC packets while we have enough PCM frames buffered
        let framesNeeded = Int(BCConstants.aacFrameSize)
        let bytesNeeded = framesNeeded * bytesPerInterleavedFrame

        while pcmAccumulator.count >= bytesNeeded {
            let chunk = pcmAccumulator.prefix(bytesNeeded)
            pcmAccumulator.removeFirst(bytesNeeded)

            // Store for callback
            currentChunk = chunk
            currentChunkOffset = 0

            let outputBufferSize: UInt32 = 8192
            let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(outputBufferSize))
            defer { outputBuffer.deallocate() }

            let outBuffer = AudioBuffer(
                mNumberChannels: interleavedChannels,
                mDataByteSize: outputBufferSize,
                mData: UnsafeMutableRawPointer(outputBuffer)
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

            if convertStatus == noErr && outBufferList.mBuffers.mDataByteSize > 0 {
                let aacData = Data(bytes: outBufferList.mBuffers.mData!,
                                  count: Int(outBufferList.mBuffers.mDataByteSize))

                frameCount += 1
                if frameCount % 100 == 1 {
                    LogManager.shared.log("AudioEncoder: Encoded AAC packet \(frameCount), \(aacData.count) bytes")
                }

                delegate?.audioEncoder(self, didEncode: aacData, for: connectionId)
            } else if convertStatus != noErr {
                frameCount += 1
                if frameCount % 200 == 1 {
                    LogManager.shared.log("AudioEncoder: Convert failed (status \(convertStatus))")
                }
            }
        }

        currentChunk = nil
    }

    // Input data for the current 1024-frame chunk
    private var currentChunk: Data?
    private var currentChunkOffset: Int = 0

    private func provideInputData(ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                   ioData: UnsafeMutablePointer<AudioBufferList>,
                                   outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard let chunk = currentChunk, currentChunkOffset < chunk.count else {
            ioNumberDataPackets.pointee = 0
            return -1
        }

        let remaining = chunk.count - currentChunkOffset
        chunk.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress!.advanced(by: currentChunkOffset)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(remaining)
            ioData.pointee.mBuffers.mNumberChannels = interleavedChannels
        }

        let frames = remaining / bytesPerInterleavedFrame
        ioNumberDataPackets.pointee = UInt32(frames)
        currentChunkOffset = chunk.count

        return noErr
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
            LogManager.shared.log("AudioEncoder: Failed to create AAC converter: \(status)")
            return
        }

        var bitrate: UInt32 = BCConstants.aacBitrate
        AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)

        inputFormat = src
        outputFormat = dst

        let isNonInterleaved = (sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        LogManager.shared.log(
            "AudioEncoder: Tap format rate=\(Int(sourceFormat.mSampleRate))Hz, channels=\(sourceFormat.mChannelsPerFrame), "
                + "bits=\(sourceFormat.mBitsPerChannel), bytesPerFrame=\(sourceFormat.mBytesPerFrame), "
                + "nonInterleaved=\(isNonInterleaved), flags=0x\(String(sourceFormat.mFormatFlags, radix: 16)); "
                + "output=AAC-LC \(Int(BCConstants.audioSampleRate))Hz stereo \(BCConstants.aacBitrate / 1_000)kbps"
        )
    }

    deinit {
        if let converter = converter {
            AudioConverterDispose(converter)
        }
    }
}
