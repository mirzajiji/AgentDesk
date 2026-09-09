import Foundation
import LocalAuthentication
import Security

struct SystemKeychainBackend: KeychainBackend {
    func set(_ data: Data, service: String, account: String) throws {
        let query = query(service: service, account: account)
        let change = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, change)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
            // Another authorized process may have inserted the same identity between update and add.
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, change) }
        }
        try check(status)
    }

    func get(service: String, account: String) throws -> Data? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw SecretStoreError.invalidResult }
        return data
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    func exists(service: String, account: String) throws -> Bool {
        var query = query(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Existence never requests secret bytes.
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    private func query(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }
}
