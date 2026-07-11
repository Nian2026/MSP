import Foundation

/// Chat-naming events are SDK control-plane notifications for host UI and
/// indexing. They are intentionally separate from `MSPAgentEvent`, so title
/// generation never becomes a model-visible or canonical timeline item.
public enum MSPChatNamingEvent: Hashable, Sendable {
    case titleGenerationStarted(MSPChatTitleGenerationStartedEvent)
    case titleUpdated(MSPChatTitleUpdatedEvent)
    case titleGenerationSkipped(MSPChatTitleGenerationSkippedEvent)
    case titleGenerationFailed(MSPChatTitleGenerationFailedEvent)
    case searchDescriptionGenerationStarted(
        MSPChatSearchDescriptionGenerationStartedEvent
    )
    case searchDescriptionUpdated(MSPChatSearchDescriptionUpdatedEvent)
    case searchDescriptionGenerationSkipped(
        MSPChatSearchDescriptionGenerationSkippedEvent
    )
    case searchDescriptionGenerationFailed(
        MSPChatSearchDescriptionGenerationFailedEvent
    )
}

public typealias MSPChatNamingEventHandler =
    @Sendable (MSPChatNamingEvent) async -> Void

public struct MSPChatTitleGenerationStartedEvent: Hashable, Sendable {
    public var chatID: String
    public var source: MSPChatNamingRequestSource
    public var startedAt: Date

    public init(
        chatID: String,
        source: MSPChatNamingRequestSource,
        startedAt: Date
    ) {
        self.chatID = chatID
        self.source = source
        self.startedAt = startedAt
    }
}

public struct MSPChatTitleUpdatedEvent: Hashable, Sendable {
    public var eventID: String
    public var record: MSPChatTitleRecord
    public var requestSource: MSPChatNamingRequestSource?

    public init(
        eventID: String,
        record: MSPChatTitleRecord,
        requestSource: MSPChatNamingRequestSource?
    ) {
        self.eventID = eventID
        self.record = record
        self.requestSource = requestSource
    }
}

public struct MSPChatTitleGenerationSkippedEvent: Hashable, Sendable {
    public var chatID: String
    public var source: MSPChatNamingRequestSource
    public var reason: MSPChatNamingSkipReason
    public var skippedAt: Date

    public init(
        chatID: String,
        source: MSPChatNamingRequestSource,
        reason: MSPChatNamingSkipReason,
        skippedAt: Date
    ) {
        self.chatID = chatID
        self.source = source
        self.reason = reason
        self.skippedAt = skippedAt
    }
}

public struct MSPChatTitleGenerationFailedEvent: Hashable, Sendable {
    public var chatID: String
    public var source: MSPChatNamingRequestSource
    public var message: String
    public var willUseFallback: Bool
    public var failedAt: Date

    public init(
        chatID: String,
        source: MSPChatNamingRequestSource,
        message: String,
        willUseFallback: Bool,
        failedAt: Date
    ) {
        self.chatID = chatID
        self.source = source
        self.message = message
        self.willUseFallback = willUseFallback
        self.failedAt = failedAt
    }
}

public struct MSPChatSearchDescriptionGenerationStartedEvent: Hashable, Sendable {
    public var chatID: String
    public var title: String
    public var source: MSPChatSearchDescriptionRequestSource
    public var startedAt: Date

    public init(
        chatID: String,
        title: String,
        source: MSPChatSearchDescriptionRequestSource,
        startedAt: Date
    ) {
        self.chatID = chatID
        self.title = title
        self.source = source
        self.startedAt = startedAt
    }
}

public struct MSPChatSearchDescriptionUpdatedEvent: Hashable, Sendable {
    public var eventID: String
    public var record: MSPChatTitleRecord
    public var source: MSPChatSearchDescriptionRequestSource

    public init(
        eventID: String,
        record: MSPChatTitleRecord,
        source: MSPChatSearchDescriptionRequestSource
    ) {
        self.eventID = eventID
        self.record = record
        self.source = source
    }
}

public struct MSPChatSearchDescriptionGenerationSkippedEvent: Hashable, Sendable {
    public var chatID: String
    public var source: MSPChatSearchDescriptionRequestSource
    public var reason: MSPChatSearchDescriptionSkipReason
    public var skippedAt: Date

    public init(
        chatID: String,
        source: MSPChatSearchDescriptionRequestSource,
        reason: MSPChatSearchDescriptionSkipReason,
        skippedAt: Date
    ) {
        self.chatID = chatID
        self.source = source
        self.reason = reason
        self.skippedAt = skippedAt
    }
}

public struct MSPChatSearchDescriptionGenerationFailedEvent: Hashable, Sendable {
    public var chatID: String
    public var title: String
    public var source: MSPChatSearchDescriptionRequestSource
    public var message: String
    public var failedAt: Date

    public init(
        chatID: String,
        title: String,
        source: MSPChatSearchDescriptionRequestSource,
        message: String,
        failedAt: Date
    ) {
        self.chatID = chatID
        self.title = title
        self.source = source
        self.message = message
        self.failedAt = failedAt
    }
}
