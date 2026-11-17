import Foundation
import Security

public struct TranslationCredentialStore {
    static let service = "com.iine.app.translation"
    private static let account = "deepseek"

    enum Lookup {
        case found(String), notFound, unavailable
    }

    struct KeychainAccess {
        let read: (String) -> Lookup
        let write: (String, String) -> Bool
        let remove: (String) -> Bool

        static let live = KeychainAccess(
            read: { service in
                var query = TranslationCredentialStore.query(service: service)
                query[kSecReturnData as String] = kCFBooleanTrue
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecItemNotFound { return .notFound }
                guard status == errSecSuccess,
                      let data = item as? Data,
                      let key = String(data: data, encoding: .utf8), !key.isEmpty else { return .unavailable }
                return .found(key)
            },
            write: { service, key in
                let query = TranslationCredentialStore.query(service: service)
                let value = [kSecValueData as String: Data(key.utf8)]
                let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
                if status == errSecSuccess { return true }
                guard status == errSecItemNotFound else { return false }
                var attributes = query
                attributes[kSecValueData as String] = Data(key.utf8)
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let added = SecItemAdd(attributes as CFDictionary, nil)
                if added == errSecDuplicateItem {
                    return SecItemUpdate(query as CFDictionary, value as CFDictionary) == errSecSuccess
                }
                return added == errSecSuccess
            },
            remove: { service in
                let status = SecItemDelete(TranslationCredentialStore.query(service: service) as CFDictionary)
                return status == errSecSuccess || status == errSecItemNotFound
            }
        )
    }

    private let keychain: KeychainAccess

    public init() { keychain = .live }
    init(keychain: KeychainAccess) { self.keychain = keychain }

    public func load() -> String? {
        switch keychain.read(Self.service) {
        case .found(let key): return key
        case .unavailable: return nil
        case .notFound:
            guard case .found(let key) = keychain.read(LegacyBrandMigration.credentialService) else { return nil }
            _ = save(key)
            return key
        }
    }

    @discardableResult
    public func save(_ key: String) -> Bool {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return keychain.write(Self.service, key)
    }

    @discardableResult
    public func delete() -> Bool {
        let removedCurrent = keychain.remove(Self.service)
        let removedLegacy = keychain.remove(LegacyBrandMigration.credentialService)
        return removedCurrent && removedLegacy
    }

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
