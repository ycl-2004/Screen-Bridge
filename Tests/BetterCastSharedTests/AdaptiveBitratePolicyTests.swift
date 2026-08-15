import XCTest
@testable import BetterCastShared

final class AdaptiveBitratePolicyTests: XCTestCase {
    func testCongestionReducesBitrate() {
        XCTAssertEqual(
            AdaptiveBitratePolicy.recommendedBitrate(
                currentBitrate: 20_000_000,
                targetBitrate: 20_000_000,
                sendLatencyEWMA: 0.09,
                sentFrames: 50,
                droppedFrames: 0
            ),
            16_000_000
        )
    }

    func testDropRateReducesBitrateEvenWithFastCompletions() {
        XCTAssertEqual(
            AdaptiveBitratePolicy.recommendedBitrate(
                currentBitrate: 10_000_000,
                targetBitrate: 20_000_000,
                sendLatencyEWMA: 0.005,
                sentFrames: 90,
                droppedFrames: 10
            ),
            8_000_000
        )
    }

    func testReductionNeverCrossesMinimum() {
        XCTAssertEqual(
            AdaptiveBitratePolicy.recommendedBitrate(
                currentBitrate: 5_000_000,
                targetBitrate: 20_000_000,
                sendLatencyEWMA: 0.2,
                sentFrames: 1,
                droppedFrames: 20
            ),
            5_000_000
        )
    }

    func testHealthyLinkRecoversGradually() {
        XCTAssertEqual(
            AdaptiveBitratePolicy.recommendedBitrate(
                currentBitrate: 10_000_000,
                targetBitrate: 20_000_000,
                sendLatencyEWMA: 0.005,
                sentFrames: 30,
                droppedFrames: 0
            ),
            11_000_000
        )
    }

    func testRecoveryDoesNotExceedUserTarget() {
        XCTAssertEqual(
            AdaptiveBitratePolicy.recommendedBitrate(
                currentBitrate: 19_500_000,
                targetBitrate: 20_000_000,
                sendLatencyEWMA: 0.005,
                sentFrames: 30,
                droppedFrames: 0
            ),
            20_000_000
        )
    }
}
