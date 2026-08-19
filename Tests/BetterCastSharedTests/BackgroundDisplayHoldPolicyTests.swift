import XCTest
@testable import BetterCastShared

/// Regression coverage for the background grace period, which was observably
/// dead on a real iPad: the sender logged "grace period started (300s), keeping
/// virtual display" and destroyed that display in the same second, because
/// iPadOS resets the receiver's sockets as it suspends the app.
final class BackgroundDisplayHoldPolicyTests: XCTestCase {

    // MARK: - Hold deadline

    /// A session that never announced backgrounding is a normal disconnect and
    /// must not leave a display parked.
    func testNoHoldWithoutABackgroundNotice() {
        XCTAssertNil(BackgroundDisplayHoldPolicy.holdDeadline(graceStart: nil, now: Date()))
    }

    /// The transport error arrives about a second after the notice. That is the
    /// case the hold exists for.
    func testHoldSurvivesTheTransportResetThatFollowsTheNotice() {
        let graceStart = Date()
        let deadline = BackgroundDisplayHoldPolicy.holdDeadline(
            graceStart: graceStart,
            now: graceStart.addingTimeInterval(1)
        )
        XCTAssertEqual(
            deadline,
            graceStart.addingTimeInterval(BackgroundDisplayHoldPolicy.defaultGraceDuration)
        )
    }

    /// Expiry tears the pipeline down through the same path that would create a
    /// hold. Returning nil for an elapsed window is what stops that teardown
    /// from re-holding the display it is retiring.
    func testElapsedGraceRefusesToReHoldTheDisplay() {
        let graceStart = Date()
        let afterExpiry = graceStart
            .addingTimeInterval(BackgroundDisplayHoldPolicy.defaultGraceDuration + 1)
        XCTAssertNil(BackgroundDisplayHoldPolicy.holdDeadline(graceStart: graceStart, now: afterExpiry))
    }

    // MARK: - Reconnect budget

    /// Normal disconnects keep their bounded attempt budget.
    func testUnheldReconnectStillGivesUp() {
        XCTAssertFalse(BackgroundDisplayHoldPolicy.shouldRetryConnect(
            attempt: 4,
            maximumAttempts: 3,
            holdDeadline: nil,
            now: Date()
        ))
    }

    /// Stopping at three tries would strand the held display until it expired,
    /// so the hold's deadline becomes the budget instead.
    func testHeldDisplayKeepsRetryingPastTheAttemptCap() {
        let now = Date()
        XCTAssertTrue(BackgroundDisplayHoldPolicy.shouldRetryConnect(
            attempt: 20,
            maximumAttempts: 3,
            holdDeadline: now.addingTimeInterval(120),
            now: now
        ))
    }

    /// Once the hold is gone the extended budget goes with it.
    func testExpiredHoldStopsExtendingTheReconnectBudget() {
        let now = Date()
        XCTAssertFalse(BackgroundDisplayHoldPolicy.shouldRetryConnect(
            attempt: 20,
            maximumAttempts: 3,
            holdDeadline: now.addingTimeInterval(-1),
            now: now
        ))
    }

    /// Unbounded exponential back-off would park the display for minutes after
    /// the receiver had already come back.
    func testHeldRetriesStopBackingOffIntoMinutes() {
        let unheld = BackgroundDisplayHoldPolicy.retryDelay(attempt: 9, isHoldingDisplay: false)
        let held = BackgroundDisplayHoldPolicy.retryDelay(attempt: 9, isHoldingDisplay: true)
        XCTAssertGreaterThan(unheld, 60)
        XCTAssertEqual(held, BackgroundDisplayHoldPolicy.heldRetryDelayCeiling)
    }

    /// Early attempts are unchanged: the ceiling only clamps the tail.
    func testEarlyRetriesKeepTheirExistingBackoff() {
        XCTAssertEqual(BackgroundDisplayHoldPolicy.retryDelay(attempt: 1, isHoldingDisplay: true), 2)
        XCTAssertEqual(BackgroundDisplayHoldPolicy.retryDelay(attempt: 2, isHoldingDisplay: true), 4)
    }

    // MARK: - Adoption

    private struct Geometry: Equatable {
        let width: Int
        let height: Int
    }

    /// Reuse is the whole point: recreating the display bounces every window
    /// back to the Mac's own screen.
    func testReturningReceiverAdoptsTheDisplayItLeft() {
        let now = Date()
        XCTAssertTrue(BackgroundDisplayHoldPolicy.canAdoptHeldDisplay(
            held: Geometry(width: 2688, height: 1868),
            requested: Geometry(width: 2688, height: 1868),
            deadline: now.addingTimeInterval(60),
            now: now
        ))
    }

    /// A receiver that rotated while it was away needs a different display;
    /// adopting the old one would stream the wrong aspect ratio.
    func testRotatedReceiverDoesNotAdoptAMismatchedDisplay() {
        let now = Date()
        XCTAssertFalse(BackgroundDisplayHoldPolicy.canAdoptHeldDisplay(
            held: Geometry(width: 2688, height: 1868),
            requested: Geometry(width: 1868, height: 2688),
            deadline: now.addingTimeInterval(60),
            now: now
        ))
    }

    /// A hold past its deadline is on its way out and must not be handed on.
    func testExpiredHoldIsNotAdopted() {
        let now = Date()
        XCTAssertFalse(BackgroundDisplayHoldPolicy.canAdoptHeldDisplay(
            held: Geometry(width: 2688, height: 1868),
            requested: Geometry(width: 2688, height: 1868),
            deadline: now.addingTimeInterval(-1),
            now: now
        ))
    }
}
