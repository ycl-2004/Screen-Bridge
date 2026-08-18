import XCTest
@testable import BetterCastShared

final class AudioPacketFramingTests: XCTestCase {
    func testPacketRoundTripsAllTimingFields() throws {
        let packet = FramedAudioPacket(
            header: AudioPacketHeader(
                sequence: 0x0102_0304,
                sampleTime: 0x0102_0304_0506_0708,
                sampleCount: 1024,
                codec: .aacLC,
                flags: 0x80
            ),
            payload: Data([0xaa, 0xbb, 0xcc])
        )

        XCTAssertEqual(try FramedAudioPacket.decode(packet.encoded()), packet)
    }

    func testRejectsTruncatedHeader() {
        XCTAssertThrowsError(try FramedAudioPacket.decode(Data(repeating: 0, count: 15))) {
            XCTAssertEqual($0 as? AudioPacketFramingError, .truncatedHeader)
        }
    }

    func testRejectsEmptyPayload() {
        var headerOnly = FramedAudioPacket(
            header: AudioPacketHeader(
                sequence: 1,
                sampleTime: 0,
                sampleCount: 1024,
                codec: .aacLC
            ),
            payload: Data([0])
        ).encoded()
        headerOnly.removeLast()

        XCTAssertThrowsError(try FramedAudioPacket.decode(headerOnly)) {
            XCTAssertEqual($0 as? AudioPacketFramingError, .emptyPayload)
        }
    }

    func testRejectsUnknownCodec() {
        var data = FramedAudioPacket(
            header: AudioPacketHeader(
                sequence: 1,
                sampleTime: 0,
                sampleCount: 1024,
                codec: .aacLC
            ),
            payload: Data([1])
        ).encoded()
        data[14] = 0xff

        XCTAssertThrowsError(try FramedAudioPacket.decode(data)) {
            XCTAssertEqual($0 as? AudioPacketFramingError, .unsupportedCodec)
        }
    }

    func testRejectsInvalidAACSampleCount() {
        var data = FramedAudioPacket(
            header: AudioPacketHeader(
                sequence: 1,
                sampleTime: 0,
                sampleCount: 1024,
                codec: .aacLC
            ),
            payload: Data([1])
        ).encoded()
        data[12] = 0
        data[13] = 0

        XCTAssertThrowsError(try FramedAudioPacket.decode(data)) {
            XCTAssertEqual($0 as? AudioPacketFramingError, .invalidSampleCount)
        }
    }

    func testSequenceTrackerReportsMissingPackets() {
        var tracker = AudioSequenceTracker()
        XCTAssertNil(tracker.observe(100))
        XCTAssertNil(tracker.observe(101))
        XCTAssertEqual(
            tracker.observe(104),
            .gap(expected: 102, received: 104, missing: 2)
        )
        XCTAssertNil(tracker.observe(105))
    }

    func testSequenceTrackerHandlesUInt32Wrap() {
        var tracker = AudioSequenceTracker()
        XCTAssertNil(tracker.observe(UInt32.max))
        XCTAssertNil(tracker.observe(0))
        XCTAssertNil(tracker.observe(1))
    }
}
