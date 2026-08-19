import Foundation

/// Rules for keeping a virtual display alive while the receiver is backgrounded.
///
/// The receiver announces backgrounding (command 555) and iPadOS then suspends
/// it, which resets its sockets within about a second. The sender therefore
/// always sees a fatal transport error immediately after the notice — the grace
/// period cannot be expressed as "hold the connection", only as "hold the
/// display and keep trying to get the connection back".
///
/// These are pure because every bug in this area is a state-transition bug: a
/// hold that outlives its deadline strands a display WindowServer counts
/// against its one-private-display-at-a-time limit, and a hold released one step
/// too early bounces every window back to the Mac's own screen.
public enum BackgroundDisplayHoldPolicy {
    /// How long a display may outlive its connection.
    public static let defaultGraceDuration: TimeInterval = 300

    /// Longest back-off between reconnect attempts while a display is held.
    /// Without a ceiling the exponential chain would back off into minutes and
    /// leave the display parked long after the receiver came back.
    public static let heldRetryDelayCeiling: TimeInterval = 8

    /// The deadline a display may be held to, or `nil` when it must be
    /// destroyed now.
    ///
    /// Returning `nil` for an already-elapsed window is what stops the
    /// expiry-driven teardown from re-holding the display it is retiring.
    public static func holdDeadline(
        graceStart: Date?,
        graceDuration: TimeInterval = defaultGraceDuration,
        now: Date
    ) -> Date? {
        guard let graceStart else { return nil }
        let deadline = graceStart.addingTimeInterval(graceDuration)
        return deadline > now ? deadline : nil
    }

    /// Whether another auto-reconnect attempt is allowed.
    ///
    /// A held display extends the budget past the normal attempt cap: the
    /// receiver is knowingly away and returns on the user's schedule, not ours.
    /// Giving up at three tries would strand the display until it expired.
    public static func shouldRetryConnect(
        attempt: Int,
        maximumAttempts: Int,
        holdDeadline: Date?,
        now: Date
    ) -> Bool {
        if attempt <= maximumAttempts { return true }
        guard let holdDeadline else { return false }
        return holdDeadline > now
    }

    /// Back-off before the next attempt.
    public static func retryDelay(attempt: Int, isHoldingDisplay: Bool) -> TimeInterval {
        let exponential = pow(2.0, Double(max(1, attempt)))
        return isHoldingDisplay ? min(heldRetryDelayCeiling, exponential) : exponential
    }

    /// Whether a held display can be handed to a returning session.
    ///
    /// Geometry must match exactly: a receiver that rotated or a Mac whose
    /// resolution setting changed while the device was away needs a genuinely
    /// different display, and adopting a mismatched one would stream the wrong
    /// aspect ratio.
    public static func canAdoptHeldDisplay<Geometry: Equatable>(
        held: Geometry,
        requested: Geometry,
        deadline: Date,
        now: Date
    ) -> Bool {
        held == requested && deadline > now
    }
}
