import Foundation

public enum StreamFramingError: Error, Equatable {
    /// A peer declared a zero-length body. Nothing on the wire is legitimately empty.
    case emptyFrame
    /// A peer declared a body larger than the protocol allows for this channel.
    case frameTooLarge
    /// The connection ended before the declared body arrived in full.
    case truncatedFrame
}

/// Bounds for the length-prefixed wire protocol.
///
/// Every frame is `[UInt32 big-endian body length][body]`. The length comes from
/// the peer, so it is untrusted input even after pairing succeeds: a buggy or
/// hostile paired device must not be able to make the other side allocate an
/// arbitrary buffer or block forever waiting for bytes that never arrive.
///
/// Limits are per channel so a control message can never request a video-sized read.
public enum StreamFraming {

    /// Handshake messages are small JSON blobs (nonces and proofs).
    public static let maxHandshakeFrameBytes = 64 * 1024

    /// Control messages are authenticated envelopes wrapping a small event.
    public static let maxControlFrameBytes = 64 * 1024

    /// One coalesced H.264 access unit. A 4K keyframe at high bitrate stays far
    /// below this; the limit exists to bound the worst case, not to shape traffic.
    public static let maxVideoFrameBytes = 16 * 1024 * 1024

    /// Type byte, fixed audio header, and one encoded AAC-LC access unit.
    public static let maxAudioFrameBytes = 64 * 1024

    /// Used where video and audio share a connection and the type is not yet known.
    public static var maxMediaFrameBytes: Int { maxVideoFrameBytes }

    /// Type bytes prefixing sender→receiver frames on the media transport.
    ///
    /// `0x05` carries sender control (heartbeat, disconnect notice) sealed in
    /// an `AuthenticatedEnvelope`; the receiver no longer honors the bare
    /// `0x03`/`0x04` forms, so an on-path attacker cannot forge them.
    public enum SenderControlTypeByte {
        public static let video: UInt8 = 0x01
        public static let audio: UInt8 = 0x02
        public static let authenticatedControl: UInt8 = 0x05
        public static let disconnectCommand: UInt8 = 0x03
        public static let heartbeatCommand: UInt8 = 0x04

        /// Whether a first body byte marks type-byte framing (as opposed to the
        /// legacy raw-video framing used by older desktop senders).
        public static func isFramingMarker(_ byte: UInt8) -> Bool {
            switch byte {
            case video, audio, disconnectCommand, heartbeatCommand, authenticatedControl:
                return true
            default:
                return false
            }
        }
    }

    /// Validates a peer-supplied body length against a channel limit.
    public static func validateBodyLength(_ raw: UInt32, limit: Int) throws -> Int {
        guard raw > 0 else { throw StreamFramingError.emptyFrame }
        guard raw <= UInt32(clamping: limit) else { throw StreamFramingError.frameTooLarge }
        return Int(raw)
    }

    /// Reads the big-endian body length from a 4-byte header.
    public static func bodyLength(fromHeader header: Data) -> UInt32? {
        guard header.count >= 4 else { return nil }
        return header.withUnsafeBytes { raw -> UInt32 in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
    }

    /// Splits a video payload of `[PTS: 8 bytes native-endian][AVCC NALUs...]`.
    ///
    /// The byte order matches what `VideoEncoder` writes; it is deliberately not
    /// normalised here so existing receivers stay compatible.
    public static func splitVideoPayload(_ data: Data) -> (presentationTimeNanos: UInt64, accessUnit: Data)? {
        guard data.count > 8 else { return nil }
        let pts = data.withUnsafeBytes { raw -> UInt64 in
            raw.loadUnaligned(as: UInt64.self)
        }
        return (pts, Data(data.dropFirst(8)))
    }
}

/// Outcome of parsing one AVCC access unit.
public struct AVCCParseResult: Equatable {
    public let sps: Data?
    public let pps: Data?
    public let containsKeyframe: Bool
    public let isMalformed: Bool

    public init(sps: Data?, pps: Data?, containsKeyframe: Bool, isMalformed: Bool) {
        self.sps = sps
        self.pps = pps
        self.containsKeyframe = containsKeyframe
        self.isMalformed = isMalformed
    }
}

/// Parser for length-prefixed (AVCC) H.264 access units.
///
/// The previous inline scanner checked `offset + 4 + naluLen > totalLen` before
/// reading the NALU header byte. With `naluLen == 0` that check passes at the end
/// of the buffer and `data[offset + 4]` traps. This parser requires every NALU to
/// carry at least its 1-byte header and requires the buffer to be consumed exactly.
public enum AVCCParser {

    private static let lengthPrefixSize = 4

    public static func parse(_ data: Data) -> AVCCParseResult {
        guard !data.isEmpty else { return malformed() }

        var sps: Data?
        var pps: Data?
        var containsKeyframe = false

        let result: AVCCParseResult? = data.withUnsafeBytes { raw -> AVCCParseResult? in
            let total = raw.count
            var offset = 0

            while offset < total {
                // Need a full length prefix.
                guard total - offset >= lengthPrefixSize else { return malformed() }

                let declared = UInt32(
                    bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                )

                // A NALU always carries at least its header byte.
                guard declared >= 1 else { return malformed() }

                let remaining = total - offset - lengthPrefixSize
                guard Int(declared) <= remaining else { return malformed() }

                let naluStart = offset + lengthPrefixSize
                let naluType = raw[naluStart] & 0x1F

                switch naluType {
                case 5:
                    containsKeyframe = true
                case 7 where sps == nil:
                    sps = Data(bytes: raw.baseAddress!.advanced(by: naluStart), count: Int(declared))
                case 8 where pps == nil:
                    pps = Data(bytes: raw.baseAddress!.advanced(by: naluStart), count: Int(declared))
                default:
                    break
                }

                offset = naluStart + Int(declared)
            }

            return nil // consumed exactly; fall through to the success result
        }

        if let malformedResult = result { return malformedResult }

        return AVCCParseResult(
            sps: sps,
            pps: pps,
            containsKeyframe: containsKeyframe,
            isMalformed: false
        )
    }

    private static func malformed() -> AVCCParseResult {
        AVCCParseResult(sps: nil, pps: nil, containsKeyframe: false, isMalformed: true)
    }
}

public enum MediaLivenessFailure: String, Equatable, Sendable {
    case transportHeartbeatStopped
    case noDecodableFirstFrame
    case decoderStalled
    case rendererStalled
}

/// Pure, testable health policy for a receiver media session. Dates represent
/// distinct progress boundaries; receiving a packet never advances decode or
/// render progress implicitly.
public struct MediaLivenessSnapshot: Equatable, Sendable {
    public let sessionStartedAt: Date
    public let lastMediaHeartbeat: Date
    public let lastVideoAccessUnitReceived: Date
    public let lastVideoDecoded: Date
    public let lastVideoRendered: Date
    public let hasDecodedFrame: Bool
    public let hasRenderedFrame: Bool

    public init(
        sessionStartedAt: Date,
        lastMediaHeartbeat: Date,
        lastVideoAccessUnitReceived: Date,
        lastVideoDecoded: Date,
        lastVideoRendered: Date,
        hasDecodedFrame: Bool,
        hasRenderedFrame: Bool
    ) {
        self.sessionStartedAt = sessionStartedAt
        self.lastMediaHeartbeat = lastMediaHeartbeat
        self.lastVideoAccessUnitReceived = lastVideoAccessUnitReceived
        self.lastVideoDecoded = lastVideoDecoded
        self.lastVideoRendered = lastVideoRendered
        self.hasDecodedFrame = hasDecodedFrame
        self.hasRenderedFrame = hasRenderedFrame
    }
}

public enum MediaLivenessEvaluator {
    public static func failure(
        for snapshot: MediaLivenessSnapshot,
        now: Date,
        timeout: TimeInterval
    ) -> MediaLivenessFailure? {
        if now.timeIntervalSince(snapshot.lastMediaHeartbeat) > timeout {
            return .transportHeartbeatStopped
        }
        if !snapshot.hasRenderedFrame,
           now.timeIntervalSince(snapshot.sessionStartedAt) > timeout {
            return .noDecodableFirstFrame
        }
        // A stalled stage is one that is falling behind work that is still
        // arriving. On a static extended desktop ScreenCaptureKit stops
        // producing frames entirely, so an old undecoded access unit is simply
        // the last thing that was sent — not evidence of a stuck decoder. Only
        // treat a stage as stalled while its input is still fresh; the
        // transport heartbeat above already covers a genuinely dead link.
        if snapshot.hasDecodedFrame,
           snapshot.lastVideoAccessUnitReceived > snapshot.lastVideoDecoded,
           now.timeIntervalSince(snapshot.lastVideoAccessUnitReceived) <= timeout,
           now.timeIntervalSince(snapshot.lastVideoDecoded) > timeout {
            return .decoderStalled
        }
        if snapshot.hasRenderedFrame,
           snapshot.lastVideoDecoded > snapshot.lastVideoRendered,
           now.timeIntervalSince(snapshot.lastVideoDecoded) <= timeout,
           now.timeIntervalSince(snapshot.lastVideoRendered) > timeout {
            return .rendererStalled
        }
        return nil
    }
}
