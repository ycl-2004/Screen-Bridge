import Foundation
import Security

public protocol PairingSecretStoring {
    func loadSecret() throws -> Data?
    func saveSecret(_ secret: Data) throws
    func deleteSecret() throws
}

public enum PairingSecretStoreError: Error, Equatable {
    case unhandledStatus(OSStatus)
    /// Refused before touching the Keychain, so any stored secret survives.
    case emptySecret
}

public final class KeychainPairingSecretStore: PairingSecretStoring {
    private let service: String
    private let account: String

    public init(
        service: String = PrivateBetterCastConstants.appGroupKeychainService,
        account: String = PrivateBetterCastConstants.pairingSecretAccount
    ) {
        self.service = service
        self.account = account
    }

    public func loadSecret() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PairingSecretStoreError.unhandledStatus(status)
        }
        return item as? Data
    }

    /// Stores the pairing secret, replacing any existing one.
    ///
    /// This updates in place rather than delete-then-add: the old sequence lost
    /// the stored secret whenever the add half failed, leaving the device
    /// silently unpaired with no way to recover the previous value.
    public func saveSecret(_ secret: Data) throws {
        guard !secret.isEmpty else { throw PairingSecretStoreError.emptySecret }

        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PairingSecretStoreError.unhandledStatus(updateStatus)
        }

        var addQuery = baseQuery()
        addQuery.merge(attributes) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingSecretStoreError.unhandledStatus(addStatus)
        }
    }

    public func deleteSecret() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingSecretStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
