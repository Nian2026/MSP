import XCTest
@testable import PhotoSorter

final class MSPCodexOAuthConfigurationStoreTests: XCTestCase {
    func testSaveAndLoadPersistsOAuthConfigurationAcrossDefaultsAndTokenStore() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        let checkedAt = Date(timeIntervalSince1970: 1_782_526_761)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "id-token",
                accessToken: "access-token",
                refreshToken: "refresh-token",
                accountID: "account-123",
                email: "reader@example.test",
                planType: "pro",
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 会话已保存。",
                lastCheckedAt: checkedAt
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            tokenStore: tokenStore
        )

        XCTAssertEqual(loaded.idToken, "id-token")
        XCTAssertEqual(loaded.accessToken, "access-token")
        XCTAssertEqual(loaded.refreshToken, "refresh-token")
        XCTAssertEqual(loaded.accountID, "account-123")
        XCTAssertEqual(loaded.email, "reader@example.test")
        XCTAssertEqual(loaded.planType, "pro")
        XCTAssertEqual(loaded.lastLoginStatus, .signedIn)
        XCTAssertEqual(loaded.lastStatusMessage, "Codex OAuth 会话已保存。")
        XCTAssertEqual(loaded.lastCheckedAt, checkedAt)
    }

    func testLoadTurnsInterruptedSigningInStateIntoStableSavedSessionState() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "",
                accessToken: "access-token",
                refreshToken: "",
                accountID: "",
                email: "",
                planType: "",
                lastLoginStatus: .signingIn,
                lastStatusMessage: "正在打开 Codex OAuth 登录页面…",
                lastCheckedAt: nil
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            tokenStore: tokenStore
        )

        XCTAssertEqual(loaded.lastLoginStatus, .signedIn)
        XCTAssertEqual(loaded.lastStatusMessage, "Codex OAuth 会话已保存。")
        XCTAssertEqual(loaded.accessToken, "access-token")
    }

    func testLoadRestoresSignedInStateWhenStoredCredentialExists() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "",
                accessToken: "",
                refreshToken: "refresh-token",
                accountID: "",
                email: "",
                planType: "",
                lastLoginStatus: .signedOut,
                lastStatusMessage: "",
                lastCheckedAt: nil
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            tokenStore: tokenStore
        )

        XCTAssertEqual(loaded.lastLoginStatus, .signedIn)
        XCTAssertEqual(loaded.lastStatusMessage, "Codex OAuth 会话已保存。")
        XCTAssertEqual(loaded.refreshToken, "refresh-token")
    }

    func testLoadDropsStaleSignedInStateWhenStoredCredentialIsMissing() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "id-token",
                accessToken: "access-token",
                refreshToken: "refresh-token",
                accountID: "account-123",
                email: "reader@example.test",
                planType: "pro",
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 会话已保存。",
                lastCheckedAt: Date(timeIntervalSince1970: 1_782_526_761)
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )
        tokenStore.deleteAllTokens()

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            tokenStore: tokenStore
        )

        XCTAssertEqual(loaded, .empty)
    }

    func testBlankEnvironmentDoesNotClearStoredOAuthConfiguration() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "stored-id-token",
                accessToken: "stored-access-token",
                refreshToken: "stored-refresh-token",
                accountID: "stored-account",
                email: "stored@example.test",
                planType: "plus",
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 会话已保存。",
                lastCheckedAt: nil
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [
                "MSP_PLAYGROUND_CODEX_ID_TOKEN": "",
                "MSP_PLAYGROUND_CODEX_ACCESS_TOKEN": "   ",
                "MSP_PLAYGROUND_CODEX_REFRESH_TOKEN": "",
                "MSP_PLAYGROUND_CODEX_ACCOUNT_ID": "",
                "MSP_PLAYGROUND_CODEX_EMAIL": "",
                "MSP_PLAYGROUND_CODEX_PLAN_TYPE": ""
            ],
            tokenStore: tokenStore
        )

        XCTAssertEqual(loaded.idToken, "stored-id-token")
        XCTAssertEqual(loaded.accessToken, "stored-access-token")
        XCTAssertEqual(loaded.refreshToken, "stored-refresh-token")
        XCTAssertEqual(loaded.accountID, "stored-account")
        XCTAssertEqual(loaded.email, "stored@example.test")
        XCTAssertEqual(loaded.planType, "plus")
        XCTAssertEqual(loaded.lastLoginStatus, .signedIn)
    }

    func testNonEmptyEnvironmentOverridesStoredOAuthConfigurationForE2E() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "stored-id-token",
                accessToken: "stored-access-token",
                refreshToken: "stored-refresh-token",
                accountID: "stored-account",
                email: "stored@example.test",
                planType: "plus",
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 会话已保存。",
                lastCheckedAt: nil
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [
                "MSP_PLAYGROUND_CODEX_ID_TOKEN": "env-id-token",
                "MSP_PLAYGROUND_CODEX_ACCESS_TOKEN": "env-access-token",
                "MSP_PLAYGROUND_CODEX_REFRESH_TOKEN": "env-refresh-token",
                "MSP_PLAYGROUND_CODEX_ACCOUNT_ID": "env-account",
                "MSP_PLAYGROUND_CODEX_EMAIL": "env@example.test",
                "MSP_PLAYGROUND_CODEX_PLAN_TYPE": "pro"
            ],
            tokenStore: tokenStore
        )

        XCTAssertEqual(loaded.idToken, "env-id-token")
        XCTAssertEqual(loaded.accessToken, "env-access-token")
        XCTAssertEqual(loaded.refreshToken, "env-refresh-token")
        XCTAssertEqual(loaded.accountID, "env-account")
        XCTAssertEqual(loaded.email, "env@example.test")
        XCTAssertEqual(loaded.planType, "pro")
        XCTAssertEqual(loaded.lastLoginStatus, .signedIn)
    }

    func testClearRemovesOAuthDefaultsAndTokens() throws {
        let suiteName = "MSPCodexOAuthConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tokenStore = InMemoryCodexOAuthTokenStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MSPCodexOAuthConfigurationStore.save(
            MSPCodexOAuthConfiguration(
                idToken: "id-token",
                accessToken: "access-token",
                refreshToken: "refresh-token",
                accountID: "account-123",
                email: "reader@example.test",
                planType: "pro",
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 会话已保存。",
                lastCheckedAt: Date(timeIntervalSince1970: 1_782_526_761)
            ),
            defaults: defaults,
            tokenStore: tokenStore
        )

        MSPCodexOAuthConfigurationStore.clear(
            defaults: defaults,
            tokenStore: tokenStore
        )

        let loaded = MSPCodexOAuthConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            tokenStore: tokenStore
        )
        XCTAssertEqual(loaded, .empty)
        XCTAssertNil(tokenStore.loadToken(.idToken))
        XCTAssertNil(tokenStore.loadToken(.accessToken))
        XCTAssertNil(tokenStore.loadToken(.refreshToken))
    }
}

private final class InMemoryCodexOAuthTokenStore: MSPCodexOAuthTokenStorage {
    private var tokens: [MSPCodexOAuthTokenKind: String] = [:]

    func loadToken(_ kind: MSPCodexOAuthTokenKind) -> String? {
        tokens[kind]
    }

    func saveToken(_ token: String, kind: MSPCodexOAuthTokenKind) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            tokens.removeValue(forKey: kind)
        } else {
            tokens[kind] = trimmed
        }
    }

    func deleteToken(_ kind: MSPCodexOAuthTokenKind) {
        tokens.removeValue(forKey: kind)
    }

    func deleteAllTokens() {
        tokens.removeAll()
    }
}
