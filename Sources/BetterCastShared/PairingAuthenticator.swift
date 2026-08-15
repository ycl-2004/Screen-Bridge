import CryptoKit
import Foundation
import Security

public enum PairingAuthError: Error, Equatable {
    case invalidProof
    case invalidEnvelope
}

public struct SenderHello: Codable, Equatable {
    public let version: UInt8
    public let senderNonce: Data

    public init(version: UInt8 = PrivateBetterCastConstants.protocolVersion, senderNonce: Data) {
        self.version = version
        self.senderNonce = senderNonce
    }
}

public struct ReceiverHello: Codable, Equatable {
    public let receiverNonce: Data
    public let receiverProof: Data

    public init(receiverNonce: Data, receiverProof: Data) {
        self.receiverNonce = receiverNonce
        self.receiverProof = receiverProof
    }
}

public struct SenderProof: Codable, Equatable {
    public let senderProof: Data

    public init(senderProof: Data) {
        self.senderProof = senderProof
    }
}

public struct AuthenticatedEnvelope: Codable, Equatable {
    public let sequence: UInt64
    public let payload: Data
    public let mac: Data

    public init(sequence: UInt64, payload: Data, mac: Data) {
        self.sequence = sequence
        self.payload = payload
        self.mac = mac
    }

    public static func seal(sequence: UInt64, payload: Data, sessionKey: Data) -> AuthenticatedEnvelope {
        AuthenticatedEnvelope(
            sequence: sequence,
            payload: payload,
            mac: PairingAuthenticator.envelopeMAC(sequence: sequence, payload: payload, sessionKey: sessionKey)
        )
    }

    public func verifiedPayload(sessionKey: Data) throws -> Data {
        let expected = PairingAuthenticator.envelopeMAC(sequence: sequence, payload: payload, sessionKey: sessionKey)
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

    /// Strips the separators a user might type, so `"YC-Cast 2026"` and
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

    public static func envelopeMAC(sequence: UInt64, payload: Data, sessionKey: Data) -> Data {
        var sequenceBE = sequence.bigEndian
        return hmac(secret: sessionKey, parts: [
            Data("bettercast.input-envelope.v1".utf8),
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
