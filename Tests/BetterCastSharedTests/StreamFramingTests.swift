import XCTest
@testable import BetterCastShared

/// Bounds checks for the length-prefixed wire protocol.
///
/// Before these existed, every `receive` path took the raw `UInt32` length from
/// the peer and passed it straight to `NWConnection.receive` as `maximumLength`.
/// A peer could therefore ask the other side to buffer ~4 GiB.
final class StreamFrameLengthTests: XCTestCase {

    func testRejectsZeroLengthFrame() {
        XCTAssertThrowsError(
            try StreamFraming.validateBodyLength(0, limit: StreamFraming.maxControlFrameBytes)
        ) { error in
            XCTAssertEqual(error as? StreamFramingError, .emptyFrame)
        }
    }

    func testRejectsFrameLargerThanLimit() {
        let oversize = UInt32(StreamFraming.maxControlFrameBytes + 1)
        XCTAssertThrowsError(
            try StreamFraming.validateBodyLength(oversize, limit: StreamFraming.maxControlFrameBytes)
        ) { error in
            XCTAssertEqual(error as? StreamFramingError, .frameTooLarge)
        }
    }

    func testRejectsMaximumUInt32() {
        XCTAssertThrowsError(
            try StreamFraming.validateBodyLength(UInt32.max, limit: StreamFraming.maxVideoFrameBytes)
        ) { error in
            XCTAssertEqual(error as? StreamFramingError, .frameTooLarge)
        }
    }

    func testAcceptsFrameExactlyAtLimit() throws {
        let atLimit = UInt32(StreamFraming.maxControlFrameBytes)
        let length = try StreamFraming.validateBodyLength(atLimit, limit: StreamFraming.maxControlFrameBytes)
        XCTAssertEqual(length, StreamFraming.maxControlFrameBytes)
    }

    func testAcceptsOrdinaryFrame() throws {
        let length = try StreamFraming.validateBodyLength(1024, limit: StreamFraming.maxVideoFrameBytes)
        XCTAssertEqual(length, 1024)
    }

    func testVideoLimitIsLargerThanControlLimit() {
        // Video frames legitimately dwarf control messages; keeping separate
        // limits stops a control channel from being used to request a huge read.
        XCTAssertGreaterThan(StreamFraming.maxVideoFrameBytes, StreamFraming.maxControlFrameBytes)
    }

    func testHeaderDecodingRejectsShortHeader() {
        XCTAssertNil(StreamFraming.bodyLength(fromHeader: Data([0, 0, 1])))
    }

    func testHeaderDecodingReadsBigEndianLength() {
        // 0x00000200 == 512
        let header = Data([0x00, 0x00, 0x02, 0x00])
        XCTAssertEqual(StreamFraming.bodyLength(fromHeader: header), 512)
    }
}

/// AVCC (length-prefixed H.264) parsing.
///
/// The iOS decoder previously read `videoData[offset + 4]` after only checking
/// `offset + 4 + naluLen > totalLen`. With `naluLen == 0` that check passes at
/// the very end of the buffer and the read traps.
final class AVCCParserTests: XCTestCase {

    private func avcc(_ nalus: [Data]) -> Data {
        var out = Data()
        for nalu in nalus {
            var length = UInt32(nalu.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            out.append(nalu)
        }
        return out
    }

    private func nalu(type: UInt8, payloadLength: Int = 8) -> Data {
        var data = Data([type & 0x1F])
        data.append(Data(repeating: 0xAB, count: payloadLength))
        return data
    }

    func testZeroLengthNALUAtEndOfBufferDoesNotTrap() {
        // The exact crash shape: a 4-byte zero length and nothing after it.
        let data = Data([0x00, 0x00, 0x00, 0x00])
        let result = AVCCParser.parse(data)
        XCTAssertTrue(result.isMalformed)
        XCTAssertNil(result.sps)
        XCTAssertNil(result.pps)
    }

    func testZeroLengthNALUBetweenValidUnitsIsRejected() {
        var data = avcc([nalu(type: 7)])
        data.append(Data([0x00, 0x00, 0x00, 0x00]))
        data.append(avcc([nalu(type: 8)]))

        let result = AVCCParser.parse(data)
        XCTAssertTrue(result.isMalformed)
    }

    func testTruncatedNALUIsRejected() {
        // Declares 100 bytes but only 4 follow.
        var data = Data([0x00, 0x00, 0x00, 0x64])
        data.append(Data(repeating: 0x01, count: 4))

        let result = AVCCParser.parse(data)
        XCTAssertTrue(result.isMalformed)
    }

    func testDanglingBytesShorterThanLengthPrefixAreRejected() {
        var data = avcc([nalu(type: 7)])
        data.append(Data([0x00, 0x00]))

        let result = AVCCParser.parse(data)
        XCTAssertTrue(result.isMalformed)
    }

    func testEmptyDataIsMalformed() {
        let result = AVCCParser.parse(Data())
        XCTAssertTrue(result.isMalformed)
    }

    func testExtractsSPSAndPPS() {
        let sps = nalu(type: 7, payloadLength: 12)
        let pps = nalu(type: 8, payloadLength: 4)
        let idr = nalu(type: 5, payloadLength: 40)

        let result = AVCCParser.parse(avcc([sps, pps, idr]))

        XCTAssertFalse(result.isMalformed)
        XCTAssertEqual(result.sps, sps)
        XCTAssertEqual(result.pps, pps)
    }

    func testReportsKeyframeWhenIDRPresent() {
        let result = AVCCParser.parse(avcc([nalu(type: 7), nalu(type: 8), nalu(type: 5)]))
        XCTAssertTrue(result.containsKeyframe)
    }

    func testDoesNotReportKeyframeForPFrameOnly() {
        let result = AVCCParser.parse(avcc([nalu(type: 1, payloadLength: 30)]))
        XCTAssertFalse(result.isMalformed)
        XCTAssertFalse(result.containsKeyframe)
    }

    func testSingleByteNALUIsValid() {
        // A 1-byte NALU is legal: header only, no payload.
        let result = AVCCParser.parse(avcc([Data([0x07])]))
        XCTAssertFalse(result.isMalformed)
        XCTAssertEqual(result.sps, Data([0x07]))
    }

    func testHugeDeclaredLengthDoesNotOverflow() {
        var data = Data()
        var length = UInt32.max.bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(Data(repeating: 0x00, count: 16))

        let result = AVCCParser.parse(data)
        XCTAssertTrue(result.isMalformed)
    }
}

/// The video payload is `[PTS: 8 bytes][AVCC NALUs...]`.
final class VideoPayloadTests: XCTestCase {

    func testRejectsPayloadShorterThanTimestampHeader() {
        XCTAssertNil(StreamFraming.splitVideoPayload(Data(repeating: 0, count: 8)))
    }

    func testSplitsTimestampFromNALUs() throws {
        var payload = Data()
        var pts = UInt64(123_456_789)
        payload.append(Data(bytes: &pts, count: 8))
        payload.append(Data([0x00, 0x00, 0x00, 0x01, 0x07]))

        let split = try XCTUnwrap(StreamFraming.splitVideoPayload(payload))
        XCTAssertEqual(split.presentationTimeNanos, 123_456_789)
        XCTAssertEqual(split.accessUnit, Data([0x00, 0x00, 0x00, 0x01, 0x07]))
    }
}
