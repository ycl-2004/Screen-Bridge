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
            12_000_000
        )
    }

    /// Recovery has to outrun the bursts it is recovering for. Desktop content
    /// sits near-idle and then spikes 100x when a window is dragged; climbing at
    /// 10% per step took ~30s to get from 7 to 12 Mbps, so a burst arriving
    /// mid-climb met a bitrate far below what the link could carry and its
    /// frames were dropped.
    func testRecoveryReachesUsableBitrateQuickly() {
        var bitrate = 7_000_000
        let target = 20_000_000
        var steps = 0
        while bitrate < target, steps < 20 {
            bitrate = AdaptiveBitratePolicy.recommendedBitrate(
                currentBitrate: bitrate,
                targetBitrate: target,
                sendLatencyEWMA: 0.005,
                sentFrames: 30,
                droppedFrames: 0
            )
            steps += 1
        }
        XCTAssertEqual(bitrate, target)
        // At one adjustment per 2s, 6 steps is ~12s rather than ~30s.
        XCTAssertLessThanOrEqual(steps, 6, "recovery from a dip takes too long")
    }

    /// Climbing faster than the loop retreats makes a controller oscillate
    /// rather than settle, so recovery must never outpace backoff.
    func testClimbNeverOutpacesBackoff() {
        let congested = AdaptiveBitratePolicy.recommendedBitrate(
            currentBitrate: 20_000_000, targetBitrate: 20_000_000,
            sendLatencyEWMA: 0.005, sentFrames: 10, droppedFrames: 10
        )
        let healthy = AdaptiveBitratePolicy.recommendedBitrate(
            currentBitrate: 20_000_000, targetBitrate: 40_000_000,
            sendLatencyEWMA: 0.005, sentFrames: 30, droppedFrames: 0
        )
        let dropRatio = Double(20_000_000 - congested) / 20_000_000
        let climbRatio = Double(healthy - 20_000_000) / 20_000_000
        XCTAssertGreaterThanOrEqual(dropRatio, climbRatio)
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
