import Foundation
import Security

/// Persists the server session token. Replaces the Capacitor `Preferences` plugin the web
/// client used (`network.js:12-26`); the Keychain is used rather than UserDefaults because
/// the token authenticates the player's account.
enum SessionStore {
    private static let service = "com.allr.joelsworld"
    private static let account = "player_token"

#if os(macOS)
    /// The admin editor keeps its token in `UserDefaults` instead. It is a developer tool
    /// running on the operator's own Mac, and the file-based macOS keychain prompts for
    /// access every time the app's signature changes — which is every rebuild here.
    private static let defaultsKey = "admin_session_token"

    static func loadToken() -> String? {
        let token = UserDefaults.standard.string(forKey: defaultsKey)
        return (token?.isEmpty ?? true) ? nil : token
    }

    static func saveToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: defaultsKey)
    }

    static func clearToken() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
#else
    static func loadToken() -> String? {
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
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    static func saveToken(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(token.utf8)

        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func clearToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
#endif
}
