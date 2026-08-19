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

    /// Wall-clock budget for an entire Auto candidate chain.
    ///
    /// Auto walks several routes in reliability order and each one may burn a
    /// full dial timeout plus warm-up retries. Left uncapped that compounds into
    /// well over a minute of "Connecting…" before anything is reported, which
    /// reads as a hang rather than as a search. The budget bounds the wait
    /// regardless of how many interfaces Bonjour happened to advertise.
    public static let automaticRouteBudgetSeconds: TimeInterval = 35

    /// Warm-up retries allowed on an AWDL route.
    ///
    /// A user who explicitly selected AWDL is waiting on that radio and nothing
    /// else, so it keeps the full warm-up budget. In Auto, AWDL is one candidate
    /// among several and spending the same budget there delays every remaining
    /// route behind a link that is usually not the answer.
    public static func awdlAttemptBudget(isExplicitAWDLRequest: Bool) -> Int {
        isExplicitAWDLRequest ? maximumAWDLAttempts : 2
    }

    /// Whether an Auto chain may still advance to another route candidate.
    public static func hasAutomaticRouteBudgetRemaining(
        chainStartedAt: Date,
        now: Date,
        budget: TimeInterval = automaticRouteBudgetSeconds
    ) -> Bool {
        now.timeIntervalSince(chainStartedAt) < budget
    }

    /// Whether a `connect` call may proceed.
    ///
    /// Only a fresh, externally initiated connect competes for the reservation.
    /// A retry is the continuation of an attempt that already holds it, so
    /// rejecting it as a duplicate would strand the chain it belongs to.
    public static func shouldAcceptConnect(
        attempt: Int,
        fallbackIndex: Int = 0,
        hasReservation: Bool
    ) -> Bool {
        if attempt > 1 || fallbackIndex > 0 { return true }
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
