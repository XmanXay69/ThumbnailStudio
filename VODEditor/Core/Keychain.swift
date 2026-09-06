import Foundation
import Security

/// Minimal Keychain wrapper for the Anthropic API key.
///
/// The key is a credential, so it goes in the Keychain rather than
/// UserDefaults, where it would sit in plaintext inside the app's preferences
/// plist. Nothing else in this app needs secure storage.
enum Keychain {
    private static let service = "com.xavier.vodeditor"

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static let anthropicAPIKey = "anthropic-api-key"
    /// Only for generating thumbnail backgrounds — Claude doesn't make images.
    static let openAIAPIKey = "openai-api-key"
}
