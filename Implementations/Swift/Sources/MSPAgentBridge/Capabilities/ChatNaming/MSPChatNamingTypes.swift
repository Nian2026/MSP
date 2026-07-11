import Foundation

public protocol MSPChatTitleGenerating: Sendable {
    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion
}

public protocol MSPChatSearchDescriptionGenerating: Sendable {
    func generateSearchDescription(
        request: MSPChatSearchDescriptionGenerationRequest
    ) async throws -> String?
}

public struct MSPChatNamingInput: Hashable, Sendable {
    public var parts: [MSPChatNamingInputPart]

    public init(parts: [MSPChatNamingInputPart]) {
        self.parts = parts
    }

    public init(
        text: String,
        pastedTextExcerpts: [String] = []
    ) {
        self.parts = [.text(text)] + pastedTextExcerpts.map {
            .pastedTextExcerpt($0)
        }
    }
}

public enum MSPChatNamingInputPart: Hashable, Sendable {
    case text(String)
    case pastedTextExcerpt(String)

    public var text: String {
        switch self {
        case .text(let text), .pastedTextExcerpt(let text):
            return text
        }
    }
}

public enum MSPChatNamingRequestSource: String, Codable, Hashable, Sendable {
    case initialUserInput = "initial_user_input"
    case historicalBackfill = "historical_backfill"
    case developerRequested = "developer_requested"
    case forkInheritance = "fork_inheritance"
}

public enum MSPChatSearchDescriptionRequestSource: String, Codable, Hashable, Sendable {
    case manualTitleChange = "manual_title_change"
    case developerRequested = "developer_requested"
}

/// Makes manual-title description intent explicit: callers can preserve the
/// current value, replace it, or clear it with `.replace(nil)`.
public enum MSPChatSearchDescriptionUpdate: Hashable, Sendable {
    case preserve
    case replace(String?)
}

public struct MSPChatNamingRequest: Hashable, Sendable {
    public var chatID: String
    public var input: MSPChatNamingInput
    public var source: MSPChatNamingRequestSource

    public init(
        chatID: String,
        input: MSPChatNamingInput,
        source: MSPChatNamingRequestSource = .initialUserInput
    ) {
        self.chatID = chatID
        self.input = input
        self.source = source
    }

    public init(
        chatID: String,
        text: String,
        pastedTextExcerpts: [String] = [],
        source: MSPChatNamingRequestSource = .initialUserInput
    ) {
        self.init(
            chatID: chatID,
            input: MSPChatNamingInput(
                text: text,
                pastedTextExcerpts: pastedTextExcerpts
            ),
            source: source
        )
    }
}

public struct MSPChatTitleGenerationRequest: Hashable, Sendable {
    public var chatID: String
    public var prompt: String
    public var instructions: String
    public var model: String?
    public var titleMaximumCharacters: Int
    public var descriptionMaximumCharacters: Int
    public var source: MSPChatNamingRequestSource

    public init(
        chatID: String,
        prompt: String,
        instructions: String,
        model: String?,
        titleMaximumCharacters: Int,
        descriptionMaximumCharacters: Int,
        source: MSPChatNamingRequestSource
    ) {
        self.chatID = chatID
        self.prompt = prompt
        self.instructions = instructions
        self.model = model
        self.titleMaximumCharacters = titleMaximumCharacters
        self.descriptionMaximumCharacters = descriptionMaximumCharacters
        self.source = source
    }
}

public struct MSPChatSearchDescriptionGenerationRequest: Hashable, Sendable {
    public var chatID: String
    public var title: String
    public var prompt: String
    public var instructions: String
    public var model: String?
    public var descriptionMaximumCharacters: Int
    public var source: MSPChatSearchDescriptionRequestSource

    public init(
        chatID: String,
        title: String,
        prompt: String,
        instructions: String,
        model: String?,
        descriptionMaximumCharacters: Int,
        source: MSPChatSearchDescriptionRequestSource
    ) {
        self.chatID = chatID
        self.title = title
        self.prompt = prompt
        self.instructions = instructions
        self.model = model
        self.descriptionMaximumCharacters = descriptionMaximumCharacters
        self.source = source
    }
}

public struct MSPChatTitleSuggestion: Codable, Hashable, Sendable {
    public var title: String
    public var searchDescription: String?

    public init(title: String, searchDescription: String? = nil) {
        self.title = title
        self.searchDescription = searchDescription
    }
}

public struct MSPChatNamingLimits: Hashable, Sendable {
    public static let codexCompatibleTitleMaximumCharacters = 36
    public static let codexCompatibleDescriptionMaximumCharacters = 100
    public static let codexCompatibleInputMaximumCharacters = 2_000
    public static let codexCompatibleFallbackMaximumCharacters = 60

    public var titleMaximumCharacters: Int
    public var descriptionMaximumCharacters: Int
    public var inputMaximumCharacters: Int
    public var fallbackMaximumCharacters: Int

    public init(
        titleMaximumCharacters: Int = Self.codexCompatibleTitleMaximumCharacters,
        descriptionMaximumCharacters: Int = Self.codexCompatibleDescriptionMaximumCharacters,
        inputMaximumCharacters: Int = Self.codexCompatibleInputMaximumCharacters,
        fallbackMaximumCharacters: Int = Self.codexCompatibleFallbackMaximumCharacters
    ) {
        self.titleMaximumCharacters = max(1, titleMaximumCharacters)
        self.descriptionMaximumCharacters = max(1, descriptionMaximumCharacters)
        self.inputMaximumCharacters = max(1, inputMaximumCharacters)
        self.fallbackMaximumCharacters = max(1, fallbackMaximumCharacters)
    }

    public static let codexCompatible = MSPChatNamingLimits()
}

public struct MSPChatNamingPolicy: Hashable, Sendable {
    public var generateFromInitialUserInput: Bool
    public var backfillHistoricalUntitledChats: Bool
    public var allowDeveloperRequestedGeneration: Bool
    public var inheritForkTitles: Bool
    public var useInputFallbackOnGenerationFailure: Bool

    public init(
        generateFromInitialUserInput: Bool,
        backfillHistoricalUntitledChats: Bool,
        allowDeveloperRequestedGeneration: Bool,
        inheritForkTitles: Bool,
        useInputFallbackOnGenerationFailure: Bool
    ) {
        self.generateFromInitialUserInput = generateFromInitialUserInput
        self.backfillHistoricalUntitledChats = backfillHistoricalUntitledChats
        self.allowDeveloperRequestedGeneration = allowDeveloperRequestedGeneration
        self.inheritForkTitles = inheritForkTitles
        self.useInputFallbackOnGenerationFailure = useInputFallbackOnGenerationFailure
    }

    public static let codexCompatible = MSPChatNamingPolicy(
        generateFromInitialUserInput: true,
        backfillHistoricalUntitledChats: true,
        allowDeveloperRequestedGeneration: true,
        inheritForkTitles: true,
        useInputFallbackOnGenerationFailure: true
    )

    public static let disabled = MSPChatNamingPolicy(
        generateFromInitialUserInput: false,
        backfillHistoricalUntitledChats: false,
        allowDeveloperRequestedGeneration: false,
        inheritForkTitles: false,
        useInputFallbackOnGenerationFailure: false
    )

    public func permits(_ source: MSPChatNamingRequestSource) -> Bool {
        switch source {
        case .initialUserInput:
            return generateFromInitialUserInput
        case .historicalBackfill:
            return backfillHistoricalUntitledChats
        case .developerRequested:
            return allowDeveloperRequestedGeneration
        case .forkInheritance:
            return inheritForkTitles
        }
    }
}

public struct MSPChatNamingConfiguration: Hashable, Sendable {
    public static let codexCompatibleTimeoutNanoseconds: UInt64 = 30_000_000_000

    /// Optional public lower-cost model reference for hosts that do not want
    /// title generation to reuse their main model. Model selection remains
    /// developer-owned and provider availability must be checked by the host.
    public static let codexReferenceModel = "gpt-5.4-mini"

    public var model: String?
    public var limits: MSPChatNamingLimits
    public var timeoutNanoseconds: UInt64
    public var policy: MSPChatNamingPolicy

    public init(
        model: String? = nil,
        limits: MSPChatNamingLimits = .codexCompatible,
        timeoutNanoseconds: UInt64 = Self.codexCompatibleTimeoutNanoseconds,
        policy: MSPChatNamingPolicy = .codexCompatible
    ) {
        self.model = model
        self.limits = limits
        self.timeoutNanoseconds = timeoutNanoseconds
        self.policy = policy
    }

    public static func codexCompatible(
        model: String? = nil
    ) -> MSPChatNamingConfiguration {
        MSPChatNamingConfiguration(model: model)
    }

    public static let disabled = MSPChatNamingConfiguration(policy: .disabled)
}

public enum MSPChatNamingSkipReason: String, Codable, Hashable, Sendable {
    case policyDisabled = "policy_disabled"
    case alreadyTitled = "already_titled"
    case emptyInput = "empty_input"
    case titleChangedDuringGeneration = "title_changed_during_generation"
    case writeConditionNotMet = "write_condition_not_met"
    case parentUntitled = "parent_untitled"
}

public enum MSPChatNamingOutcome: Hashable, Sendable {
    case updated(MSPChatTitleMetadata)
    case skipped(reason: MSPChatNamingSkipReason, metadata: MSPChatTitleMetadata)

    public var metadata: MSPChatTitleMetadata {
        switch self {
        case .updated(let metadata), .skipped(_, let metadata):
            return metadata
        }
    }
}

public enum MSPChatSearchDescriptionSkipReason: String, Codable, Hashable, Sendable {
    case generatorUnavailable = "generator_unavailable"
    case chatUntitled = "chat_untitled"
    case emptyGeneratedDescription = "empty_generated_description"
    case titleChangedDuringGeneration = "title_changed_during_generation"
    case revisionUnavailable = "revision_unavailable"
    case writeConditionNotMet = "write_condition_not_met"
}

public enum MSPChatSearchDescriptionRefreshOutcome: Hashable, Sendable {
    case updated(MSPChatTitleMetadata)
    case skipped(
        reason: MSPChatSearchDescriptionSkipReason,
        metadata: MSPChatTitleMetadata
    )

    public var metadata: MSPChatTitleMetadata {
        switch self {
        case .updated(let metadata), .skipped(_, let metadata):
            return metadata
        }
    }
}
