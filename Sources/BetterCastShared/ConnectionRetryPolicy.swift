import Foundation

/// What the back-off timer should do when it finally fires.
public enum ConnectionBackoffOutcome: Equatable {
    /// Another code path already released the reservation; this chain is stale.
    case abandonSuperseded
    /// The device connected while we waited. The reservation is still ours and
    /// must be handed back, or the device stays stuck in "connecting" forever.
    case releaseReservation
    /// Still disconnected and still ours — dial again.
    case proceedWithRetry
}

/// Rules for retrying a connection and for owning the per-device "currently
/// connecting" reservation.
///
/// These are pulled out of `NetworkClient` because every bug in this area has
/// been a state-transition bug, not a networking bug: a reservation released
/// one step too early let a second retry chain start for the same device, and
/// the two chains together flooded the receiver's pending-handshake limit so a
/// cable that works on a single dial could never connect.
public enum ConnectionRetryPolicy {
    /// AWDL radios sleep and need waking, so a cold peer-to-peer dial genuinely
    /// can fail once or twice before succeeding.
    public static let maximumAWDLAttempts = 4

    /// Pause between warm-up retries, so the receiver can retire the handshake
    /// we just cancelled before the next dial arrives.
    public static let backoffSeconds: TimeInterval = 1.5

    /// Whether a `connect` call may proceed.
    ///
    /// Only a fresh, externally initiated connect competes for the reservation.
    /// A retry is the continuation of an attempt that already holds it, so
    /// rejecting it as a duplicate would strand the chain it belongs to.
    public static func shouldAcceptConnect(attempt: Int, hasReservation: Bool) -> Bool {
        if attempt > 1 { return true }
        return !hasReservation
    }

    /// Whether a cancelled connection should hand the reservation back.
    ///
    /// The retry path cancels the connection itself and keeps owning the
    /// reservation for the next dial; releasing it there re-opens the door for
    /// the competing chain the timeout handler just prevented.
    public static func shouldReleaseReservationOnCancel(cancelledForRetry: Bool) -> Bool {
        !cancelledForRetry
    }

    public static func backoffOutcome(
        hasReservation: Bool,
        deviceAlreadyConnected: Bool
    ) -> ConnectionBackoffOutcome {
        guard hasReservation else { return .abandonSuperseded }
        return deviceAlreadyConnected ? .releaseReservation : .proceedWithRetry
    }
}
