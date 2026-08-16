import Foundation

/// How many encoded video frames may be in flight on a link at once.
///
/// Backpressure used to be applied uniformly to every transport, gating all of
/// them at a single frame. On USB/Thunderbolt, peer-to-peer and loopback links —
/// which have both high bandwidth and low latency — that capped throughput at
/// one frame per round trip and produced drops on links that were not congested
/// at all, which in turn dragged the adaptive bitrate down. Those links
/// previously ran with no completion gating whatsoever and were the most stable
/// paths available, so they get real headroom back here while the queue stays
/// bounded.
public enum VideoFlightWindowPolicy {
    public static let reliableLinkWindow = 4
    public static let sharedLinkWindow = 1

    public static func maxFramesInFlight(
        isP2P: Bool,
        isWiredCable: Bool,
        isLoopback: Bool
    ) -> Int {
        (isP2P || isWiredCable || isLoopback) ? reliableLinkWindow : sharedLinkWindow
    }
}
