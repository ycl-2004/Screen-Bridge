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
                flags: AudioPacketFlags.sampleTimeValid
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

    func testCaptureSampleTimeScalesToOutputTimeline() {
        XCTAssertEqual(
            AudioSampleTimingPolicy.outputSampleTime(
                inputSampleTime: 44_100,
                inputSampleRate: 44_100,
                outputSampleRate: 48_000
            ),
            48_000
        )
        XCTAssertNil(
            AudioSampleTimingPolicy.outputSampleTime(
                inputSampleTime: .nan,
                inputSampleRate: 48_000,
                outputSampleRate: 48_000
            )
        )
        XCTAssertNil(
            AudioSampleTimingPolicy.outputSampleTime(
                inputSampleTime: .greatestFiniteMagnitude,
                inputSampleRate: 48_000,
                outputSampleRate: 48_000
            )
        )
    }

    func testConverterFramePolicyHonorsSourceRateAndRequestLimit() {
        XCTAssertEqual(
            AudioConverterFramePolicy.inputFramesNeeded(
                forOutputFrames: 1024,
                inputSampleRate: 44_100,
                outputSampleRate: 48_000
            ),
            941
        )
        XCTAssertEqual(
            AudioConverterFramePolicy.framesToProvide(requested: 512, available: 300),
            300
        )
        XCTAssertEqual(
            AudioConverterFramePolicy.framesToProvide(requested: 512, available: 900),
            512
        )
        XCTAssertNil(
            AudioConverterFramePolicy.inputFramesNeeded(
                forOutputFrames: 1024,
                inputSampleRate: 0,
                outputSampleRate: 48_000
            )
        )
    }

    func testPCMByteRingPreservesOrderAcrossWrapAndGrowth() {
        var ring = AudioPCMByteRingBuffer(capacity: 4)
        append([1, 2, 3], to: &ring)

        var firstRead = [UInt8](repeating: 0, count: 2)
        XCTAssertTrue(firstRead.withUnsafeMutableBytes { raw in
            ring.read(into: raw.baseAddress!, byteCount: raw.count)
        })
        XCTAssertEqual(firstRead, [1, 2])

        append([4, 5, 6, 7], to: &ring)
        XCTAssertGreaterThanOrEqual(ring.capacity, 5)

        var secondRead = [UInt8](repeating: 0, count: 5)
        XCTAssertTrue(secondRead.withUnsafeMutableBytes { raw in
            ring.read(into: raw.baseAddress!, byteCount: raw.count)
        })
        XCTAssertEqual(secondRead, [3, 4, 5, 6, 7])
        XCTAssertTrue(ring.isEmpty)
    }

    private func append(_ bytes: [UInt8], to ring: inout AudioPCMByteRingBuffer) {
        bytes.withUnsafeBytes { raw in
            ring.append(raw.baseAddress!, byteCount: raw.count)
        }
    }
}
