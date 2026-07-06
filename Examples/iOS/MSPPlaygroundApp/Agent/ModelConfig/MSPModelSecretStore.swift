import Foundation
import Security

protocol MSPModelSecretStore {
    func loadAPIKey() -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

enum MSPModelSecretStoreError: LocalizedError, Equatable {
    case keychainDeleteFailed(status: OSStatus)
    case keychainSaveFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainDeleteFailed(let status):
            return "Failed to update the saved API key in Keychain. Delete status: \(status)."
        case .keychainSaveFailed(let status):
            return "Failed to save the API key in Keychain. Save status: \(status)."
        }
    }
}

struct MSPModelKeychainSecretStore: MSPModelSecretStore {
    static let shared = MSPModelKeychainSecretStore()

    private let service = "com.model-shell-proxy.playground.model"
    private let apiKeyAccount = "api-key"

    func loadAPIKey() -> String? {
        var query = baseQuery(account: apiKeyAccount)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            try deleteAPIKey()
            return
        }

        try deleteAPIKey()

        var query = baseQuery(account: apiKeyAccount)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MSPModelSecretStoreError.keychainSaveFailed(status: status)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery(account: apiKeyAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MSPModelSecretStoreError.keychainDeleteFailed(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
