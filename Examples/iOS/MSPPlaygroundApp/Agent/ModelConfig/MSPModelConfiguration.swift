import Foundation

struct MSPModelConfiguration: Hashable, Sendable {
    var providerName: String
    var baseURL: URL?
    var apiKey: String
    var modelID: String
    var credentialMode: String
    var apiStyle: String
    var endpointType: String
    var endpointPathOverride: String
    var reasoningEffort: String
    var verbosity: String

    static let defaultAPIStyle = "responses"
    static let defaultEndpointType = "openai-response"

    init(
        providerName: String,
        baseURL: URL?,
        apiKey: String,
        modelID: String,
        credentialMode: String = MSPModelCredentialMode.apiKey.rawValue,
        apiStyle: String = MSPModelConfiguration.defaultAPIStyle,
        endpointType: String = MSPModelConfiguration.defaultEndpointType,
        endpointPathOverride: String = "",
        reasoningEffort: String,
        verbosity: String
    ) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.credentialMode = credentialMode
        self.apiStyle = apiStyle
        self.endpointType = endpointType
        self.endpointPathOverride = endpointPathOverride
        self.reasoningEffort = reasoningEffort
        self.verbosity = verbosity
    }

    static let placeholder = MSPModelConfiguration(
        providerName: "OpenAI-compatible",
        baseURL: URL(string: "https://api.openai.com/v1"),
        apiKey: "",
        modelID: "gpt-5",
        credentialMode: MSPModelCredentialMode.apiKey.rawValue,
        apiStyle: MSPModelConfiguration.defaultAPIStyle,
        endpointType: MSPModelConfiguration.defaultEndpointType,
        endpointPathOverride: "",
        reasoningEffort: "medium",
        verbosity: "medium"
    )

    var resolvedBaseURL: URL? {
        baseURL ?? URL(string: "https://api.openai.com/v1")
    }

    var isUsableForNetworkRequest: Bool {
        resolvedBaseURL != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalized() -> MSPModelConfiguration {
        MSPModelConfiguration(
            providerName: providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenAI-compatible"
                : providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: resolvedBaseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "gpt-5"
                : modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialMode: MSPModelCredentialMode.normalizedRawValue(credentialMode),
            apiStyle: apiStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? MSPModelConfiguration.defaultAPIStyle
                : apiStyle.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointType: endpointType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? MSPModelConfiguration.defaultEndpointType
                : endpointType.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointPathOverride: endpointPathOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoningEffort: reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "medium"
                : reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines),
            verbosity: verbosity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "medium"
                : verbosity.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum MSPModelCredentialMode: String, Hashable, Sendable {
    case apiKey
    case codexOAuth

    var displayTitle: String {
        switch self {
        case .apiKey:
            return "API key"
        case .codexOAuth:
            return "Codex OAuth"
        }
    }

    static func normalizedRawValue(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return MSPModelCredentialMode(rawValue: normalized)?.rawValue
            ?? MSPModelCredentialMode.apiKey.rawValue
    }
}

enum MSPModelConfigurationStore {
    private static let providerNameKey = "msp.playground.model.providerName"
    private static let baseURLKey = "msp.playground.model.baseURL"
    private static let apiKeyKey = "msp.playground.model.apiKey"
    private static let modelKey = "msp.playground.model.model"
    private static let credentialModeKey = "msp.playground.model.credentialMode"
    private static let apiStyleKey = "msp.playground.model.apiStyle"
    private static let endpointTypeKey = "msp.playground.model.endpointType"
    private static let endpointPathOverrideKey = "msp.playground.model.endpointPathOverride"
    private static let reasoningEffortKey = "msp.playground.model.reasoningEffort"
    private static let verbosityKey = "msp.playground.model.verbosity"

    static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secretStore: MSPModelSecretStore = MSPModelKeychainSecretStore.shared
    ) -> MSPModelConfiguration {
        let fallback = MSPModelConfiguration.placeholder
        let keychainAPIKey = secretStore.loadAPIKey()
        let legacyDefaultsAPIKey = defaults.string(forKey: apiKeyKey)
        if keychainAPIKey == nil,
           let legacyDefaultsAPIKey,
           !legacyDefaultsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try secretStore.saveAPIKey(legacyDefaultsAPIKey)
                defaults.removeObject(forKey: apiKeyKey)
            } catch {
                // Keep the legacy defaults value until a later launch can migrate it.
            }
        }
        let baseURLString = defaults.string(forKey: baseURLKey)
            ?? fallback.baseURL?.absoluteString
            ?? ""
        let stored = MSPModelConfiguration(
            providerName: defaults.string(forKey: providerNameKey) ?? fallback.providerName,
            baseURL: URL(string: baseURLString),
            apiKey: keychainAPIKey ?? legacyDefaultsAPIKey ?? fallback.apiKey,
            modelID: defaults.string(forKey: modelKey) ?? fallback.modelID,
            credentialMode: defaults.string(forKey: credentialModeKey) ?? fallback.credentialMode,
            apiStyle: defaults.string(forKey: apiStyleKey) ?? fallback.apiStyle,
            endpointType: defaults.string(forKey: endpointTypeKey) ?? fallback.endpointType,
            endpointPathOverride: defaults.string(forKey: endpointPathOverrideKey) ?? fallback.endpointPathOverride,
            reasoningEffort: defaults.string(forKey: reasoningEffortKey) ?? fallback.reasoningEffort,
            verbosity: defaults.string(forKey: verbosityKey) ?? fallback.verbosity
        ).normalized()

        return MSPModelConfiguration(
            providerName: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_PROVIDER", in: environment) ?? stored.providerName,
            baseURL: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_BASE_URL", in: environment).flatMap(URL.init(string:)) ?? stored.baseURL,
            apiKey: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_API_KEY", in: environment) ?? stored.apiKey,
            modelID: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL", in: environment) ?? stored.modelID,
            credentialMode: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_CREDENTIAL_MODE", in: environment) ?? stored.credentialMode,
            apiStyle: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_API_STYLE", in: environment) ?? stored.apiStyle,
            endpointType: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_ENDPOINT_TYPE", in: environment) ?? stored.endpointType,
            endpointPathOverride: nonEmptyEnvironmentValue("MSP_PLAYGROUND_MODEL_ENDPOINT_PATH_OVERRIDE", in: environment) ?? stored.endpointPathOverride,
            reasoningEffort: nonEmptyEnvironmentValue("MSP_PLAYGROUND_REASONING_EFFORT", in: environment) ?? stored.reasoningEffort,
            verbosity: nonEmptyEnvironmentValue("MSP_PLAYGROUND_VERBOSITY", in: environment) ?? stored.verbosity
        ).normalized()
    }

    static func save(
        _ configuration: MSPModelConfiguration,
        defaults: UserDefaults = .standard,
        secretStore: MSPModelSecretStore = MSPModelKeychainSecretStore.shared
    ) throws {
        let normalized = configuration.normalized()
        try secretStore.saveAPIKey(normalized.apiKey)
        defaults.set(normalized.providerName, forKey: providerNameKey)
        defaults.set(normalized.baseURL?.absoluteString ?? "", forKey: baseURLKey)
        defaults.removeObject(forKey: apiKeyKey)
        defaults.set(normalized.modelID, forKey: modelKey)
        defaults.set(normalized.credentialMode, forKey: credentialModeKey)
        defaults.set(normalized.apiStyle, forKey: apiStyleKey)
        defaults.set(normalized.endpointType, forKey: endpointTypeKey)
        defaults.set(normalized.endpointPathOverride, forKey: endpointPathOverrideKey)
        defaults.set(normalized.reasoningEffort, forKey: reasoningEffortKey)
        defaults.set(normalized.verbosity, forKey: verbosityKey)
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

enum MSPModelConfigurationDraftCommit {
    static func committedConfiguration(
        from draft: MSPModelConfiguration,
        originalAPIKey: String,
        clearsAPIKey: Bool
    ) -> MSPModelConfiguration {
        var configuration = draft
        let draftAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalAPIKey = originalAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if clearsAPIKey {
            configuration.apiKey = ""
        } else if draftAPIKey.isEmpty, !originalAPIKey.isEmpty {
            configuration.apiKey = originalAPIKey
        }

        return configuration.normalized()
    }
}

enum MSPModelAPIKeyStatus: Equatable {
    case missing
    case saved
    case willReplace
    case willRemove

    static func status(
        hasSavedAPIKey: Bool,
        draftAPIKey: String,
        clearsAPIKey: Bool
    ) -> MSPModelAPIKeyStatus {
        if clearsAPIKey {
            return .willRemove
        }
        if !draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .willReplace
        }
        return hasSavedAPIKey ? .saved : .missing
    }

    var text: String {
        switch self {
        case .missing:
            return "No API key saved"
        case .saved:
            return "API key saved in Keychain"
        case .willReplace:
            return "API key will be replaced"
        case .willRemove:
            return "API key will be removed"
        }
    }

    var fieldPrompt: String {
        switch self {
        case .missing:
            return "API key"
        case .saved:
            return "New API key (optional)"
        case .willReplace:
            return "New API key"
        case .willRemove:
            return "API key"
        }
    }

    var systemImageName: String {
        switch self {
        case .missing:
            return "exclamationmark.circle"
        case .saved:
            return "checkmark.circle.fill"
        case .willReplace:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .willRemove:
            return "trash.circle.fill"
        }
    }

    var isPositive: Bool {
        self == .saved
    }

    var isPendingReplacement: Bool {
        self == .willReplace
    }

    var isDestructive: Bool {
        self == .willRemove
    }
}

enum MSPModelCredentialSource: String, Equatable {
    case apiKey
    case codexOAuthAccessToken
}

struct MSPResolvedModelConfiguration: Equatable {
    var configuration: MSPModelConfiguration
    var credentialSource: MSPModelCredentialSource
    var additionalHTTPHeaders: [String: String]

    init(
        configuration: MSPModelConfiguration,
        credentialSource: MSPModelCredentialSource,
        additionalHTTPHeaders: [String: String] = [:]
    ) {
        self.configuration = configuration
        self.credentialSource = credentialSource
        self.additionalHTTPHeaders = additionalHTTPHeaders
    }
}

enum MSPModelConfigurationResolver {
    static let codexOAuthBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
    static let codexOAuthDefaultModelID = "gpt-5.5"
    static let officialOpenAIBaseURL = URL(string: "https://api.openai.com/v1")!
    private static let codexOAuthUserAgent = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"

    static func resolve(
        configuration: MSPModelConfiguration,
        codexOAuthConfiguration: MSPCodexOAuthConfiguration
    ) -> MSPResolvedModelConfiguration? {
        let normalized = configuration.normalized()
        let credentialMode = MSPModelCredentialMode(rawValue: normalized.credentialMode) ?? .apiKey
        if credentialMode == .apiKey, normalized.isUsableForNetworkRequest {
            return MSPResolvedModelConfiguration(
                configuration: normalized,
                credentialSource: .apiKey
            )
        }

        let allowsOAuthCredential = credentialMode == .codexOAuth
            || normalized.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard normalized.resolvedBaseURL != nil,
              !normalized.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              allowsOAuthCredential else {
            return nil
        }

        let codexOAuth = codexOAuthConfiguration.normalized()
        guard codexOAuth.hasAccessToken else {
            return nil
        }

        var resolved = normalized
        resolved.apiKey = codexOAuth.accessToken
        let usesDirectCodexBackend = shouldRouteOfficialOpenAIAPIToCodexOAuth(
            baseURL: normalized.resolvedBaseURL
        )
        if usesDirectCodexBackend {
            resolved.providerName = "Codex OAuth"
            resolved.baseURL = codexOAuthBaseURL
            resolved.credentialMode = MSPModelCredentialMode.codexOAuth.rawValue
            if usesDefaultOpenAIModel(resolved.modelID) {
                resolved.modelID = codexOAuthDefaultModelID
            }
        }

        return MSPResolvedModelConfiguration(
            configuration: resolved,
            credentialSource: .codexOAuthAccessToken,
            additionalHTTPHeaders: codexOAuthHTTPHeaders(
                from: codexOAuth,
                usesDirectCodexBackend: usesDirectCodexBackend
            )
        )
    }

    static func missingConfigurationMessage(
        configuration: MSPModelConfiguration,
        codexOAuthConfiguration: MSPCodexOAuthConfiguration
    ) -> String {
        let normalized = configuration.normalized()
        if normalized.resolvedBaseURL == nil {
            return "请先配置模型 base URL。"
        }
        if normalized.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先配置模型 model。"
        }
        if normalized.credentialMode == MSPModelCredentialMode.codexOAuth.rawValue,
           !codexOAuthConfiguration.normalized().hasStoredCredential {
            return "请先登录 Codex OAuth。"
        }
        if normalized.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先配置模型 API key，或登录 Codex OAuth。"
        }
        return "请先配置模型 base URL、API key 和 model。"
    }

    private static func shouldRouteOfficialOpenAIAPIToCodexOAuth(baseURL: URL?) -> Bool {
        guard let host = baseURL?.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return host == "api.openai.com"
    }

    private static func usesDefaultOpenAIModel(_ modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == MSPModelConfiguration.placeholder.modelID.lowercased()
    }

    private static func codexOAuthHTTPHeaders(
        from codexOAuth: MSPCodexOAuthConfiguration,
        usesDirectCodexBackend: Bool
    ) -> [String: String] {
        guard usesDirectCodexBackend else {
            return [:]
        }
        var headers = [
            "User-Agent": codexOAuthUserAgent,
            "originator": "codex_cli_rs"
        ]
        let accountID = codexOAuth.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accountID.isEmpty {
            headers["Chatgpt-Account-Id"] = accountID
        }
        return headers
    }
}

enum MSPModelPickerSource: String, Hashable, Sendable {
    case apiKey
    case codexOAuth

    var credentialMode: MSPModelCredentialMode {
        switch self {
        case .apiKey:
            return .apiKey
        case .codexOAuth:
            return .codexOAuth
        }
    }

    var title: String {
        credentialMode.displayTitle
    }

    var systemImageName: String {
        switch self {
        case .apiKey:
            return "key"
        case .codexOAuth:
            return "person.crop.circle.badge.checkmark"
        }
    }
}

struct MSPModelPickerOption: Identifiable, Hashable, Sendable {
    var id: String { "\(source.rawValue):\(modelID)" }
    var source: MSPModelPickerSource
    var modelID: String
    var title: String
    var subtitle: String
    var isEnabled: Bool
    var isSelected: Bool
}

enum MSPModelPickerCatalog {
    private static let apiKeyModels = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.2",
        "gpt-5"
    ]
    private static let codexOAuthModels = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2"
    ]

    static func options(
        configuration: MSPModelConfiguration,
        codexOAuthConfiguration: MSPCodexOAuthConfiguration
    ) -> [MSPModelPickerOption] {
        let normalized = configuration.normalized()
        let credentialMode = MSPModelCredentialMode(rawValue: normalized.credentialMode) ?? .apiKey
        let hasAPIKey = !normalized.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCodexOAuth = codexOAuthConfiguration.normalized().hasStoredCredential

        let apiModels = mergedModelIDs(
            primary: credentialMode == .apiKey ? normalized.modelID : nil,
            defaults: apiKeyModels
        )
        let oauthModels = mergedModelIDs(
            primary: credentialMode == .codexOAuth ? normalized.modelID : nil,
            defaults: codexOAuthModels
        )

        let apiOptions = hasAPIKey
            ? apiModels.map { modelID in
                option(
                    source: .apiKey,
                    modelID: modelID,
                    isSelected: credentialMode == .apiKey && normalized.modelID == modelID
                )
            }
            : []
        let oauthOptions = hasCodexOAuth
            ? oauthModels.map { modelID in
                option(
                    source: .codexOAuth,
                    modelID: modelID,
                    isSelected: credentialMode == .codexOAuth && normalized.modelID == modelID
                )
            }
            : []

        return apiOptions + oauthOptions
    }

    static func configuration(
        selecting option: MSPModelPickerOption,
        from configuration: MSPModelConfiguration
    ) -> MSPModelConfiguration {
        var next = configuration.normalized()
        next.credentialMode = option.source.credentialMode.rawValue
        next.modelID = option.modelID
        switch option.source {
        case .apiKey:
            if next.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || next.providerName == MSPModelPickerSource.codexOAuth.title {
                next.providerName = "OpenAI-compatible"
            }
            if next.baseURL == nil {
                next.baseURL = MSPModelConfigurationResolver.officialOpenAIBaseURL
            }
        case .codexOAuth:
            next.providerName = MSPModelPickerSource.codexOAuth.title
            next.baseURL = MSPModelConfigurationResolver.officialOpenAIBaseURL
        }
        return next.normalized()
    }

    static func currentSelectionTitle(
        configuration: MSPModelConfiguration,
        codexOAuthConfiguration: MSPCodexOAuthConfiguration
    ) -> String {
        let availableOptions = options(
            configuration: configuration,
            codexOAuthConfiguration: codexOAuthConfiguration
        )
        let selectedOption = availableOptions.first(where: \.isSelected)
            ?? availableOptions.first
        guard let selectedOption else {
            return "未配置模型"
        }
        return "\(selectedOption.source.title) · \(selectedOption.modelID)"
    }

    private static func option(
        source: MSPModelPickerSource,
        modelID: String,
        isSelected: Bool
    ) -> MSPModelPickerOption {
        MSPModelPickerOption(
            source: source,
            modelID: modelID,
            title: modelID,
            subtitle: source.title,
            isEnabled: true,
            isSelected: isSelected
        )
    }

    private static func mergedModelIDs(primary: String?, defaults: [String]) -> [String] {
        var result: [String] = []
        func append(_ candidate: String?) {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  !result.contains(trimmed) else {
                return
            }
            result.append(trimmed)
        }
        append(primary)
        defaults.forEach { append($0) }
        return result
    }
}
