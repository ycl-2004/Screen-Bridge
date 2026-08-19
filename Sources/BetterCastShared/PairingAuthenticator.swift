import CryptoKit
import Foundation
import Security

public enum PairingAuthError: Error, Equatable, Sendable {
    case invalidProof
    case invalidEnvelope
}

/// A receiver session has exactly one media/control transport. An optional
/// audio transport may join it after the media transport is authenticated.
public enum StreamConnectionRole: String, Codable, Equatable, Sendable {
    case mediaControl
    case audio
}

/// Display facts the sender needs before it creates a virtual display.
/// Sending these inside the handshake prevents a temporary default-sized
/// display from being created and immediately replaced after connection.
public struct ReceiverCapabilities: Codable, Equatable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var isValid: Bool {
        pixelWidth > 0 && pixelHeight > 0
    }
}

public struct SenderHello: Codable, Equatable, Sendable {
    public let version: UInt8
    public let senderNonce: Data
    public let role: StreamConnectionRole
    /// Nil for a new media/control connection. The receiver creates the
    /// logical session and returns its ID. Auxiliary transports must send it.
    public let sessionID: UUID?

    public init(
        version: UInt8 = PrivateBetterCastConstants.protocolVersion,
        senderNonce: Data,
        role: StreamConnectionRole = .mediaControl,
        sessionID: UUID? = nil
    ) {
        self.version = version
        self.senderNonce = senderNonce
        self.role = role
        self.sessionID = sessionID
    }
}

public struct ReceiverHello: Codable, Equatable, Sendable {
    /// Protocol version the receiver is actually running. The sender enforces
    /// equality so an outdated peer fails the handshake with a clear reason
    /// instead of failing later on framing differences.
    public let version: UInt8
    public let receiverNonce: Data
    public let receiverProof: Data
    public let sessionID: UUID
    public let capabilities: ReceiverCapabilities?

    public init(
        version: UInt8 = PrivateBetterCastConstants.protocolVersion,
        receiverNonce: Data,
        receiverProof: Data,
        sessionID: UUID,
        capabilities: ReceiverCapabilities? = nil
    ) {
        self.version = version
        self.receiverNonce = receiverNonce
        self.receiverProof = receiverProof
        self.sessionID = sessionID
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case receiverNonce
        case receiverProof
        case sessionID
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Protocol v3 ReceiverHello omitted this field. Decode it as a sentinel
        // so the sender reaches its explicit unsupportedProtocol branch instead
        // of reporting an opaque JSON failure before the version check.
        version = try container.decodeIfPresent(UInt8.self, forKey: .version) ?? 0
        receiverNonce = try container.decode(Data.self, forKey: .receiverNonce)
        receiverProof = try container.decode(Data.self, forKey: .receiverProof)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        capabilities = try container.decodeIfPresent(ReceiverCapabilities.self, forKey: .capabilities)
    }
}

public struct SenderProof: Codable, Equatable, Sendable {
    public let senderProof: Data

    public init(senderProof: Data) {
        self.senderProof = senderProof
    }
}

public enum AuthenticatedEnvelopeDirection: Sendable {
    case senderToReceiver
    case receiverToSender

    fileprivate var authenticationDomain: Data {
        switch self {
        case .senderToReceiver:
            return Data("bettercast.control-envelope.sender-to-receiver.v1".utf8)
        case .receiverToSender:
            return Data("bettercast.control-envelope.receiver-to-sender.v1".utf8)
        }
    }
}

public struct AuthenticatedEnvelope: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let payload: Data
    public let mac: Data

    public init(sequence: UInt64, payload: Data, mac: Data) {
        self.sequence = sequence
        self.payload = payload
        self.mac = mac
    }

    public static func seal(
        sequence: UInt64,
        payload: Data,
        sessionKey: Data,
        direction: AuthenticatedEnvelopeDirection
    ) -> AuthenticatedEnvelope {
        AuthenticatedEnvelope(
            sequence: sequence,
            payload: payload,
            mac: PairingAuthenticator.envelopeMAC(
                sequence: sequence,
                payload: payload,
                sessionKey: sessionKey,
                direction: direction
            )
        )
    }

    public func verifiedPayload(
        sessionKey: Data,
        direction: AuthenticatedEnvelopeDirection
    ) throws -> Data {
        let expected = PairingAuthenticator.envelopeMAC(
            sequence: sequence,
            payload: payload,
            sessionKey: sessionKey,
            direction: direction
        )
        guard PairingAuthenticator.constantTimeEquals(mac, expected) else {
            throw PairingAuthError.invalidEnvelope
        }
        return payload
    }
}

public struct PairingAuthenticator {
    private static let nonceLength = 32

    public static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        return Data((0..<nonceLength).map { _ in UInt8.random(in: 0...UInt8.max) })
    }

    /// Shortest accepted pairing code, counted after normalization.
    public static let minimumSecretLength = 6

    /// Alphabet for generated codes: no `0/O` or `1/l/I`, so a code read off one
    /// screen and typed into another is unambiguous.
    private static let codeAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    public static func normalizedSecret(from userInput: String) -> Data {
        let digest = SHA256.hash(data: Data(normalize(userInput).utf8))
        return Data(digest)
    }

    /// Strips the separators a user might type, so `"Screen Bridge 2026"` and
    /// `"yccast2026"` are the same secret on both devices.
    public static func normalize(_ userInput: String) -> String {
        userInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Whether a pairing code is strong enough to be used as a shared secret.
    ///
    /// Normalization removes whitespace and `-`, so inputs the UI treated as
    /// non-empty (`"-"`, `"---"`) previously collapsed to `SHA256("")` — the same
    /// fixed secret on every install that did it. Callers must gate on this
    /// before storing a secret.
    public static func isAcceptableSecretInput(_ userInput: String) -> Bool {
        let normalized = normalize(userInput)
        guard normalized.count >= minimumSecretLength else { return false }
        // A code made of one repeated character has length but no entropy.
        guard Set(normalized).count >= 2 else { return false }
        return true
    }

    /// Generates a pairing code that satisfies `isAcceptableSecretInput`.
    public static func generatePairingCode(groups: Int = 3, groupLength: Int = 4) -> String {
        let chunks = (0..<groups).map { _ in
            String((0..<groupLength).map { _ in randomAlphabetCharacter() })
        }
        let code = chunks.joined(separator: "-")
        // Astronomically unlikely, but never hand back a code our own rule rejects.
        return isAcceptableSecretInput(code) ? code : generatePairingCode(groups: groups, groupLength: groupLength)
    }

    private static func randomAlphabetCharacter() -> Character {
        var byte: UInt8 = 0
        let status = withUnsafeMutablePointer(to: &byte) { pointer in
            SecRandomCopyBytes(kSecRandomDefault, 1, pointer)
        }
        let index = status == errSecSuccess
            ? Int(byte) % codeAlphabet.count
            : Int.random(in: 0..<codeAlphabet.count)
        return codeAlphabet[index]
    }

    public static func receiverProof(secret: Data, senderNonce: Data, receiverNonce: Data) -> Data {
        hmac(secret: secret, parts: [
            Data("bettercast.receiver-proof.v1".utf8),
            senderNonce,
            receiverNonce
        ])
    }

    public static func senderProof(secret: Data, senderNonce: Data, receiverNonce: Data) -> Data {
        hmac(secret: secret, parts: [
            Data("bettercast.sender-proof.v1".utf8),
            senderNonce,
            receiverNonce
        ])
    }

    public static func deriveSessionKey(secret: Data, senderNonce: Data, receiverNonce: Data) -> Data {
        hmac(secret: secret, parts: [
            Data("bettercast.session-key.v1".utf8),
            senderNonce,
            receiverNonce
        ])
    }

    public static func verifyReceiverProof(_ proof: Data, secret: Data, senderNonce: Data, receiverNonce: Data) -> Bool {
        constantTimeEquals(proof, receiverProof(secret: secret, senderNonce: senderNonce, receiverNonce: receiverNonce))
    }

    public static func verifySenderProof(_ proof: Data, secret: Data, senderNonce: Data, receiverNonce: Data) -> Bool {
        constantTimeEquals(proof, senderProof(secret: secret, senderNonce: senderNonce, receiverNonce: receiverNonce))
    }

    public static func envelopeMAC(
        sequence: UInt64,
        payload: Data,
        sessionKey: Data,
        direction: AuthenticatedEnvelopeDirection
    ) -> Data {
        var sequenceBE = sequence.bigEndian
        return hmac(secret: sessionKey, parts: [
            direction.authenticationDomain,
            Data(bytes: &sequenceBE, count: MemoryLayout<UInt64>.size),
            payload
        ])
    }

    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func hmac(secret: Data, parts: [Data]) -> Data {
        let key = SymmetricKey(data: secret)
        var authenticationCode = HMAC<SHA256>(key: key)
        for part in parts {
            authenticationCode.update(data: part)
        }
        return Data(authenticationCode.finalize())
    }
}
