import XCTest
@testable import BetterCastShared

/// Applying one-frame backpressure to every transport capped USB/Thunderbolt at
/// one frame per round trip and produced drops on a link with 0 ms measured
/// latency, which then pulled the adaptive bitrate down from 100 to 80 Mbps.
final class VideoFlightWindowPolicyTests: XCTestCase {

    func testReliableLinksGetHeadroom() {
        let cases: [(name: String, p2p: Bool, wired: Bool, loopback: Bool)] = [
            ("USB/Thunderbolt", false, true, false),
            ("peer-to-peer", true, false, false),
            ("loopback", false, false, true),
        ]
        for c in cases {
            XCTAssertEqual(
                VideoFlightWindowPolicy.maxFramesInFlight(
                    isP2P: c.p2p, isWiredCable: c.wired, isLoopback: c.loopback
                ),
                VideoFlightWindowPolicy.reliableLinkWindow,
                "\(c.name) must not be gated at a single frame"
            )
        }
    }

    func testSharedLinksStayConservative() {
        XCTAssertEqual(
            VideoFlightWindowPolicy.maxFramesInFlight(
                isP2P: false, isWiredCable: false, isLoopback: false
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
}
