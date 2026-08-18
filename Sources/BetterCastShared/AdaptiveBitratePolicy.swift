import Foundation

/// Pure policy for bounded video bitrate adaptation.
///
/// Network.framework send completion latency and backpressure drops are used as
/// congestion signals. The user-selected quality remains the upper bound, while
/// `minimumBitrate` prevents a transient stall from collapsing picture quality
/// indefinitely.
public enum AdaptiveBitratePolicy {
    public static func recommendedBitrate(
        currentBitrate: Int,
        targetBitrate: Int,
        minimumBitrate: Int = 5_000_000,
        sendLatencyEWMA: TimeInterval,
        sentFrames: Int,
        droppedFrames: Int
    ) -> Int {
        guard currentBitrate > 0, targetBitrate > 0 else { return 0 }

        let upperBound = max(1, targetBitrate)
        let lowerBound = min(max(1, minimumBitrate), upperBound)
        let current = min(max(currentBitrate, lowerBound), upperBound)
        let totalFrames = max(sentFrames + droppedFrames, 1)
        let dropRatio = Double(droppedFrames) / Double(totalFrames)

        if dropRatio >= 0.08 || sendLatencyEWMA >= 0.075 {
            return max(lowerBound, Int(Double(current) * 0.80))
        }

        if sentFrames >= 10,
           droppedFrames == 0,
           sendLatencyEWMA > 0,
           sendLatencyEWMA <= 0.015,
           current < upperBound {
            // Climb 20% per step instead of 10%. Recovery used to take ~30s to
            // get from 7 to 12 Mbps, so a burst arriving mid-climb met a bitrate
            // far below what the link could carry and its frames were dropped.
            // Kept exactly at the 20% backoff rate and no higher: climbing
            // faster than the loop retreats is how a controller starts
            // oscillating instead of settling.
            return min(upperBound, current + max(1_000_000, current / 5))
        }

        return current
    }
}
