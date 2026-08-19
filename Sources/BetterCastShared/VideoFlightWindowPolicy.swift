import Foundation

/// How many encoded video frames may be in flight on a link at once.
///
/// Backpressure used to be applied uniformly to every transport, gating all of
/// them at a single frame. On USB/Thunderbolt and peer-to-peer links —
/// which have both high bandwidth and low latency — that capped throughput at
/// one frame per round trip and produced drops on links that were not congested
/// at all, which in turn dragged the adaptive bitrate down. Those links
/// previously ran with no completion gating whatsoever and were the most stable
/// paths available, so they get real headroom back here while the queue stays
/// bounded.
public enum VideoFlightWindowPolicy {
    public static let reliableLinkWindow = 4
    /// Two, not one. Desktop content is extremely bursty: a static screen encodes
    /// to a few hundred bytes while dragging a window produces 60–75 KB frames —
    /// a 100x swing. At one frame in flight the very first burst frame fills the
    /// window and every following frame is dropped until it completes, which is
    /// exactly the stutter felt when dragging a window onto the extended display.
    /// Two frames absorb the burst while still bounding the queue.
    public static let sharedLinkWindow = 2

    public static func maxFramesInFlight(
        isP2P: Bool,
        isWiredCable: Bool
    ) -> Int {
        (isP2P || isWiredCable) ? reliableLinkWindow : sharedLinkWindow
    }
}

/// Converts the sender's compressed-video byte window into an observed rate.
/// Timer callbacks are not guaranteed to arrive exactly one second apart, so
/// the real elapsed interval is part of the measurement.
public enum VideoTransferRatePolicy {
    public static func megabitsPerSecond(
        byteCount: Int,
        elapsedSeconds: TimeInterval
    ) -> Double {
        guard byteCount >= 0,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0 else { return 0 }
        return (Double(byteCount) * 8) / elapsedSeconds / 1_000_000
    }
}
