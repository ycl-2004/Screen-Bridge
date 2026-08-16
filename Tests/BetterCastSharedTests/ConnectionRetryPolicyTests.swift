import XCTest
@testable import BetterCastShared

/// Regression coverage for the connection-lifecycle bugs that shipped and had
/// to be diagnosed from device logs. Each test names the failure it prevents.
final class ConnectionRetryPolicyTests: XCTestCase {

    // MARK: - Retry budget

    func testColdLinkRetriesUpToTheBudget() {
        for attempt in 1..<ConnectionRetryPolicy.maximumAttempts {
            XCTAssertEqual(
                ConnectionRetryPolicy.decision(attempt: attempt, canFallBackToInfrastructure: false),
                .retry(attempt: attempt + 1, afterSeconds: ConnectionRetryPolicy.backoffSeconds),
                "attempt \(attempt) should still retry"
            )
        }
    }

    /// A single retry was not enough for a cold USB/Thunderbolt link: it needed
    /// three dials, and the user had to click Connect again by hand.
    func testBudgetCoversTheObservedThreeDialCableWarmUp() {
        XCTAssertGreaterThanOrEqual(ConnectionRetryPolicy.maximumAttempts, 3)
    }

    func testRetriesStopAtTheBudget() {
        XCTAssertEqual(
            ConnectionRetryPolicy.decision(
                attempt: ConnectionRetryPolicy.maximumAttempts,
                canFallBackToInfrastructure: false
            ),
            .fail
        )
    }

    func testAutoModePrefersInfrastructureFallbackOverRetrying() {
        XCTAssertEqual(
            ConnectionRetryPolicy.decision(attempt: 1, canFallBackToInfrastructure: true),
            .fallBackToInfrastructure
        )
    }

    /// Dialing again immediately kept the receiver's pending-handshake slots
    /// occupied by connections we had just cancelled.
    func testRetriesAreSpacedOut() {
        XCTAssertGreaterThan(ConnectionRetryPolicy.backoffSeconds, 0)
    }

    // MARK: - Reservation ownership
    //
    // Releasing the per-device reservation one step too early let a second,
    // independent retry chain start for the same device. The chains interleaved,
    // each with its own attempt counter, and together they flooded the receiver
    // (which refuses more than four pending handshakes) so a cable that works on
    // a single dial could never connect at all.

    func testExternalConnectIsRejectedWhileAnotherAttemptOwnsTheDevice() {
        XCTAssertFalse(
            ConnectionRetryPolicy.shouldAcceptConnect(attempt: 1, hasReservation: true)
        )
    }

    func testExternalConnectIsAcceptedWhenDeviceIsFree() {
        XCTAssertTrue(
            ConnectionRetryPolicy.shouldAcceptConnect(attempt: 1, hasReservation: false)
        )
    }

    /// The retry is a continuation of the attempt that already holds the
    /// reservation, so it must not be rejected by its own bookkeeping.
    func testRetryIsNeverRejectedByItsOwnReservation() {
        for attempt in 2...ConnectionRetryPolicy.maximumAttempts {
            XCTAssertTrue(
                ConnectionRetryPolicy.shouldAcceptConnect(attempt: attempt, hasReservation: true),
                "retry \(attempt) must proceed"
            )
        }
    }

    /// The retry path cancels the connection itself; releasing the reservation
    /// on that cancel re-opened the door for the competing chain.
    func testCancelForRetryKeepsTheReservation() {
        XCTAssertFalse(
            ConnectionRetryPolicy.shouldReleaseReservationOnCancel(cancelledForRetry: true)
        )
    }

    func testOrdinaryCancelReleasesTheReservation() {
        XCTAssertTrue(
            ConnectionRetryPolicy.shouldReleaseReservationOnCancel(cancelledForRetry: false)
        )
    }

    // MARK: - Back-off outcome

    func testBackoffRetriesWhenStillDisconnectedAndStillOwned() {
        XCTAssertEqual(
            ConnectionRetryPolicy.backoffOutcome(hasReservation: true, deviceAlreadyConnected: false),
            .proceedWithRetry
        )
    }

    /// If the device connects during the back-off, the reservation is still ours
    /// and must be handed back. Leaving it set pinned the device to a
    /// "connecting" state that no later connect attempt could get past — the
    /// device was unusable until the app restarted.
    func testBackoffReleasesReservationWhenDeviceConnectedMeanwhile() {
        XCTAssertEqual(
            ConnectionRetryPolicy.backoffOutcome(hasReservation: true, deviceAlreadyConnected: true),
            .releaseReservation
        )
    }

    func testBackoffAbandonsWhenReservationWasTakenOver() {
        XCTAssertEqual(
            ConnectionRetryPolicy.backoffOutcome(hasReservation: false, deviceAlreadyConnected: false),
            .abandonSuperseded
        )
        XCTAssertEqual(
            ConnectionRetryPolicy.backoffOutcome(hasReservation: false, deviceAlreadyConnected: true),
            .abandonSuperseded
        )
    }

    /// The reservation must end up released on every terminal path, otherwise
    /// the device is stuck. This walks the full state space.
    func testReservationIsNeverStrandedAcrossAllOutcomes() {
        for hasReservation in [true, false] {
            for connected in [true, false] {
                let outcome = ConnectionRetryPolicy.backoffOutcome(
                    hasReservation: hasReservation,
                    deviceAlreadyConnected: connected
                )
                if hasReservation && connected {
                    XCTAssertEqual(outcome, .releaseReservation,
                                   "a held reservation on a connected device must be released")
                }
                if !hasReservation {
                    XCTAssertEqual(outcome, .abandonSuperseded,
                                   "without a reservation nothing may be released twice")
                }
            }
        }
    }
}
