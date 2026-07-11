import Foundation
import MSPAgentBridge
import MSPChat

/// A host-facing, Chat-ID-bound value for opting a persisted `.chat` session
/// into automatic naming when it creates an ``MSPAgentConversation``.
public struct MSPAgentChatNamingIntegration: Sendable {
    public let chatID: String
    fileprivate let coordinator: MSPChatNamingCoordinator
    fileprivate let schedulesInitialChatNamingOnFirstSend: Bool
    private let currentContextProvider:
        @Sendable () throws -> MSPChatNamingInput?

    init(
        chatID: String,
        coordinator: MSPChatNamingCoordinator,
        schedulesInitialChatNamingOnFirstSend: Bool,
        currentContextProvider:
            @escaping @Sendable () throws -> MSPChatNamingInput?
    ) {
        self.chatID = chatID
        self.coordinator = coordinator
        self.schedulesInitialChatNamingOnFirstSend =
            schedulesInitialChatNamingOnFirstSend
        self.currentContextProvider = currentContextProvider
    }

    /// Runs an explicit naming request without requiring the caller to repeat
    /// or manually pair the persisted Chat ID.
    @discardableResult
    public func generateTitleIfNeeded(
        input: MSPChatNamingInput,
        source: MSPChatNamingRequestSource = .developerRequested
    ) async throws -> MSPChatNamingOutcome {
        try await coordinator.generateTitleIfNeeded(MSPChatNamingRequest(
            chatID: chatID,
            input: input,
            source: source
        ))
    }

    @discardableResult
    public func backfillTitleIfNeeded(
        preview: MSPChatNamingInput
    ) async throws -> MSPChatNamingOutcome {
        try await coordinator.backfillTitleIfNeeded(
            chatID: chatID,
            preview: preview
        )
    }

    /// Preferred UI manual-rename path. It cancels pending metadata work,
    /// preserves/replaces the description atomically, and emits naming events.
    @discardableResult
    public func setManualTitle(
        _ title: String,
        searchDescription: MSPChatSearchDescriptionUpdate = .preserve
    ) async throws -> MSPChatTitleMetadata {
        try await coordinator.setManualTitle(
            chatID: chatID,
            title: title,
            searchDescription: searchDescription
        )
    }

    /// Renames and then refreshes the search description from the Chat's
    /// current persisted user context, prioritizing the most recent purpose.
    @discardableResult
    public func setManualTitleAndRefreshSearchDescription(
        _ title: String
    ) async throws -> MSPChatTitleMetadata {
        let input = (try? currentContextProvider())
            ?? MSPChatNamingInput(parts: [])
        return try await setManualTitleAndRefreshSearchDescription(
            title,
            input: input
        )
    }

    /// Host-supplied context variant for providers that maintain their own
    /// canonical Chat history.
    @discardableResult
    public func setManualTitleAndRefreshSearchDescription(
        _ title: String,
        input: MSPChatNamingInput
    ) async throws -> MSPChatTitleMetadata {
        try await coordinator.setManualTitleAndRefreshSearchDescription(
            chatID: chatID,
            title: title,
            input: input
        )
    }

    @discardableResult
    public func refreshSearchDescription(
        source: MSPChatSearchDescriptionRequestSource = .manualTitleChange
    ) async throws -> MSPChatSearchDescriptionRefreshOutcome {
        let input = (try? currentContextProvider())
            ?? MSPChatNamingInput(parts: [])
        return try await refreshSearchDescription(
            input: input,
            source: source
        )
    }

    @discardableResult
    public func refreshSearchDescription(
        input: MSPChatNamingInput,
        source: MSPChatSearchDescriptionRequestSource = .manualTitleChange
    ) async throws -> MSPChatSearchDescriptionRefreshOutcome {
        try await coordinator.refreshSearchDescription(
            chatID: chatID,
            input: input,
            source: source
        )
    }

    public func cancelPendingNaming() async {
        await coordinator.cancelPendingNaming(for: chatID)
    }

    /// One-call title inheritance for a derived Chat. The child persistence
    /// adapter remains authoritative and commits with `.onlyIfUntitled`.
    @discardableResult
    public func inheritTitle(
        from parentSession: MSPAgentChatSession
    ) async throws -> MSPChatNamingOutcome {
        try await inheritTitle(from: parentSession.titleMetadata())
    }

    @discardableResult
    public func inheritTitle(
        from parentMetadata: MSPChatTitleMetadata
    ) async throws -> MSPChatNamingOutcome {
        try await coordinator.inheritTitle(from: parentMetadata, to: chatID)
    }

    @discardableResult
    public func inheritTitle(
        from parentRecord: MSPChatTitleRecord
    ) async throws -> MSPChatNamingOutcome {
        try await coordinator.inheritTitle(from: parentRecord, to: chatID)
    }

    fileprivate func replacingInitialSendScheduling(
        with enabled: Bool
    ) -> MSPAgentChatNamingIntegration {
        MSPAgentChatNamingIntegration(
            chatID: chatID,
            coordinator: coordinator,
            schedulesInitialChatNamingOnFirstSend: enabled,
            currentContextProvider: currentContextProvider
        )
    }
}

extension MSPAgentChatSession {
    /// Creates the MSP naming engine with a developer-selected
    /// Responses model. Passing the main model configuration is the zero-
    /// configuration path; passing a cheaper configuration keeps naming cost
    /// independent from the main Chat model. A non-empty
    /// `namingConfiguration.model` overrides `modelConfiguration.model`.
    public func makeChatNamingIntegration(
        modelConfiguration: MSPAgentModelConfiguration,
        namingConfiguration: MSPChatNamingConfiguration = .codexCompatible(),
        automaticallyBackfillsHistoricalTitle: Bool = true,
        onEvent: @escaping MSPChatNamingEventHandler = { _ in }
    ) throws -> MSPAgentChatNamingIntegration {
        let generator = MSPResponsesChatTitleGenerator(
            modelConfiguration: modelConfiguration,
            namingConfiguration: namingConfiguration
        )
        return try makeChatNamingIntegration(
            titleGenerator: generator,
            searchDescriptionGenerator: generator,
            namingConfiguration: namingConfiguration,
            automaticallyBackfillsHistoricalTitle:
                automaticallyBackfillsHistoricalTitle,
            onEvent: onEvent
        )
    }

    /// Advanced integration point for local models, non-Responses providers,
    /// or an application-owned metadata service.
    public func makeChatNamingIntegration(
        titleGenerator: any MSPChatTitleGenerating,
        searchDescriptionGenerator:
            (any MSPChatSearchDescriptionGenerating)? = nil,
        namingConfiguration: MSPChatNamingConfiguration = .codexCompatible(),
        automaticallyBackfillsHistoricalTitle: Bool = true,
        onEvent: @escaping MSPChatNamingEventHandler = { _ in }
    ) throws -> MSPAgentChatNamingIntegration {
        let manifest = try MSPChatCoreReader().readManifest(at: packageURL)
        guard let chatID = manifest.packageID else {
            throw MSPAgentChatStoreError.missingPackageID
        }
        let metadata = try titleMetadata()
        let historicalPreview: MSPChatNamingInput?
        if automaticallyBackfillsHistoricalTitle,
           namingConfiguration.policy.backfillHistoricalUntitledChats,
           metadata.isUntitled {
            historicalPreview = try historicalChatNamingInput()
        } else {
            historicalPreview = nil
        }
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: titleGenerator,
            searchDescriptionGenerator: searchDescriptionGenerator,
            persistence: self,
            configuration: namingConfiguration,
            onEvent: onEvent
        )
        let integration = MSPAgentChatNamingIntegration(
            chatID: chatID,
            coordinator: coordinator,
            schedulesInitialChatNamingOnFirstSend:
                metadata.isUntitled
                && historicalPreview == nil
                && namingConfiguration.policy.generateFromInitialUserInput,
            currentContextProvider: { [session = self] in
                try session.currentChatNamingInput()
            }
        )
        if let historicalPreview {
            scheduleHistoricalBackfill(
                integration: integration,
                preview: historicalPreview
            )
        }
        return integration
    }

    /// Creates the same integration for a derived Chat and completes title
    /// inheritance before returning. If the parent is untitled, the child can
    /// still use the normal historical-preview backfill path.
    public func makeDerivedChatNamingIntegration(
        inheritingTitleFrom parentSession: MSPAgentChatSession,
        modelConfiguration: MSPAgentModelConfiguration,
        namingConfiguration: MSPChatNamingConfiguration = .codexCompatible(),
        onEvent: @escaping MSPChatNamingEventHandler = { _ in }
    ) async throws -> MSPAgentChatNamingIntegration {
        let generator = MSPResponsesChatTitleGenerator(
            modelConfiguration: modelConfiguration,
            namingConfiguration: namingConfiguration
        )
        return try await makeDerivedChatNamingIntegration(
            inheritingTitleFrom: parentSession,
            titleGenerator: generator,
            searchDescriptionGenerator: generator,
            namingConfiguration: namingConfiguration,
            onEvent: onEvent
        )
    }

    /// Custom-provider variant of derived-Chat title inheritance.
    public func makeDerivedChatNamingIntegration(
        inheritingTitleFrom parentSession: MSPAgentChatSession,
        titleGenerator: any MSPChatTitleGenerating,
        searchDescriptionGenerator:
            (any MSPChatSearchDescriptionGenerating)? = nil,
        namingConfiguration: MSPChatNamingConfiguration = .codexCompatible(),
        onEvent: @escaping MSPChatNamingEventHandler = { _ in }
    ) async throws -> MSPAgentChatNamingIntegration {
        let integration = try makeChatNamingIntegration(
            titleGenerator: titleGenerator,
            searchDescriptionGenerator: searchDescriptionGenerator,
            namingConfiguration: namingConfiguration,
            automaticallyBackfillsHistoricalTitle: false,
            onEvent: onEvent
        )
        let inheritance = try await integration.inheritTitle(
            from: parentSession
        )
        guard inheritance.metadata.isUntitled else {
            return integration.replacingInitialSendScheduling(with: false)
        }
        if namingConfiguration.policy.backfillHistoricalUntitledChats,
           let preview = try historicalChatNamingInput() {
            let backfilling = integration.replacingInitialSendScheduling(
                with: false
            )
            scheduleHistoricalBackfill(
                integration: backfilling,
                preview: preview
            )
            return backfilling
        }
        return integration
    }

    private func scheduleHistoricalBackfill(
        integration: MSPAgentChatNamingIntegration,
        preview: MSPChatNamingInput
    ) {
        Task {
            do {
                _ = try await integration.backfillTitleIfNeeded(
                    preview: preview
                )
            } catch is CancellationError {
                // Manual naming or host cancellation intentionally wins.
            } catch {
                // The coordinator already projects failures through its
                // independent ChatNaming event channel.
            }
        }
    }

    private func historicalChatNamingInput() throws -> MSPChatNamingInput? {
        var result: MSPChatNamingInput?
        do {
            _ = try MSPChatCoreReader().forEachTimelineEvent(at: packageURL) { event in
                if let input = try Self.firstHistoricalPreview(in: event) {
                    result = input
                    throw MSPChatNamingTimelineScanStop.found
                }
            }
        } catch MSPChatNamingTimelineScanStop.found {
            // The first persisted preview candidate was found; stop scanning
            // rather than materializing the rest of a potentially large Chat.
        }
        if let result {
            return result
        }
        return Self.firstUserInput(in: try modelVisibleHistory())
    }

    private static func firstHistoricalPreview(
        in event: MSPChatTimelineEvent
    ) throws -> MSPChatNamingInput? {
        if let userInput = try firstUserInput(in: event) {
            return userInput
        }
        guard event.type == MSPGoalChatMapping.threadGoalUpdatedTimelineType,
              let rawObjective = event.payload["objective"]?.stringValue else {
            return nil
        }
        let objective = rawObjective.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !objective.isEmpty else {
            return nil
        }
        return MSPChatNamingInput(text: objective)
    }

    private func currentChatNamingInput() throws -> MSPChatNamingInput? {
        let recentUserMessages = try modelVisibleHistory().compactMap { item -> String? in
            guard let object = item.objectValue,
                  object["role"]?.stringValue == "user" else {
                return nil
            }
            let texts = Self.userTextParts(from: object["content"])
            guard !texts.isEmpty else {
                return nil
            }
            return MSPChatNamingPrompt.preparedPrompt(
                from: MSPChatNamingInput(parts: texts.map {
                    .text($0)
                }),
                maximumCharacters: Int.max
            )
        }
        let nonempty = recentUserMessages.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonempty.isEmpty else {
            return nil
        }
        return MSPChatNamingInput(parts: nonempty.reversed().map {
            .text($0)
        })
    }

    private static func firstUserInput(
        in items: [MSPAgentJSONValue]
    ) -> MSPChatNamingInput? {
        for item in items {
            guard let object = item.objectValue,
                  object["role"]?.stringValue == "user" else {
                continue
            }
            let texts = userTextParts(from: object["content"])
            if !texts.isEmpty {
                return MSPChatNamingInput(parts: texts.map {
                    .text($0)
                })
            }
        }
        return nil
    }

    private static func firstUserInput(
        in event: MSPChatTimelineEvent
    ) throws -> MSPChatNamingInput? {
        if event.type == modelContextItemEventType,
           let item = event.payload["item"] {
            return firstUserInput(in: [try item.agentJSONValue()])
        }
        if event.type == modelContextSnapshotEventType,
           let items = event.payload["items"]?.arrayValue {
            for item in items {
                if let input = firstUserInput(in: [try item.agentJSONValue()]) {
                    return input
                }
            }
            return nil
        }
        if event.type == "message" {
            return firstUserInput(in: [.object(
                try event.payload.mapValues { try $0.agentJSONValue() }
            )])
        }
        return nil
    }

    private static func userTextParts(
        from content: MSPAgentJSONValue?
    ) -> [String] {
        if let text = content?.stringValue,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [text]
        }
        guard let parts = content?.arrayValue else {
            return []
        }
        return parts.compactMap { part in
            guard let object = part.objectValue,
                  let text = object["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let type = object["type"]?.stringValue
            guard type == nil || type == "input_text" || type == "text" else {
                return nil
            }
            return text
        }
    }
}

private enum MSPChatNamingTimelineScanStop: Error {
    case found
}

extension MSPAgentRuntime {
    /// Keeps the persisted Chat identity and its naming coordinator together,
    /// preventing hosts from accidentally wiring a coordinator to another Chat.
    public func makeConversation(
        configuration: MSPAgentConversationConfiguration,
        chatNaming: MSPAgentChatNamingIntegration
    ) -> MSPAgentConversation {
        makeConversation(
            configuration: configuration,
            chatID: chatNaming.chatID,
            chatNamingCoordinator: chatNaming.coordinator,
            schedulesInitialChatNamingOnFirstSend:
                chatNaming.schedulesInitialChatNamingOnFirstSend
        )
    }
}
