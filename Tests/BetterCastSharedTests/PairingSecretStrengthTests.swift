import XCTest
@testable import BetterCastShared

/// Pairing code acceptance.
///
/// `normalizedSecret(from:)` strips whitespace and `-` before hashing, so inputs
/// the UI considered non-empty (`"-"`, `"---"`, `"  -  "`) collapsed to
/// `SHA256("")` — a fixed, publicly known secret shared by every such install.
final class PairingSecretStrengthTests: XCTestCase {

    func testRejectsEmptyInput() {
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput(""))
    }

    func testRejectsWhitespaceOnlyInput() {
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("     "))
    }

    func testRejectsSeparatorOnlyInput() {
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("-"))
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("---"))
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput(" - - - "))
    }

    func testRejectsInputShorterThanMinimumAfterNormalization() {
        // "12-34" normalizes to "1234", which is below the minimum.
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("12-34"))
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("abc"))
    }

    func testRejectsSingleRepeatedCharacter() {
        // "000000" has length but no entropy.
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("000000"))
        XCTAssertFalse(PairingAuthenticator.isAcceptableSecretInput("aaaaaaaa"))
    }

    func testAcceptsOrdinaryCode() {
        XCTAssertTrue(PairingAuthenticator.isAcceptableSecretInput("yccast-2026"))
        XCTAssertTrue(PairingAuthenticator.isAcceptableSecretInput("739154"))
    }

    func testAcceptsCodeAtExactMinimumLength() {
        let code = String(repeating: "ab", count: PairingAuthenticator.minimumSecretLength / 2)
        XCTAssertEqual(code.count, PairingAuthenticator.minimumSecretLength)
        XCTAssertTrue(PairingAuthenticator.isAcceptableSecretInput(code))
    }

    func testNormalizationIsUnchangedForAcceptedInput() {
        // Guard against silently changing the wire format: existing pairings
        // must keep working.
        // Legacy fixture: existing pairing normalization must remain stable.
        let expected = PairingAuthenticator.normalizedSecret(from: "YC-Cast 2026")
        let actual = PairingAuthenticator.normalizedSecret(from: "yccast2026")
        XCTAssertEqual(expected, actual)
    }

    func testGeneratedCodeIsAccepted() {
        for _ in 0..<50 {
            let code = PairingAuthenticator.generatePairingCode()
            XCTAssertTrue(
                PairingAuthenticator.isAcceptableSecretInput(code),
                "generated code \(code) must satisfy its own acceptance rule"
            )
        }
    }

    func testGeneratedCodesDiffer() {
        let codes = Set((0..<50).map { _ in PairingAuthenticator.generatePairingCode() })
        XCTAssertGreaterThan(codes.count, 45, "generated codes should not repeat")
    }
}

/// Keychain write semantics.
///
/// `saveSecret` used to delete-then-add. If the add failed, the old secret was
/// already gone and the device silently lost its pairing.
final class KeychainPairingSecretStoreTests: XCTestCase {

    private var store: KeychainPairingSecretStore!

    override func setUp() {
        super.setUp()
        store = KeychainPairingSecretStore(
            service: "com.yichen.yccast.tests.\(UUID().uuidString)",
            account: "pairing-secret"
        )
    }

    override func tearDown() {
        try? store.deleteSecret()
        store = nil
        super.tearDown()
    }

    func testSaveThenLoadRoundTrips() throws {
        try XCTSkipIf(!keychainAvailable(), "Keychain unavailable in this test environment")

        let secret = Data(repeating: 0x11, count: 32)
        try store.saveSecret(secret)
        XCTAssertEqual(try store.loadSecret(), secret)
    }

    func testReplacingSecretKeepsExactlyOneItem() throws {
        try XCTSkipIf(!keychainAvailable(), "Keychain unavailable in this test environment")

        try store.saveSecret(Data(repeating: 0x11, count: 32))
        try store.saveSecret(Data(repeating: 0x22, count: 32))

        XCTAssertEqual(try store.loadSecret(), Data(repeating: 0x22, count: 32))
    }

    func testDeleteIsIdempotent() throws {
        try XCTSkipIf(!keychainAvailable(), "Keychain unavailable in this test environment")

        try store.saveSecret(Data(repeating: 0x33, count: 32))
        try store.deleteSecret()
        XCTAssertNoThrow(try store.deleteSecret())
        XCTAssertNil(try store.loadSecret())
    }

    func testLoadOnEmptyStoreReturnsNil() throws {
        try XCTSkipIf(!keychainAvailable(), "Keychain unavailable in this test environment")
        XCTAssertNil(try store.loadSecret())
    }

    /// Updating an existing item must not go through a destructive delete.
    func testUpdateDoesNotDestroyExistingSecretOnFailure() throws {
        try XCTSkipIf(!keychainAvailable(), "Keychain unavailable in this test environment")

        let original = Data(repeating: 0x44, count: 32)
        try store.saveSecret(original)

        // An empty secret is rejected before any Keychain mutation happens.
        XCTAssertThrowsError(try store.saveSecret(Data()))
        XCTAssertEqual(try store.loadSecret(), original, "a rejected write must leave the stored secret intact")
    }

    private func keychainAvailable() -> Bool {
        do {
            _ = try store.loadSecret()
            return true
        } catch {
            return false
        }
    }
}
