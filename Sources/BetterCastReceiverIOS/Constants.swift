import Foundation
import BetterCastShared

/// Constants for the Screen Bridge iOS receiver app.
///
/// Deliberately small. The port, service type, and AAC format values that used
/// to live here were never read: the listener takes its service type straight
/// from `PrivateBetterCastConstants`, and `AudioPlayerIOS` uses the shared
/// `AudioStreamFormat`. Duplicated constants that nothing reads drift away from
/// the real ones and mislead the next reader.
enum BCConstants {
    static let preferredAudioSampleRate: Double = AudioStreamFormat.sampleRate
    /// Ten milliseconds reduces callback pressure while packet buffering owns
    /// the larger network-jitter budget.
    static let audioIOBufferDuration: TimeInterval = 0.010
}
