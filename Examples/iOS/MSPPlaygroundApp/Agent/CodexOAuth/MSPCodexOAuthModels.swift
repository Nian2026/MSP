import Foundation

enum MSPCodexOAuthLoginStatus: String, Hashable, Sendable {
    case unknown
    case signedOut
    case signingIn
    case signedIn
    case failed

    var title: String {
        switch self {
        case .unknown:
            return "未检查"
        case .signedOut:
            return "未登录"
        case .signingIn:
            return "登录中"
        case .signedIn:
            return "已登录"
        case .failed:
            return "登录异常"
        }
    }
}

enum MSPCodexOAuthQuotaStatus: String, Sendable {
    case success
    case signedOut
    case failed
}

struct MSPCodexOAuthQuotaWindow: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var remainingPercent: Double?
    var usedPercent: Double?
    var resetAt: Date?
}

struct MSPCodexOAuthQuotaResult: Hashable, Sendable {
    var status: MSPCodexOAuthQuotaStatus
    var message: String
    var email: String?
    var planType: String?
    var windows: [MSPCodexOAuthQuotaWindow]
    var checkedAt: Date
}

struct MSPCodexOAuthConfiguration: Hashable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accountID: String
    var email: String
    var planType: String
    var lastLoginStatus: MSPCodexOAuthLoginStatus
    var lastStatusMessage: String
    var lastCheckedAt: Date?

    static let empty = MSPCodexOAuthConfiguration(
        idToken: "",
        accessToken: "",
        refreshToken: "",
        accountID: "",
        email: "",
        planType: "",
        lastLoginStatus: .signedOut,
        lastStatusMessage: "",
        lastCheckedAt: nil
    )

    var hasAccessToken: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasRefreshToken: Bool {
        !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasStoredCredential: Bool {
        hasAccessToken || hasRefreshToken
    }

    func normalized() -> MSPCodexOAuthConfiguration {
        MSPCodexOAuthConfiguration(
            idToken: idToken.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshToken: refreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            planType: planType.trimmingCharacters(in: .whitespacesAndNewlines),
            lastLoginStatus: lastLoginStatus,
            lastStatusMessage: lastStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            lastCheckedAt: lastCheckedAt
        )
    }

    func applyingTokenMetadata() -> MSPCodexOAuthConfiguration {
        let normalized = normalized()
        let metadata = MSPCodexOAuthJWTMetadata(
            idToken: normalized.idToken.nilIfEmpty,
            accessToken: normalized.accessToken.nilIfEmpty
        )
        return MSPCodexOAuthConfiguration(
            idToken: normalized.idToken,
            accessToken: normalized.accessToken,
            refreshToken: normalized.refreshToken,
            accountID: metadata.accountID ?? normalized.accountID,
            email: metadata.email ?? normalized.email,
            planType: metadata.planType ?? normalized.planType,
            lastLoginStatus: normalized.lastLoginStatus,
            lastStatusMessage: normalized.lastStatusMessage,
            lastCheckedAt: normalized.lastCheckedAt
        )
    }
}

enum MSPCodexOAuthConfigurationStore {
    private static let accountIDKey = "msp.playground.codexOAuth.accountID"
    private static let emailKey = "msp.playground.codexOAuth.email"
    private static let planTypeKey = "msp.playground.codexOAuth.planType"
    private static let loginStatusKey = "msp.playground.codexOAuth.loginStatus"
    private static let statusMessageKey = "msp.playground.codexOAuth.statusMessage"
    private static let checkedAtKey = "msp.playground.codexOAuth.checkedAt"

    static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokenStore: MSPCodexOAuthTokenStorage = MSPCodexOAuthKeychainTokenStore.shared
    ) -> MSPCodexOAuthConfiguration {
        let stored = MSPCodexOAuthConfiguration(
            idToken: tokenStore.loadToken(.idToken) ?? "",
            accessToken: tokenStore.loadToken(.accessToken) ?? "",
            refreshToken: tokenStore.loadToken(.refreshToken) ?? "",
            accountID: defaults.string(forKey: accountIDKey) ?? "",
            email: defaults.string(forKey: emailKey) ?? "",
            planType: defaults.string(forKey: planTypeKey) ?? "",
            lastLoginStatus: MSPCodexOAuthLoginStatus(
                rawValue: defaults.string(forKey: loginStatusKey) ?? ""
            ) ?? .signedOut,
            lastStatusMessage: defaults.string(forKey: statusMessageKey) ?? "",
            lastCheckedAt: Date(timeIntervalSince1970: defaults.double(forKey: checkedAtKey))
        )

        var loaded = MSPCodexOAuthConfiguration(
            idToken: nonEmptyEnvironmentValue("MSP_PLAYGROUND_CODEX_ID_TOKEN", in: environment) ?? stored.idToken,
            accessToken: nonEmptyEnvironmentValue("MSP_PLAYGROUND_CODEX_ACCESS_TOKEN", in: environment) ?? stored.accessToken,
            refreshToken: nonEmptyEnvironmentValue("MSP_PLAYGROUND_CODEX_REFRESH_TOKEN", in: environment) ?? stored.refreshToken,
            accountID: nonEmptyEnvironmentValue("MSP_PLAYGROUND_CODEX_ACCOUNT_ID", in: environment) ?? stored.accountID,
            email: nonEmptyEnvironmentValue("MSP_PLAYGROUND_CODEX_EMAIL", in: environment) ?? stored.email,
            planType: nonEmptyEnvironmentValue("MSP_PLAYGROUND_CODEX_PLAN_TYPE", in: environment) ?? stored.planType,
            lastLoginStatus: stored.lastLoginStatus,
            lastStatusMessage: stored.lastStatusMessage,
            lastCheckedAt: defaults.object(forKey: checkedAtKey) == nil ? nil : stored.lastCheckedAt
        ).applyingTokenMetadata()
        guard loaded.hasStoredCredential else {
            return .empty
        }

        let loadedStatus = loaded.lastLoginStatus
        if loadedStatus == .signingIn || loadedStatus == .signedOut || loadedStatus == .unknown {
            loaded.lastLoginStatus = .signedIn
            if loaded.lastStatusMessage.isEmpty || loadedStatus == .signingIn {
                loaded.lastStatusMessage = "Codex OAuth 会话已保存。"
            }
        }
        return loaded
    }

    static func save(
        _ configuration: MSPCodexOAuthConfiguration,
        defaults: UserDefaults = .standard,
        tokenStore: MSPCodexOAuthTokenStorage = MSPCodexOAuthKeychainTokenStore.shared
    ) {
        let normalized = configuration.applyingTokenMetadata()
        defaults.set(normalized.accountID, forKey: accountIDKey)
        defaults.set(normalized.email, forKey: emailKey)
        defaults.set(normalized.planType, forKey: planTypeKey)
        defaults.set(normalized.lastLoginStatus.rawValue, forKey: loginStatusKey)
        defaults.set(normalized.lastStatusMessage, forKey: statusMessageKey)
        if let lastCheckedAt = normalized.lastCheckedAt {
            defaults.set(lastCheckedAt.timeIntervalSince1970, forKey: checkedAtKey)
        } else {
            defaults.removeObject(forKey: checkedAtKey)
        }
        tokenStore.saveToken(normalized.idToken, kind: .idToken)
        tokenStore.saveToken(normalized.accessToken, kind: .accessToken)
        tokenStore.saveToken(normalized.refreshToken, kind: .refreshToken)
    }

    static func clear(
        defaults: UserDefaults = .standard,
        tokenStore: MSPCodexOAuthTokenStorage = MSPCodexOAuthKeychainTokenStore.shared
    ) {
        defaults.removeObject(forKey: accountIDKey)
        defaults.removeObject(forKey: emailKey)
        defaults.removeObject(forKey: planTypeKey)
        defaults.removeObject(forKey: loginStatusKey)
        defaults.removeObject(forKey: statusMessageKey)
        defaults.removeObject(forKey: checkedAtKey)
        tokenStore.deleteAllTokens()
    }

    private static func nonEmptyEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct MSPCodexOAuthJWTMetadata: Hashable, Sendable {
    var email: String?
    var accountID: String?
    var planType: String?
    var accessTokenExpiresAt: Date?

    init(idToken: String?, accessToken: String?) {
        let idPayload = Self.jwtPayload(idToken)
        let accessPayload = Self.jwtPayload(accessToken)
        email = Self.firstString(
            in: [idPayload, accessPayload],
            paths: [
                ["email"],
                ["https://api.openai.com/profile", "email"]
            ]
        )
        accountID = Self.firstString(
            in: [accessPayload, idPayload],
            paths: [
                ["chatgpt_account_id"],
                ["https://api.openai.com/auth", "chatgpt_account_id"],
                ["account_id"]
            ]
        )
        planType = Self.firstString(
            in: [accessPayload, idPayload],
            paths: [
                ["chatgpt_plan_type"],
                ["https://api.openai.com/auth", "chatgpt_plan_type"],
                ["plan_type"]
            ]
        )
        if let exp = Self.firstDouble(in: accessPayload, paths: [["exp"]]) {
            accessTokenExpiresAt = Date(timeIntervalSince1970: exp)
        } else {
            accessTokenExpiresAt = nil
        }
    }

    private static func jwtPayload(_ token: String?) -> [String: Any] {
        guard let token,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload.append(String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func firstString(in payloads: [[String: Any]], paths: [[String]]) -> String? {
        for payload in payloads {
            for path in paths {
                if let value = value(in: payload, path: path) {
                    if let string = value as? String {
                        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    } else if let number = value as? NSNumber {
                        return number.stringValue
                    }
                }
            }
        }
        return nil
    }

    private static func firstDouble(in payload: [String: Any], paths: [[String]]) -> Double? {
        for path in paths {
            if let value = value(in: payload, path: path) {
                if let double = value as? Double {
                    return double
                }
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                if let string = value as? String {
                    return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return nil
    }

    private static func value(in payload: [String: Any], path: [String]) -> Any? {
        var current: Any = payload
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
