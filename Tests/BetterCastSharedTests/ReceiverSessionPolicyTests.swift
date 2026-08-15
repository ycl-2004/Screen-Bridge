import XCTest
@testable import BetterCastShared

final class ReceiverSessionPolicyTests: XCTestCase {
    func testMainTransportMayCreateOrReplaceSession() {
        XCTAssertTrue(
            ReceiverSessionPolicy.mayAttach(
                role: .mediaControl,
                sessionID: UUID(),
                activeSessionID: UUID(),
                hasMainTransport: true
            )
        )
    }

    func testAudioMayJoinOnlyMatchingActiveSession() {
        let sessionID = UUID()
        XCTAssertTrue(
            ReceiverSessionPolicy.mayAttach(
                role: .audio,
                sessionID: sessionID,
                activeSessionID: sessionID,
                hasMainTransport: true
            )
        )
    }

    func testAudioCannotCreateSessionByItself() {
        let sessionID = UUID()
        XCTAssertFalse(
            ReceiverSessionPolicy.mayAttach(
                role: .audio,
                sessionID: sessionID,
                activeSessionID: sessionID,
                hasMainTransport: false
            )
        )
    }

    func testAudioCannotJoinStaleSession() {
        XCTAssertFalse(
            ReceiverSessionPolicy.mayAttach(
                role: .audio,
                sessionID: UUID(),
                activeSessionID: UUID(),
                hasMainTransport: true
            )
        )
    }
}
