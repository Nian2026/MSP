import MSPAgentBridge
import XCTest
@testable import MSPPlaygroundApp

final class MSPModelConfigurationStoreTests: XCTestCase {
    func testLoadUsesModelDefaultReasoningAndVerbosityMedium() {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemoryModelSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = MSPModelConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            secretStore: secretStore
        )

        XCTAssertEqual(configuration.reasoningEffort, "model_default")
        XCTAssertEqual(configuration.verbosity, "medium")
    }

    func testSaveAndLoadPersistsModelConfiguration() throws {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secretStore = InMemoryModelSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        try MSPModelConfigurationStore.save(
            MSPModelConfiguration(
                providerName: "OpenAI-compatible",
                baseURL: URL(string: "https://api.example.test/v1"),
                apiKey: "persisted-key",
                modelID: "gpt-test",
                credentialMode: MSPModelCredentialMode.codexOAuth.rawValue,
                apiStyle: "responses",
                endpointType: "openai-response",
                endpointPathOverride: "/v1/responses",
                reasoningEffort: "high",
                verbosity: "low"
            ),
            defaults: defaults,
            secretStore: secretStore
        )

        let configuration = MSPModelConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            secretStore: secretStore
        )

        XCTAssertEqual(configuration.providerName, "OpenAI-compatible")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://api.example.test/v1")
        XCTAssertEqual(configuration.apiKey, "persisted-key")
        XCTAssertEqual(configuration.modelID, "gpt-test")
        XCTAssertEqual(configuration.credentialMode, MSPModelCredentialMode.codexOAuth.rawValue)
        XCTAssertEqual(configuration.apiStyle, "responses")
        XCTAssertEqual(configuration.endpointType, "openai-response")
        XCTAssertEqual(configuration.endpointPathOverride, "/v1/responses")
        XCTAssertEqual(configuration.reasoningEffort, "high")
        XCTAssertEqual(configuration.verbosity, "low")
        XCTAssertNil(defaults.string(forKey: "msp.playground.model.apiKey"))
        XCTAssertEqual(secretStore.loadAPIKey(), "persisted-key")
    }

    func testLoadUsesLaunchEnvironmentOverridesForAutomatedE2E() {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemoryModelSecretStore(apiKey: "stored-key")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = MSPModelConfigurationStore.load(
            defaults: defaults,
            environment: [
                "MSP_PLAYGROUND_MODEL_PROVIDER": "TestProvider",
                "MSP_PLAYGROUND_MODEL_BASE_URL": "https://example.test/v1",
                "MSP_PLAYGROUND_MODEL_API_KEY": "test-key",
                "MSP_PLAYGROUND_MODEL": "test-model",
                "MSP_PLAYGROUND_MODEL_CREDENTIAL_MODE": MSPModelCredentialMode.codexOAuth.rawValue,
                "MSP_PLAYGROUND_REASONING_EFFORT": "low",
                "MSP_PLAYGROUND_VERBOSITY": "high"
            ],
            secretStore: secretStore
        )

        XCTAssertEqual(configuration.providerName, "TestProvider")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://example.test/v1")
        XCTAssertEqual(configuration.apiKey, "test-key")
        XCTAssertEqual(configuration.modelID, "test-model")
        XCTAssertEqual(configuration.credentialMode, MSPModelCredentialMode.codexOAuth.rawValue)
        XCTAssertEqual(configuration.reasoningEffort, "low")
        XCTAssertEqual(configuration.verbosity, "high")
    }

    func testBlankLaunchEnvironmentDoesNotClearStoredConfiguration() throws {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemoryModelSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        try MSPModelConfigurationStore.save(
            MSPModelConfiguration(
                providerName: "StoredProvider",
                baseURL: URL(string: "https://stored.example.test/v1"),
                apiKey: "stored-key",
                modelID: "stored-model",
                apiStyle: "responses",
                endpointType: "openai-response",
                endpointPathOverride: "/custom/responses",
                reasoningEffort: "high",
                verbosity: "low"
            ),
            defaults: defaults,
            secretStore: secretStore
        )

        let configuration = MSPModelConfigurationStore.load(
            defaults: defaults,
            environment: [
                "MSP_PLAYGROUND_MODEL_PROVIDER": "",
                "MSP_PLAYGROUND_MODEL_BASE_URL": "   ",
                "MSP_PLAYGROUND_MODEL_API_KEY": "",
                "MSP_PLAYGROUND_MODEL": "",
                "MSP_PLAYGROUND_MODEL_CREDENTIAL_MODE": "",
                "MSP_PLAYGROUND_MODEL_API_STYLE": "",
                "MSP_PLAYGROUND_MODEL_ENDPOINT_TYPE": "",
                "MSP_PLAYGROUND_MODEL_ENDPOINT_PATH_OVERRIDE": "",
                "MSP_PLAYGROUND_REASONING_EFFORT": "",
                "MSP_PLAYGROUND_VERBOSITY": ""
            ],
            secretStore: secretStore
        )

        XCTAssertEqual(configuration.providerName, "StoredProvider")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://stored.example.test/v1")
        XCTAssertEqual(configuration.apiKey, "stored-key")
        XCTAssertEqual(configuration.modelID, "stored-model")
        XCTAssertEqual(configuration.credentialMode, MSPModelCredentialMode.apiKey.rawValue)
        XCTAssertEqual(configuration.apiStyle, "responses")
        XCTAssertEqual(configuration.endpointType, "openai-response")
        XCTAssertEqual(configuration.endpointPathOverride, "/custom/responses")
        XCTAssertEqual(configuration.reasoningEffort, "high")
        XCTAssertEqual(configuration.verbosity, "low")
    }

    func testLoadMigratesLegacyDefaultsAPIKeyToSecretStore() {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemoryModelSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("legacy-key", forKey: "msp.playground.model.apiKey")
        defaults.set("https://legacy.example.test/v1", forKey: "msp.playground.model.baseURL")
        defaults.set("legacy-model", forKey: "msp.playground.model.model")

        let configuration = MSPModelConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            secretStore: secretStore
        )

        XCTAssertEqual(configuration.apiKey, "legacy-key")
        XCTAssertEqual(secretStore.loadAPIKey(), "legacy-key")
        XCTAssertNil(defaults.string(forKey: "msp.playground.model.apiKey"))
    }

    func testLegacyDefaultsAPIKeySurvivesWhenSecretStoreMigrationFails() {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingModelSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("legacy-key", forKey: "msp.playground.model.apiKey")

        let configuration = MSPModelConfigurationStore.load(
            defaults: defaults,
            environment: [:],
            secretStore: secretStore
        )

        XCTAssertEqual(configuration.apiKey, "legacy-key")
        XCTAssertEqual(defaults.string(forKey: "msp.playground.model.apiKey"), "legacy-key")
    }

    func testSaveThrowsBeforeWritingDefaultsWhenSecretStoreFails() {
        let suiteName = "MSPModelConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingModelSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertThrowsError(
            try MSPModelConfigurationStore.save(
                MSPModelConfiguration(
                    providerName: "Provider",
                    baseURL: URL(string: "https://api.example.test/v1"),
                    apiKey: "persisted-key",
                    modelID: "gpt-test",
                    reasoningEffort: "medium",
                    verbosity: "medium"
                ),
                defaults: defaults,
                secretStore: secretStore
            )
        ) { error in
            XCTAssertEqual(
                error as? MSPModelSecretStoreError,
                MSPModelSecretStoreError.keychainSaveFailed(status: -34018)
            )
        }

        XCTAssertNil(defaults.string(forKey: "msp.playground.model.providerName"))
        XCTAssertNil(defaults.string(forKey: "msp.playground.model.baseURL"))
        XCTAssertNil(defaults.string(forKey: "msp.playground.model.model"))
    }

    func testConfigurationNormalizesProviderEndpointAndResponseOptions() throws {
        let configuration = MSPModelConfiguration(
            providerName: " Provider ",
            baseURL: URL(string: "https://api.example.test/v1"),
            apiKey: " key ",
            modelID: " model-id ",
            apiStyle: " responses ",
            endpointType: " openai-response ",
            endpointPathOverride: " /responses ",
            reasoningEffort: " HIGH ",
            verbosity: " LOW "
        )

        let normalized = configuration.normalized()

        XCTAssertEqual(normalized.providerName, "Provider")
        XCTAssertEqual(normalized.baseURL?.absoluteString, "https://api.example.test/v1")
        XCTAssertEqual(normalized.apiKey, "key")
        XCTAssertEqual(normalized.modelID, "model-id")
        XCTAssertEqual(normalized.apiStyle, "responses")
        XCTAssertEqual(normalized.endpointType, "openai-response")
        XCTAssertEqual(normalized.endpointPathOverride, "/responses")
        XCTAssertEqual(normalized.reasoningEffort, "HIGH")
        XCTAssertEqual(normalized.verbosity, "LOW")
    }

    func testDraftCommitPreservesOriginalAPIKeyWhenReplacementFieldIsBlank() {
        let draft = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.example.test/v1"),
            apiKey: "   ",
            modelID: "gpt-test",
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        let committed = MSPModelConfigurationDraftCommit.committedConfiguration(
            from: draft,
            originalAPIKey: "stored-key",
            clearsAPIKey: false
        )

        XCTAssertEqual(committed.apiKey, "stored-key")
    }

    func testDraftCommitReplacesOriginalAPIKeyWhenNewKeyIsProvided() {
        let draft = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.example.test/v1"),
            apiKey: " new-key ",
            modelID: "gpt-test",
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        let committed = MSPModelConfigurationDraftCommit.committedConfiguration(
            from: draft,
            originalAPIKey: "stored-key",
            clearsAPIKey: false
        )

        XCTAssertEqual(committed.apiKey, "new-key")
    }

    func testDraftCommitClearsOriginalAPIKeyWhenRequested() {
        let draft = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.example.test/v1"),
            apiKey: "new-key",
            modelID: "gpt-test",
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        let committed = MSPModelConfigurationDraftCommit.committedConfiguration(
            from: draft,
            originalAPIKey: "stored-key",
            clearsAPIKey: true
        )

        XCTAssertEqual(committed.apiKey, "")
    }

    func testAPIKeyStatusDistinguishesBlankFieldFromMissingSecret() {
        XCTAssertEqual(
            MSPModelAPIKeyStatus.status(
                hasSavedAPIKey: true,
                draftAPIKey: "   ",
                clearsAPIKey: false
            ),
            .saved
        )
        XCTAssertEqual(
            MSPModelAPIKeyStatus.status(
                hasSavedAPIKey: false,
                draftAPIKey: "   ",
                clearsAPIKey: false
            ),
            .missing
        )
    }

    func testAPIKeyStatusShowsReplacementAndRemovalIntent() {
        XCTAssertEqual(
            MSPModelAPIKeyStatus.status(
                hasSavedAPIKey: true,
                draftAPIKey: "new-key",
                clearsAPIKey: false
            ),
            .willReplace
        )
        XCTAssertEqual(
            MSPModelAPIKeyStatus.status(
                hasSavedAPIKey: true,
                draftAPIKey: "new-key",
                clearsAPIKey: true
            ),
            .willRemove
        )
        XCTAssertEqual(MSPModelAPIKeyStatus.missing.text, "No API key saved")
        XCTAssertEqual(MSPModelAPIKeyStatus.saved.text, "API key saved in Keychain")
    }

    func testAPIKeyStatusDrivesVisibleConfigurationFieldState() {
        XCTAssertEqual(MSPModelAPIKeyStatus.missing.fieldPrompt, "API key")
        XCTAssertEqual(MSPModelAPIKeyStatus.missing.systemImageName, "exclamationmark.circle")
        XCTAssertFalse(MSPModelAPIKeyStatus.missing.isPositive)
        XCTAssertFalse(MSPModelAPIKeyStatus.missing.isPendingReplacement)
        XCTAssertFalse(MSPModelAPIKeyStatus.missing.isDestructive)

        XCTAssertEqual(MSPModelAPIKeyStatus.saved.fieldPrompt, "New API key (optional)")
        XCTAssertEqual(MSPModelAPIKeyStatus.saved.systemImageName, "checkmark.circle.fill")
        XCTAssertTrue(MSPModelAPIKeyStatus.saved.isPositive)

        XCTAssertEqual(MSPModelAPIKeyStatus.willReplace.fieldPrompt, "New API key")
        XCTAssertEqual(MSPModelAPIKeyStatus.willReplace.systemImageName, "arrow.triangle.2.circlepath.circle.fill")
        XCTAssertTrue(MSPModelAPIKeyStatus.willReplace.isPendingReplacement)

        XCTAssertEqual(MSPModelAPIKeyStatus.willRemove.fieldPrompt, "API key")
        XCTAssertEqual(MSPModelAPIKeyStatus.willRemove.systemImageName, "trash.circle.fill")
        XCTAssertTrue(MSPModelAPIKeyStatus.willRemove.isDestructive)
    }

    func testModelCredentialResolverPrefersExplicitAPIKey() throws {
        let resolved = try XCTUnwrap(
            MSPModelConfigurationResolver.resolve(
                configuration: MSPModelConfiguration(
                    providerName: "OpenAI-compatible",
                    baseURL: URL(string: "https://proxy.example.test/v1"),
                    apiKey: "api-key",
                    modelID: "gpt-test",
                    reasoningEffort: "medium",
                    verbosity: "medium"
                ),
                codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token")
            )
        )

        XCTAssertEqual(resolved.credentialSource, .apiKey)
        XCTAssertEqual(resolved.configuration.apiKey, "api-key")
    }

    func testModelCredentialResolverUsesCodexOAuthForCompatibleProxyWhenAPIKeyIsBlank() throws {
        let resolved = try XCTUnwrap(
            MSPModelConfigurationResolver.resolve(
                configuration: MSPModelConfiguration(
                    providerName: "OpenAI-compatible",
                    baseURL: URL(string: "https://proxy.example.test/v1"),
                    apiKey: "   ",
                    modelID: "gpt-test",
                    reasoningEffort: "medium",
                    verbosity: "medium"
                ),
                codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token")
            )
        )

        XCTAssertEqual(resolved.credentialSource, .codexOAuthAccessToken)
        XCTAssertEqual(resolved.configuration.apiKey, "oauth-token")
        XCTAssertEqual(resolved.configuration.baseURL?.absoluteString, "https://proxy.example.test/v1")
        XCTAssertTrue(resolved.additionalHTTPHeaders.isEmpty)
    }

    func testModelCredentialResolverRoutesOfficialOpenAIAPIHostToCodexOAuthBackend() throws {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "   ",
            modelID: "gpt-5",
            reasoningEffort: "medium",
            verbosity: "medium"
        )
        let codexOAuth = codexOAuthConfiguration(
            accessToken: "oauth-token",
            accountID: "account-123"
        )
        let resolved = try XCTUnwrap(
            MSPModelConfigurationResolver.resolve(
                configuration: configuration,
                codexOAuthConfiguration: codexOAuth
            )
        )

        XCTAssertEqual(resolved.credentialSource, .codexOAuthAccessToken)
        XCTAssertEqual(resolved.configuration.providerName, "Codex OAuth")
        XCTAssertEqual(resolved.configuration.baseURL?.absoluteString, "https://chatgpt.com/backend-api/codex")
        XCTAssertEqual(resolved.configuration.apiKey, "oauth-token")
        XCTAssertEqual(
            resolved.configuration.modelID,
            MSPModelConfigurationResolver.codexOAuthDefaultModelID
        )
        XCTAssertEqual(resolved.additionalHTTPHeaders["Chatgpt-Account-Id"], "account-123")
        XCTAssertEqual(resolved.additionalHTTPHeaders["originator"], "codex_cli_rs")
        XCTAssertNotNil(resolved.additionalHTTPHeaders["User-Agent"])
    }

    func testModelCredentialResolverPreservesExplicitOAuthModelWhenRoutingToCodexBackend() throws {
        let resolved = try XCTUnwrap(
            MSPModelConfigurationResolver.resolve(
                configuration: MSPModelConfiguration(
                    providerName: "OpenAI-compatible",
                    baseURL: URL(string: "https://api.openai.com/v1"),
                    apiKey: "   ",
                    modelID: "gpt-custom-codex",
                    reasoningEffort: "medium",
                    verbosity: "medium"
                ),
                codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token")
            )
        )

        XCTAssertEqual(resolved.configuration.modelID, "gpt-custom-codex")
    }

    func testModelCredentialResolverUsesOAuthModeEvenWhenAPIKeyIsSaved() throws {
        let resolved = try XCTUnwrap(
            MSPModelConfigurationResolver.resolve(
                configuration: MSPModelConfiguration(
                    providerName: "Codex OAuth",
                    baseURL: URL(string: "https://api.openai.com/v1"),
                    apiKey: "saved-api-key",
                    modelID: "gpt-5.4",
                    credentialMode: MSPModelCredentialMode.codexOAuth.rawValue,
                    reasoningEffort: "medium",
                    verbosity: "medium"
                ),
                codexOAuthConfiguration: codexOAuthConfiguration(
                    accessToken: "oauth-token",
                    accountID: "account-123"
                )
            )
        )

        XCTAssertEqual(resolved.credentialSource, .codexOAuthAccessToken)
        XCTAssertEqual(resolved.configuration.apiKey, "oauth-token")
        XCTAssertEqual(resolved.configuration.modelID, "gpt-5.4")
        XCTAssertEqual(resolved.additionalHTTPHeaders["Chatgpt-Account-Id"], "account-123")
    }

    func testModelPickerCatalogBuildsAPIKeyAndOAuthOptions() {
        let configuration = MSPModelConfiguration(
            providerName: "Codex OAuth",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "gpt-5.4",
            credentialMode: MSPModelCredentialMode.codexOAuth.rawValue,
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        let options = MSPModelPickerCatalog.options(
            configuration: configuration,
            codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token")
        )

        XCTAssertTrue(options.contains { $0.source == .apiKey && $0.modelID == "gpt-5.6-sol" && $0.isEnabled })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.4" && $0.isEnabled && $0.isSelected })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.6-sol" && $0.isEnabled })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.5" && $0.isEnabled })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.4-mini" && $0.isEnabled })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.2" && $0.isEnabled })
        XCTAssertFalse(options.contains { $0.modelID == "gpt-5.3-codex" })
        XCTAssertFalse(options.contains { $0.modelID == "gpt-5.3-codex-spark" })
        XCTAssertFalse(options.contains { $0.modelID == "gpt-5" })
        XCTAssertFalse(options.contains { $0.source == .codexOAuth && $0.modelID == "codex-auto-review" })
    }

    func testModelPickerCatalogUsesCredentialSpecificSnapshots() throws {
        let sharedAPIModel = MSPModelCapabilities(
            slug: "shared-model",
            displayName: "Shared API",
            defaultReasoningEffort: .high,
            supportedReasoningEfforts: [.low, .medium, .high].map {
                MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
            },
            contextWindow: 200_000
        )
        let sharedOAuthModel = MSPModelCapabilities(
            slug: "shared-model",
            displayName: "Shared OAuth",
            defaultReasoningEffort: .low,
            supportedReasoningEfforts: [.low, .ultra].map {
                MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
            },
            contextWindow: 400_000
        )
        let snapshots = MSPModelPickerCatalogSnapshots(
            apiKey: MSPModelCatalogSnapshot(
                models: [
                    sharedAPIModel,
                    MSPModelCapabilities(slug: "api-only", contextWindow: 200_000)
                ],
                metadataSource: .provided
            ),
            codexOAuth: MSPModelCatalogSnapshot(
                models: [
                    sharedOAuthModel,
                    MSPModelCapabilities(slug: "oauth-only", contextWindow: 400_000)
                ],
                metadataSource: .provided
            )
        )
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "shared-model",
            credentialMode: MSPModelCredentialMode.apiKey.rawValue,
            reasoningEffort: "high",
            verbosity: "medium"
        )

        let options = MSPModelPickerCatalog.options(
            configuration: configuration,
            codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token"),
            snapshots: snapshots
        )

        XCTAssertTrue(options.contains { $0.source == .apiKey && $0.modelID == "api-only" })
        XCTAssertFalse(options.contains { $0.source == .apiKey && $0.modelID == "oauth-only" })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "oauth-only" })
        XCTAssertFalse(options.contains { $0.source == .codexOAuth && $0.modelID == "api-only" })

        let oauthOption = try XCTUnwrap(options.first {
            $0.source == .codexOAuth && $0.modelID == "shared-model"
        })
        let selected = MSPModelPickerCatalog.configuration(
            selecting: oauthOption,
            from: configuration,
            snapshots: snapshots
        )
        XCTAssertEqual(selected.reasoningEffort, "low")

        var oauthConfiguration = selected
        oauthConfiguration.reasoningEffort = "high"
        XCTAssertEqual(
            MSPModelPickerCatalog.reasoningEffortSelection(
                configuration: oauthConfiguration,
                snapshots: snapshots
            ),
            "low"
        )
        XCTAssertEqual(
            MSPModelPickerCatalog.reasoningEffortPresets(
                configuration: oauthConfiguration,
                snapshots: snapshots
            ).map(\.effort),
            [.modelDefault, .low, .ultra]
        )
    }

    func testModelPickerCatalogSnapshotsPreserveInactiveAPISource() {
        let apiSnapshot = MSPModelCatalogSnapshot(
            models: [MSPModelCapabilities(slug: "custom-api", contextWindow: 200_000)],
            metadataSource: .remote,
            providerID: "custom-api"
        )
        let oauthSnapshot = MSPModelCatalogSnapshot(
            models: [MSPModelCapabilities(slug: "oauth-new", contextWindow: 400_000)],
            metadataSource: .remote,
            providerID: "codex-oauth"
        )

        let updated = MSPModelPickerCatalogSnapshots(apiKey: apiSnapshot).updating(
            apiKey: nil,
            codexOAuth: oauthSnapshot
        )

        XCTAssertEqual(updated.apiKey, apiSnapshot)
        XCTAssertEqual(updated.codexOAuth, oauthSnapshot)
    }

    func testModelPickerCatalogHidesUnknownBasicModelsButKeepsCurrentPrimary() {
        let basicModel = MSPModelCapabilities(
            slug: "text-embedding-test",
            entryKind: .basic
        )
        let snapshot = MSPModelCatalogSnapshot(
            models: [
                MSPModelCapabilities(slug: "responses-model", contextWindow: 200_000),
                basicModel
            ],
            metadataSource: .provided
        )
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "manually-entered-model",
            credentialMode: MSPModelCredentialMode.apiKey.rawValue,
            reasoningEffort: "model_default",
            verbosity: "medium"
        )

        let options = MSPModelPickerCatalog.options(
            configuration: configuration,
            codexOAuthConfiguration: .empty,
            snapshots: MSPModelPickerCatalogSnapshots(apiKey: snapshot)
        )

        XCTAssertTrue(snapshot.models.contains(basicModel))
        XCTAssertTrue(options.contains { $0.modelID == "responses-model" })
        XCTAssertTrue(options.contains {
            $0.modelID == "manually-entered-model" && $0.isSelected
        })
        XCTAssertFalse(options.contains { $0.modelID == basicModel.slug })
    }

    func testModelPickerCatalogExposesDynamicGPT56ReasoningEfforts() {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "gpt-5.6-sol",
            reasoningEffort: "model_default",
            verbosity: "medium"
        )

        let efforts = MSPModelPickerCatalog
            .reasoningEffortPresets(configuration: configuration)
            .map(\.effort.rawValue)

        XCTAssertEqual(efforts, [
            "model_default", "low", "medium", "high", "xhigh", "max", "ultra"
        ])
    }

    func testModelPickerCatalogReconcilesUnsupportedEffortWhenSwitchingModels() throws {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "gpt-5.6-sol",
            reasoningEffort: "ultra",
            verbosity: "medium"
        )
        let option = try XCTUnwrap(MSPModelPickerCatalog.options(
            configuration: configuration,
            codexOAuthConfiguration: .empty
        ).first { $0.source == .apiKey && $0.modelID == "gpt-5.5" })

        let selected = MSPModelPickerCatalog.configuration(
            selecting: option,
            from: configuration
        )

        XCTAssertEqual(selected.reasoningEffort, "medium")
    }

    func testModelPickerCatalogHidesAPIKeyOptionsWhenAPIKeyIsMissing() {
        let configuration = MSPModelConfiguration(
            providerName: "Codex OAuth",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "   ",
            modelID: "gpt-5.4",
            credentialMode: MSPModelCredentialMode.codexOAuth.rawValue,
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        let options = MSPModelPickerCatalog.options(
            configuration: configuration,
            codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token")
        )

        XCTAssertFalse(options.contains { $0.source == .apiKey })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.4" && $0.isEnabled && $0.isSelected })
        XCTAssertTrue(options.contains { $0.source == .codexOAuth && $0.modelID == "gpt-5.5" && $0.isEnabled })
        XCTAssertTrue(options.allSatisfy(\.isEnabled))
    }

    func testModelPickerCatalogHidesOAuthOptionsWhenOAuthCredentialIsMissing() {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "gpt-5",
            credentialMode: MSPModelCredentialMode.apiKey.rawValue,
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        let options = MSPModelPickerCatalog.options(
            configuration: configuration,
            codexOAuthConfiguration: .empty
        )

        XCTAssertFalse(options.contains { $0.source == .codexOAuth })
        XCTAssertTrue(options.contains { $0.source == .apiKey && $0.modelID == "gpt-5" && $0.isEnabled && $0.isSelected })
        XCTAssertTrue(options.contains { $0.source == .apiKey && $0.modelID == "gpt-5.5" && $0.isEnabled })
        XCTAssertTrue(options.allSatisfy(\.isEnabled))
    }

    func testModelPickerTitleUsesOAuthWhenAPIKeyIsMissing() {
        let title = MSPModelPickerCatalog.currentSelectionTitle(
            configuration: MSPModelConfiguration(
                providerName: "OpenAI-compatible",
                baseURL: URL(string: "https://api.openai.com/v1"),
                apiKey: "   ",
                modelID: "gpt-5",
                credentialMode: MSPModelCredentialMode.apiKey.rawValue,
                reasoningEffort: "medium",
                verbosity: "medium"
            ),
            codexOAuthConfiguration: codexOAuthConfiguration(accessToken: "oauth-token")
        )

        XCTAssertEqual(
            title,
            "Codex OAuth · \(MSPModelConfigurationResolver.codexOAuthDefaultModelID)"
        )
    }

    func testModelPickerTitleShowsMissingConfigurationWhenNoCredentialIsAvailable() {
        let title = MSPModelPickerCatalog.currentSelectionTitle(
            configuration: MSPModelConfiguration(
                providerName: "OpenAI-compatible",
                baseURL: URL(string: "https://api.openai.com/v1"),
                apiKey: "   ",
                modelID: "gpt-5",
                credentialMode: MSPModelCredentialMode.apiKey.rawValue,
                reasoningEffort: "medium",
                verbosity: "medium"
            ),
            codexOAuthConfiguration: .empty
        )

        XCTAssertEqual(title, "未配置模型")
    }

    func testModelPickerCatalogPreservesAPIKeyWhenSelectingOAuth() {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://api.openai.com/v1"),
            apiKey: "saved-api-key",
            modelID: "gpt-5",
            credentialMode: MSPModelCredentialMode.apiKey.rawValue,
            reasoningEffort: "medium",
            verbosity: "medium"
        )
        let option = MSPModelPickerOption(
            source: .codexOAuth,
            modelID: "gpt-5.4",
            title: "gpt-5.4",
            subtitle: "Codex OAuth",
            isEnabled: true,
            isSelected: false
        )

        let selected = MSPModelPickerCatalog.configuration(
            selecting: option,
            from: configuration
        )

        XCTAssertEqual(selected.credentialMode, MSPModelCredentialMode.codexOAuth.rawValue)
        XCTAssertEqual(selected.providerName, "Codex OAuth")
        XCTAssertEqual(selected.baseURL?.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(selected.apiKey, "saved-api-key")
        XCTAssertEqual(selected.modelID, "gpt-5.4")
    }

    func testModelCredentialResolverMissingConfigurationMessageAllowsOAuthLogin() {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://proxy.example.test/v1"),
            apiKey: "   ",
            modelID: "gpt-test",
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        XCTAssertEqual(
            MSPModelConfigurationResolver.missingConfigurationMessage(
                configuration: configuration,
                codexOAuthConfiguration: .empty
            ),
            "请先配置模型 API key，或登录 Codex OAuth。"
        )
    }

    func testModelCredentialResolverRequiresAPIKeyOrOAuthCredential() {
        let configuration = MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: "https://proxy.example.test/v1"),
            apiKey: "   ",
            modelID: "gpt-test",
            reasoningEffort: "medium",
            verbosity: "medium"
        )

        XCTAssertNil(
            MSPModelConfigurationResolver.resolve(
                configuration: configuration,
                codexOAuthConfiguration: .empty
            )
        )
        XCTAssertEqual(
            MSPModelConfigurationResolver.missingConfigurationMessage(
                configuration: configuration,
                codexOAuthConfiguration: .empty
            ),
            "请先配置模型 API key，或登录 Codex OAuth。"
        )
    }

    private func codexOAuthConfiguration(
        accessToken: String,
        accountID: String = ""
    ) -> MSPCodexOAuthConfiguration {
        MSPCodexOAuthConfiguration(
            idToken: "",
            accessToken: accessToken,
            refreshToken: "",
            accountID: accountID,
            email: "",
            planType: "",
            lastLoginStatus: .signedIn,
            lastStatusMessage: "",
            lastCheckedAt: nil
        )
    }
}

private final class InMemoryModelSecretStore: MSPModelSecretStore {
    private var apiKey: String?

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    func loadAPIKey() -> String? {
        apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmed.isEmpty ? nil : trimmed
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }
}

private final class FailingModelSecretStore: MSPModelSecretStore {
    func loadAPIKey() -> String? {
        nil
    }

    func saveAPIKey(_ apiKey: String) throws {
        throw MSPModelSecretStoreError.keychainSaveFailed(status: -34018)
    }

    func deleteAPIKey() throws {
        throw MSPModelSecretStoreError.keychainDeleteFailed(status: -34018)
    }
}
