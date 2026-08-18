import XCTest
@testable import BetterCastShared

final class PairingAuthenticatorTests: XCTestCase {
    func testProtocolVersionIncludesTimedAudioPackets() {
        XCTAssertEqual(PrivateBetterCastConstants.protocolVersion, 3)
    }

    func testMediaHelloStartsWithoutSessionAndRoundTrips() throws {
        let hello = SenderHello(
            senderNonce: Data("sender".utf8),
            role: .mediaControl
        )

        let decoded = try JSONDecoder().decode(
            SenderHello.self,
            from: JSONEncoder().encode(hello)
        )

        XCTAssertEqual(decoded, hello)
        XCTAssertNil(decoded.sessionID)
    }

    func testAudioHelloJoinsExistingSessionAndRoundTrips() throws {
        let sessionID = UUID()
        let hello = SenderHello(
            senderNonce: Data("audio".utf8),
            role: .audio,
            sessionID: sessionID
        )

        let decoded = try JSONDecoder().decode(
            SenderHello.self,
            from: JSONEncoder().encode(hello)
        )

        XCTAssertEqual(decoded.role, .audio)
        XCTAssertEqual(decoded.sessionID, sessionID)
    }

    func testReceiverHelloCarriesSessionAndDisplayCapabilities() throws {
        let sessionID = UUID()
        let hello = ReceiverHello(
            receiverNonce: Data("receiver".utf8),
            receiverProof: Data("proof".utf8),
            sessionID: sessionID,
            capabilities: ReceiverCapabilities(pixelWidth: 2688, pixelHeight: 2016)
        )

        let decoded = try JSONDecoder().decode(
            ReceiverHello.self,
            from: JSONEncoder().encode(hello)
        )

        XCTAssertEqual(decoded, hello)
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.capabilities?.pixelWidth, 2688)
        XCTAssertEqual(decoded.capabilities?.pixelHeight, 2016)
        XCTAssertTrue(decoded.capabilities?.isValid == true)
    }

    func testReceiverCapabilitiesRejectNonPositiveDimensions() {
        XCTAssertFalse(ReceiverCapabilities(pixelWidth: 0, pixelHeight: 2016).isValid)
        XCTAssertFalse(ReceiverCapabilities(pixelWidth: 2688, pixelHeight: -1).isValid)
    }

    func testReceiverProofAuthenticatesWithSameSecretAndNonces() {
        let secret = PairingAuthenticator.normalizedSecret(from: "123-456")
        let senderNonce = Data("sender".utf8)
        let receiverNonce = Data("receiver".utf8)

        let proof = PairingAuthenticator.receiverProof(
            secret: secret,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        )

        XCTAssertTrue(PairingAuthenticator.verifyReceiverProof(
            proof,
            secret: secret,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        ))
    }

    func testReceiverProofFailsWithDifferentSecret() {
        let senderNonce = Data("sender".utf8)
        let receiverNonce = Data("receiver".utf8)
        let proof = PairingAuthenticator.receiverProof(
            secret: PairingAuthenticator.normalizedSecret(from: "123456"),
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        )

        XCTAssertFalse(PairingAuthenticator.verifyReceiverProof(
            proof,
            secret: PairingAuthenticator.normalizedSecret(from: "654321"),
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        ))
    }

    func testTamperedReceiverProofFails() {
        let secret = PairingAuthenticator.normalizedSecret(from: "123456")
        let senderNonce = Data("sender".utf8)
        let receiverNonce = Data("receiver".utf8)
        var proof = PairingAuthenticator.receiverProof(
            secret: secret,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        )
        proof[0] ^= 0xff

        XCTAssertFalse(PairingAuthenticator.verifyReceiverProof(
            proof,
            secret: secret,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        ))
    }

    func testSessionKeyIsStableForSameInputsAndChangesForDifferentNonces() {
        let secret = PairingAuthenticator.normalizedSecret(from: "123456")
        let senderNonce = Data("sender".utf8)
        let receiverNonce = Data("receiver".utf8)

        let keyA = PairingAuthenticator.deriveSessionKey(
            secret: secret,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        )
        let keyB = PairingAuthenticator.deriveSessionKey(
            secret: secret,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce
        )
        let keyC = PairingAuthenticator.deriveSessionKey(
            secret: secret,
            senderNonce: Data("sender-2".utf8),
            receiverNonce: receiverNonce
        )

        XCTAssertEqual(keyA, keyB)
        XCTAssertNotEqual(keyA, keyC)
    }

    func testAuthenticatedEnvelopeVerifiesWithCorrectSessionKey() throws {
        let sessionKey = Data("session-key".utf8)
        let payload = Data("payload".utf8)
        let envelope = AuthenticatedEnvelope.seal(sequence: 1, payload: payload, sessionKey: sessionKey)

        XCTAssertEqual(try envelope.verifiedPayload(sessionKey: sessionKey), payload)
    }

    func testAuthenticatedEnvelopeFailsWithWrongKey() {
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: Data("payload".utf8),
            sessionKey: Data("session-key".utf8)
        )

        XCTAssertThrowsError(try envelope.verifiedPayload(sessionKey: Data("wrong-key".utf8)))
    }

    func testAuthenticatedEnvelopeFailsAfterPayloadTampering() {
        let sessionKey = Data("session-key".utf8)
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: Data("payload".utf8),
            sessionKey: sessionKey
        )
        let tampered = AuthenticatedEnvelope(
            sequence: envelope.sequence,
            payload: Data("tampered".utf8),
            mac: envelope.mac
        )

        XCTAssertThrowsError(try tampered.verifiedPayload(sessionKey: sessionKey))
    }

    func testAuthenticatedEnvelopeFailsAfterSequenceTampering() {
        let sessionKey = Data("session-key".utf8)
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: Data("payload".utf8),
            sessionKey: sessionKey
        )
        let tampered = AuthenticatedEnvelope(
            sequence: 2,
            payload: envelope.payload,
            mac: envelope.mac
        )

        XCTAssertThrowsError(try tampered.verifiedPayload(sessionKey: sessionKey))
    }
}
