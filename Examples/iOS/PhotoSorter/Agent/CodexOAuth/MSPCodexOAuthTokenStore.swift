import Foundation
import Security

protocol MSPCodexOAuthTokenStorage {
    func loadToken(_ kind: MSPCodexOAuthTokenKind) -> String?
    func saveToken(_ token: String, kind: MSPCodexOAuthTokenKind)
    func deleteToken(_ kind: MSPCodexOAuthTokenKind)
    func deleteAllTokens()
}

enum MSPCodexOAuthTokenKind: String, CaseIterable {
    case idToken = "id-token"
    case accessToken = "access-token"
    case refreshToken = "refresh-token"
}

enum MSPCodexOAuthTokenStore {
    typealias TokenKind = MSPCodexOAuthTokenKind

    static func loadToken(_ kind: TokenKind) -> String? {
        MSPCodexOAuthKeychainTokenStore.shared.loadToken(kind)
    }

    static func saveToken(_ token: String, kind: TokenKind) {
        MSPCodexOAuthKeychainTokenStore.shared.saveToken(token, kind: kind)
    }

    static func deleteToken(_ kind: TokenKind) {
        MSPCodexOAuthKeychainTokenStore.shared.deleteToken(kind)
    }

    static func deleteAllTokens() {
        MSPCodexOAuthKeychainTokenStore.shared.deleteAllTokens()
    }
}

struct MSPCodexOAuthKeychainTokenStore: MSPCodexOAuthTokenStorage {
    static let shared = MSPCodexOAuthKeychainTokenStore()

    private static let service = "com.model-shell-proxy.playground.codex-oauth"

    private let service = MSPCodexOAuthKeychainTokenStore.service

    func loadToken(_ kind: MSPCodexOAuthTokenKind) -> String? {
        var query = baseQuery(kind: kind)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveToken(_ token: String, kind: MSPCodexOAuthTokenKind) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            deleteToken(kind)
            return
        }

        deleteToken(kind)

        var query = baseQuery(kind: kind)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteToken(_ kind: MSPCodexOAuthTokenKind) {
        SecItemDelete(baseQuery(kind: kind) as CFDictionary)
    }

    func deleteAllTokens() {
        for kind in MSPCodexOAuthTokenKind.allCases {
            deleteToken(kind)
        }
    }

    private func baseQuery(kind: MSPCodexOAuthTokenKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue
        ]
    }
}
