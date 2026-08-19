import XCTest
@testable import BetterCastShared

/// Applying one-frame backpressure to every transport capped USB/Thunderbolt at
/// one frame per round trip and produced drops on a link with 0 ms measured
/// latency, which then pulled the adaptive bitrate down from 100 to 80 Mbps.
final class VideoFlightWindowPolicyTests: XCTestCase {

    func testReliableLinksGetHeadroom() {
        let cases: [(name: String, p2p: Bool, wired: Bool)] = [
            ("USB/Thunderbolt", false, true),
            ("peer-to-peer", true, false),
        ]
        for c in cases {
            XCTAssertEqual(
                VideoFlightWindowPolicy.maxFramesInFlight(
                    isP2P: c.p2p, isWiredCable: c.wired
                ),
                VideoFlightWindowPolicy.reliableLinkWindow,
                "\(c.name) must not be gated at a single frame"
            )
        }
    }

    func testSharedLinksStayConservative() {
        XCTAssertEqual(
            VideoFlightWindowPolicy.maxFramesInFlight(
                isP2P: false, isWiredCable: false
            ),
            VideoFlightWindowPolicy.sharedLinkWindow
        )
    }

    /// The point of the fix: reliable links must be strictly roomier than the
    /// shared-WiFi default, which is what regressed.
    func testReliableWindowIsWiderThanShared() {
        XCTAssertGreaterThan(
            VideoFlightWindowPolicy.reliableLinkWindow,
            VideoFlightWindowPolicy.sharedLinkWindow
        )
    }

    /// Still bounded — an unbounded queue was the original reason backpressure
    /// was introduced, and a genuinely stalled link must not accumulate latency.
    func testWindowStaysBounded() {
        XCTAssertLessThanOrEqual(VideoFlightWindowPolicy.reliableLinkWindow, 8)
        XCTAssertGreaterThanOrEqual(VideoFlightWindowPolicy.sharedLinkWindow, 1)
    }

    func testVideoTransferRateUsesActualElapsedTime() {
        XCTAssertEqual(
            VideoTransferRatePolicy.megabitsPerSecond(
                byteCount: 250_000,
                elapsedSeconds: 2
            ),
            1.0,
            accuracy: 0.000_001
        )
    }

    func testVideoTransferRateRejectsInvalidIntervals() {
        XCTAssertEqual(
            VideoTransferRatePolicy.megabitsPerSecond(
                byteCount: 250_000,
                elapsedSeconds: 0
            ),
            0
        )
        XCTAssertEqual(
            VideoTransferRatePolicy.megabitsPerSecond(
                byteCount: 250_000,
                elapsedSeconds: .infinity
            ),
            0
        )
    }
}
