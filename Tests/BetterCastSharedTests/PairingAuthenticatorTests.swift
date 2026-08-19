import XCTest
@testable import BetterCastShared

final class PairingAuthenticatorTests: XCTestCase {
    func testProtocolVersionSealsSenderControl() {
        // v4: sender→receiver control travels as authenticated envelopes under
        // type byte 0x05, and ReceiverHello carries its own version field.
        XCTAssertEqual(PrivateBetterCastConstants.protocolVersion, 4)
        XCTAssertEqual(StreamFraming.SenderControlTypeByte.authenticatedControl, 0x05)
        XCTAssertEqual(StreamFraming.SenderControlTypeByte.disconnectCommand, 0x03)
        XCTAssertEqual(StreamFraming.SenderControlTypeByte.heartbeatCommand, 0x04)
        XCTAssertTrue(StreamFraming.SenderControlTypeByte.isFramingMarker(0x05))
        XCTAssertFalse(StreamFraming.SenderControlTypeByte.isFramingMarker(0x7B))
    }

    func testReceiverHelloDefaultsToCurrentProtocolVersion() throws {
        let hello = ReceiverHello(
            receiverNonce: Data("receiver".utf8),
            receiverProof: Data(repeating: 1, count: 32),
            sessionID: UUID()
        )

        let decoded = try JSONDecoder().decode(
            ReceiverHello.self,
            from: JSONEncoder().encode(hello)
        )

        XCTAssertEqual(decoded.version, PrivateBetterCastConstants.protocolVersion)
        XCTAssertEqual(decoded, hello)
    }

    func testLegacyReceiverHelloWithoutVersionDecodesAsUnsupportedSentinel() throws {
        let json = """
        {
          "receiverNonce": "cmVjZWl2ZXI=",
          "receiverProof": "cHJvb2Y=",
          "sessionID": "00000000-0000-0000-0000-000000000001"
        }
        """

        let decoded = try JSONDecoder().decode(ReceiverHello.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.version, 0)
        XCTAssertNotEqual(decoded.version, PrivateBetterCastConstants.protocolVersion)
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
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: payload,
            sessionKey: sessionKey,
            direction: .receiverToSender
        )

        XCTAssertEqual(
            try envelope.verifiedPayload(sessionKey: sessionKey, direction: .receiverToSender),
            payload
        )
    }

    func testAuthenticatedEnvelopeFailsWithWrongKey() {
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: Data("payload".utf8),
            sessionKey: Data("session-key".utf8),
            direction: .receiverToSender
        )

        XCTAssertThrowsError(try envelope.verifiedPayload(
            sessionKey: Data("wrong-key".utf8),
            direction: .receiverToSender
        ))
    }

    func testAuthenticatedEnvelopeFailsAfterPayloadTampering() {
        let sessionKey = Data("session-key".utf8)
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: Data("payload".utf8),
            sessionKey: sessionKey,
            direction: .receiverToSender
        )
        let tampered = AuthenticatedEnvelope(
            sequence: envelope.sequence,
            payload: Data("tampered".utf8),
            mac: envelope.mac
        )

        XCTAssertThrowsError(try tampered.verifiedPayload(
            sessionKey: sessionKey,
            direction: .receiverToSender
        ))
    }

    func testAuthenticatedEnvelopeFailsAfterSequenceTampering() {
        let sessionKey = Data("session-key".utf8)
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 1,
            payload: Data("payload".utf8),
            sessionKey: sessionKey,
            direction: .receiverToSender
        )
        let tampered = AuthenticatedEnvelope(
            sequence: 2,
            payload: envelope.payload,
            mac: envelope.mac
        )

        XCTAssertThrowsError(try tampered.verifiedPayload(
            sessionKey: sessionKey,
            direction: .receiverToSender
        ))
    }

    func testAuthenticatedEnvelopeCannotBeReflectedAcrossDirections() {
        let sessionKey = Data("session-key".utf8)
        let envelope = AuthenticatedEnvelope.seal(
            sequence: 7,
            payload: Data([StreamFraming.SenderControlTypeByte.heartbeatCommand]),
            sessionKey: sessionKey,
            direction: .receiverToSender
        )

        XCTAssertThrowsError(try envelope.verifiedPayload(
            sessionKey: sessionKey,
            direction: .senderToReceiver
        ))
    }
}
