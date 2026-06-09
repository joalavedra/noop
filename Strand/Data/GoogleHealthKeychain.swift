import Foundation
import Security

/// Minimal Keychain storage for the Google Health OAuth client credentials and
/// refresh token, so sign-in is one-time. Values live in the login keychain under
/// one service; nothing is written to disk in the clear.
enum GoogleHealthKeychain {

    private static let service = "com.noopapp.strand.googlehealth"

    static var clientId: String? { load("clientId") }
    static var clientSecret: String? { load("clientSecret") }
    static var refreshToken: String? { load("refreshToken") }

    static func store(clientId: String, clientSecret: String, refreshToken: String) {
        save(clientId, account: "clientId")
        save(clientSecret, account: "clientSecret")
        save(refreshToken, account: "refreshToken")
    }

    /// Forget the refresh token (e.g. "Disconnect"), keeping the client id/secret
    /// so the next connect only needs a fresh sign-in.
    static func clearToken() { delete("refreshToken") }

    // MARK: - Primitives

    private static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    private static func load(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
