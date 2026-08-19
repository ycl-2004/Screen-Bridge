import Foundation

public enum AudioCodec: UInt8, Equatable, Sendable {
    case aacLC = 1
}

/// Flags carried by the v3 audio header.
public enum AudioPacketFlags {
    /// `sampleTime` came from a valid capture timestamp rather than the
    /// sender's monotonic packet fallback.
    public static let sampleTimeValid: UInt8 = 1 << 0
}

public enum AudioPacketFramingError: Error, Equatable, Sendable {
    case truncatedHeader
    case emptyPayload
    case invalidSampleCount
    case unsupportedCodec
}

/// Timing metadata carried before every encoded audio payload.
///
/// Wire order is fixed-width and big-endian:
/// `[sequence:4][sampleTime:8][sampleCount:2][codec:1][flags:1][payload...]`.
public struct AudioPacketHeader: Equatable, Sendable {
    public static let byteCount = 16

    public let sequence: UInt32
    public let sampleTime: UInt64
    public let sampleCount: UInt16
    public let codec: AudioCodec
    public let flags: UInt8

    public init(
        sequence: UInt32,
        sampleTime: UInt64,
        sampleCount: UInt16,
        codec: AudioCodec,
        flags: UInt8 = 0
    ) {
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.sampleCount = sampleCount
        self.codec = codec
        self.flags = flags
    }

    fileprivate func encoded() -> Data {
        var sequenceBE = sequence.bigEndian
        var sampleTimeBE = sampleTime.bigEndian
        var sampleCountBE = sampleCount.bigEndian
        var data = Data(bytes: &sequenceBE, count: MemoryLayout<UInt32>.size)
        data.append(Data(bytes: &sampleTimeBE, count: MemoryLayout<UInt64>.size))
        data.append(Data(bytes: &sampleCountBE, count: MemoryLayout<UInt16>.size))
        data.append(codec.rawValue)
        data.append(flags)
        return data
    }
}

public struct FramedAudioPacket: Equatable, Sendable {
    public let header: AudioPacketHeader
    public let payload: Data

    public init(header: AudioPacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> FramedAudioPacket {
        guard data.count >= AudioPacketHeader.byteCount else {
            throw AudioPacketFramingError.truncatedHeader
        }

        let sequence = data.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let sampleTime = data.withUnsafeBytes { raw in
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self))
        }
        let sampleCount = data.withUnsafeBytes { raw in
            UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt16.self))
        }
        // AAC-LC access units always decode to 1024 PCM frames in this protocol.
        // Reject any other value before the receiver uses it as an allocation size.
        guard sampleCount == 1024 else {
            throw AudioPacketFramingError.invalidSampleCount
        }
        guard let codec = AudioCodec(rawValue: data[data.startIndex + 14]) else {
            throw AudioPacketFramingError.unsupportedCodec
        }

        let payload = Data(data.dropFirst(AudioPacketHeader.byteCount))
        guard !payload.isEmpty else {
            throw AudioPacketFramingError.emptyPayload
        }

        return FramedAudioPacket(
            header: AudioPacketHeader(
                sequence: sequence,
                sampleTime: sampleTime,
                sampleCount: sampleCount,
                codec: codec,
                flags: data[data.startIndex + 15]
            ),
            payload: payload
        )
    }
}

public enum AudioSequenceObservation: Equatable, Sendable {
    case gap(expected: UInt32, received: UInt32, missing: UInt32)
    case nonMonotonic(expected: UInt32, received: UInt32)
}

public struct AudioSequenceTracker: Equatable, Sendable {
    public private(set) var expectedSequence: UInt32?

    public init() {}

    public mutating func observe(_ sequence: UInt32) -> AudioSequenceObservation? {
        defer { expectedSequence = sequence &+ 1 }
        guard let expectedSequence, sequence != expectedSequence else { return nil }

        let distance = sequence &- expectedSequence
        if distance < UInt32.max / 2 {
            return .gap(expected: expectedSequence, received: sequence, missing: distance)
        }
        return .nonMonotonic(expected: expectedSequence, received: sequence)
    }

    public mutating func reset() {
        expectedSequence = nil
    }
}

/// Converts capture-domain sample positions into the 48 kHz packet timeline.
/// Core Audio timestamps are only used when all inputs are finite and valid;
/// callers can then fall back to their existing synthetic counter.
public enum AudioSampleTimingPolicy {
    public static func outputSampleTime(
        inputSampleTime: Double,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> UInt64? {
        guard inputSampleTime.isFinite, inputSampleTime >= 0,
              inputSampleRate.isFinite, inputSampleRate > 0,
              outputSampleRate.isFinite, outputSampleRate > 0 else {
            return nil
        }

        let scaledSampleTime = inputSampleTime * outputSampleRate / inputSampleRate
        guard scaledSampleTime.isFinite, scaledSampleTime >= 0 else {
            return nil
        }
        return UInt64(exactly: scaledSampleTime.rounded())
    }
}

/// Frame-count rules shared by the encoder and its tests. AudioConverter asks
/// for input packets; the callback must never claim more than is available.
public enum AudioConverterFramePolicy {
    public static func inputFramesNeeded(
        forOutputFrames outputFrames: Int,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> Int? {
        guard outputFrames > 0,
              inputSampleRate.isFinite, inputSampleRate > 0,
              outputSampleRate.isFinite, outputSampleRate > 0 else {
            return nil
        }

        let frames = Double(outputFrames) * inputSampleRate / outputSampleRate
        guard frames.isFinite, frames > 0, frames < Double(Int.max) else { return nil }
        return Int(ceil(frames))
    }

    public static func framesToProvide(requested: Int, available: Int) -> Int {
        guard requested > 0, available > 0 else { return 0 }
        return min(requested, available)
    }
}

/// Small reusable byte FIFO for real-time PCM accumulation. It grows only
/// when necessary and never shifts the existing contents on every read.
public struct AudioPCMByteRingBuffer: Sendable {
    private var storage: [UInt8]
    private var readIndex = 0
    public private(set) var count = 0

    public init(capacity: Int = 64 * 1024) {
        precondition(capacity > 0)
        storage = Array(repeating: 0, count: capacity)
    }

    public var capacity: Int { storage.count }
    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ source: UnsafeRawPointer, byteCount: Int) {
        guard byteCount > 0 else { return }
        ensureCapacity(for: count + byteCount)

        let writeIndex = (readIndex + count) % storage.count
        let firstCount = min(byteCount, storage.count - writeIndex)
        storage.withUnsafeMutableBytes { rawStorage in
            let destination = rawStorage.baseAddress!.advanced(by: writeIndex)
            destination.copyMemory(from: source, byteCount: firstCount)
            if firstCount < byteCount {
                rawStorage.baseAddress!.copyMemory(
                    from: source.advanced(by: firstCount),
                    byteCount: byteCount - firstCount
                )
            }
        }
        count += byteCount
    }

    public mutating func append(_ data: Data) {
        data.withUnsafeBytes { rawData in
            guard let baseAddress = rawData.baseAddress else { return }
            append(baseAddress, byteCount: rawData.count)
        }
    }

    /// Exposes only the current contiguous prefix. The pointer is valid for
    /// the duration of `body`, which is exactly the AudioConverter callback's
    /// synchronous input-data lifetime.
    public func withContiguousReadableBytes<R>(
        offset: Int = 0,
        _ body: (UnsafeRawPointer, Int) -> R
    ) -> R? {
        guard offset >= 0, offset < count else { return nil }
        let absoluteIndex = (readIndex + offset) % storage.count
        let readableCount = min(count - offset, storage.count - absoluteIndex)
        return storage.withUnsafeBytes { rawStorage in
            body(rawStorage.baseAddress!.advanced(by: absoluteIndex), readableCount)
        }
    }

    @discardableResult
    public mutating func read(into destination: UnsafeMutableRawPointer, byteCount: Int) -> Bool {
        guard byteCount >= 0, byteCount <= count else { return false }
        guard byteCount > 0 else { return true }

        let firstCount = min(byteCount, storage.count - readIndex)
        storage.withUnsafeBytes { rawStorage in
            destination.copyMemory(
                from: rawStorage.baseAddress!.advanced(by: readIndex),
                byteCount: firstCount
            )
            if firstCount < byteCount {
                destination.advanced(by: firstCount).copyMemory(
                    from: rawStorage.baseAddress!,
                    byteCount: byteCount - firstCount
                )
            }
        }
        consume(byteCount)
        return true
    }

    public mutating func consume(_ byteCount: Int) {
        precondition(byteCount >= 0 && byteCount <= count)
        guard byteCount > 0 else { return }
        readIndex = (readIndex + byteCount) % storage.count
        count -= byteCount
        if count == 0 { readIndex = 0 }
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        count = 0
        readIndex = 0
        if !keepingCapacity {
            storage.removeAll(keepingCapacity: false)
        }
    }

    private mutating func ensureCapacity(for requiredCount: Int) {
        guard requiredCount > storage.count else { return }

        var newCapacity = storage.count
        while newCapacity < requiredCount {
            newCapacity *= 2
        }

        var newStorage = Array(repeating: UInt8(0), count: newCapacity)
        if count > 0 {
            let firstCount = min(count, storage.count - readIndex)
            storage.withUnsafeBytes { oldStorage in
                newStorage.withUnsafeMutableBytes { replacement in
                    replacement.baseAddress!.copyMemory(
                        from: oldStorage.baseAddress!.advanced(by: readIndex),
                        byteCount: firstCount
                    )
                    if firstCount < count {
                        replacement.baseAddress!.advanced(by: firstCount).copyMemory(
                            from: oldStorage.baseAddress!,
                            byteCount: count - firstCount
                        )
                    }
                }
            }
        }
        storage = newStorage
        readIndex = 0
    }
}

public enum AudioSendQueuePolicy {
    /// Includes the packet currently owned by Network.framework.
    public static let maxBufferedPackets = 8
    public static let maxPendingPacketsWhileSending = maxBufferedPackets - 1
}

/// FIFO for packets waiting behind the one in flight. When full, the oldest
/// waiting packet is discarded so latency remains bounded and the sequence gap
/// stays visible to the receiver.
public struct BoundedAudioPacketFIFO: Sendable {
    public let capacity: Int
    public private(set) var packets: [Data] = []

    public init(capacity: Int = AudioSendQueuePolicy.maxPendingPacketsWhileSending) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { packets.count }
    public var isEmpty: Bool { packets.isEmpty }

    @discardableResult
    public mutating func enqueue(_ packet: Data) -> Data? {
        let dropped = packets.count == capacity ? packets.removeFirst() : nil
        packets.append(packet)
        return dropped
    }

    public mutating func dequeue() -> Data? {
        guard !packets.isEmpty else { return nil }
        return packets.removeFirst()
    }

    public mutating func removeAll() {
        packets.removeAll(keepingCapacity: true)
    }
}

/// State transitions for the decoded-PCM jitter buffer. Five AAC-LC packets at
/// 48 kHz are about 107 ms; the same threshold is used for first start and for
/// recovery after an underrun.
public struct AudioJitterBufferState: Equatable, Sendable {
    public static let startPendingBuffers = 5
    public static let maxPendingBuffers = 10

    public private(set) var pendingBuffers = 0
    public private(set) var isPlaying = false

    public init() {}

    public var shouldDropIncomingBuffer: Bool {
        pendingBuffers >= Self.maxPendingBuffers
    }

    /// Returns true when playback should start or resume.
    @discardableResult
    public mutating func bufferScheduled() -> Bool {
        pendingBuffers += 1
        guard !isPlaying, pendingBuffers >= Self.startPendingBuffers else {
            return false
        }
        isPlaying = true
        return true
    }

    /// Returns true when playback exhausted the queue and must rebuffer.
    @discardableResult
    public mutating func bufferCompleted() -> Bool {
        pendingBuffers = max(pendingBuffers - 1, 0)
        guard isPlaying, pendingBuffers == 0 else { return false }
        isPlaying = false
        return true
    }

    public mutating func reset() {
        pendingBuffers = 0
        isPlaying = false
    }
}
