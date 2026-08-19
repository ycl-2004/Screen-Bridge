import Foundation
import BetterCastShared

/// Shared constants for the Screen Bridge sender app.
/// Centralizes magic numbers, ports, paths, and dimensions that were previously
/// duplicated across multiple files.
enum BCConstants {

    // MARK: - Network
    /// Standard TCP port for the private Mac-to-iPad video/audio stream.
    static let tcpPort: UInt16 = 51820

    /// Private Bonjour service type. The private build browses/advertises TCP only.
    static let tcpServiceType = PrivateBetterCastConstants.serviceType

    // MARK: - Audio
    /// AAC-LC frame size in samples. Required by the AAC encoder/decoder.
    static let aacFrameSize: UInt32 = 1024

    /// Default audio sample rate (Hz) for AAC encode/decode. Mirrors the shared
    /// wire-format constant; the receiver decodes at the same value.
    static let audioSampleRate: Double = AudioStreamFormat.sampleRate

    /// Audio channel count for stereo output.
    static let audioChannels: UInt32 = AudioStreamFormat.channelCount

    /// AAC bitrate in bits per second.
    static let aacBitrate: UInt32 = 128_000

    // MARK: - Display Defaults
    /// Default logical long edge for receiver-matched virtual displays.
    /// A 2360 x 1640 iPad becomes a 1344 x 934 HiDPI display, with native-pixel capture.
    static let defaultReceiverVirtualDisplayLogicalLongEdge = 1344

    /// HiDPI scale for receiver-matched virtual displays.
    static let defaultReceiverVirtualDisplayScale = 2
}
