import Foundation
import BetterCastShared

/// Shared constants for the ScreenBridge sender app.
/// Centralizes magic numbers, ports, paths, and dimensions that were previously
/// duplicated across multiple files.
enum BCConstants {

    // MARK: - Network
    /// Standard TCP port for the private Mac-to-iPad video/audio stream.
    static let tcpPort: UInt16 = 51820

    /// Legacy UDP port retained for inactive code paths.
    static let udpPort: UInt16 = 51821

    /// Private Bonjour service type. The private build browses/advertises TCP only.
    static let tcpServiceType = PrivateBetterCastConstants.serviceType
    static let udpServiceType = PrivateBetterCastConstants.serviceType

    // MARK: - Audio
    /// AAC-LC frame size in samples. Required by the AAC encoder/decoder.
    static let aacFrameSize: UInt32 = 1024

    /// Default audio sample rate (Hz) for AAC encode/decode.
    static let audioSampleRate: Double = 48_000

    /// Audio channel count for stereo output.
    static let audioChannels: UInt32 = 2

    /// AAC bitrate in bits per second.
    static let aacBitrate: UInt32 = 128_000

    // MARK: - System Tools
    /// macOS TCC reset utility — used to reset Screen Recording permissions.
    static let tccutilPath = "/usr/bin/tccutil"

    /// Android Debug Bridge (ADB) executable path. Installed via Android Studio
    /// platform-tools; users without it get a friendly error.
    static let adbPath = "/usr/local/bin/adb"

    // MARK: - Display Defaults
    /// Default logical long edge for receiver-matched virtual displays.
    /// A 2360 x 1640 iPad becomes a 1344 x 934 HiDPI display, with native-pixel capture.
    static let defaultReceiverVirtualDisplayLogicalLongEdge = 1344

    /// HiDPI scale for receiver-matched virtual displays.
    static let defaultReceiverVirtualDisplayScale = 2

    /// Default Android screen size when device hasn't reported its dimensions yet.
    /// Matches a typical phone resolution in landscape.
    static let defaultAndroidWidth = 1080
    static let defaultAndroidHeight = 2400
}
