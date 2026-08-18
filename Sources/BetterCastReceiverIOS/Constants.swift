import Foundation

/// Constants for the ScreenBridge iOS receiver app.
///
/// Deliberately small. The port, service type, and AAC format values that used
/// to live here were never read: the listener takes its service type straight
/// from `PrivateBetterCastConstants`, and `AudioPlayerIOS` carries its own
/// format values. Duplicated constants that nothing reads drift away from the
/// real ones and mislead the next reader.
enum BCConstants {
    /// Preferred audio IO buffer duration (seconds). Lower = lower latency.
    static let audioIOBufferDuration: TimeInterval = 0.005
}
