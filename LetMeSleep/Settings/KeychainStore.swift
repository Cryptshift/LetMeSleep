import Foundation
import Security

/// Stores the Discord bot token in the iOS Keychain (never in UserDefaults or source).
enum KeychainStore {
    static let service = "com.cryptshift.LetMeSleep"
    static let botTokenAccount = "discord-bot-token"

    static var botToken: String? {
        get { string(forAccount: botTokenAccount) }
    }

    /// Saves the token, or deletes it when `token` is blank.
    @discardableResult
    static func setBotToken(_ token: String) -> OSStatus {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? delete(account: botTokenAccount) : set(trimmed, forAccount: botTokenAccount)
    }

    static func string(forAccount account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, forAccount account: String) -> OSStatus {
        let data = Data(value.utf8)
        // Readable after the first unlock so alerts still work while the phone is locked.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        let addQuery = baseQuery(account: account).merging(attributes) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
