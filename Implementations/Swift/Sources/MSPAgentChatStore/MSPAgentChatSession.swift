import Foundation
import MSPAgentBridge
import MSPChat

public struct MSPAgentChatSession: Sendable {
    public static let modelContextItemEventType = "agent_model_context_item"
    public static let modelContextSnapshotEventType = "agent_model_context_snapshot"
    public static let applicationStateSnapshotEventType = "application_state_snapshot"

    public let packageURL: URL
    public let clock: @Sendable () -> Date
    private let writeQueue: MSPAgentChatSessionWriteQueue

    public init(
        packageURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.packageURL = packageURL.standardizedFileURL
        self.clock = clock
        self.writeQueue = MSPAgentChatSessionWriteQueue()
    }

    public func packageSnapshot() throws -> MSPChatPackage {
        try MSPChatCoreReader().readPackage(at: packageURL)
    }

    private struct AppendContext {
        var appendState: MSPChatAppendState
        var latestState: MSPAgentChatLatestStateIndex
        var validationPolicy: MSPChatCoreWriter.AppendStateValidationPolicy
    }

    private func appendContextForCurrentPackage() throws -> AppendContext {
        let manifest = try MSPChatCoreReader().readManifest(at: packageURL)
        if let latestState = try MSPAgentChatStore.latestStateIndex(at: packageURL, matching: manifest) {
            return AppendContext(
                appendState: MSPChatAppendState(
                    packageURL: packageURL,
                    manifest: manifest,
                    nextSeq: latestState.timelineNextSeq
                ),
                latestState: latestState,
                validationPolicy: .trustManifestNextSeq
            )
        }

        let latestState = try MSPAgentChatStore.latestStateIndex(at: packageURL, manifest: manifest)
        return AppendContext(
            appendState: MSPChatAppendState(
                packageURL: packageURL,
                manifest: manifest,
                nextSeq: latestState.timelineNextSeq
            ),
            latestState: latestState,
            validationPolicy: .trustProvidedState
        )
    }

    private func appendGeneratedEvents<T>(
        createdAt: String?,
        _ build: (Int, String) throws -> (events: [MSPChatTimelineEvent], result: T)
    ) throws -> T {
        try MSPChatCoreWriter.withPackageWriteLock(at: packageURL) {
            let context = try appendContextForCurrentPackage()
            var appendState = context.appendState
            var latestState = context.latestState
            let timestamp = createdAt ?? currentTimestamp()
            let built = try build(appendState.nextSeq, timestamp)
            if !built.events.isEmpty {
                try MSPChatCoreWriter().appendEvents(
                    built.events,
                    to: packageURL,
                    state: &appendState,
                    updatedAt: timestamp,
                    validationPolicy: context.validationPolicy
                )
                try latestState.apply(
                    events: built.events,
                    timelineNextSeq: appendState.nextSeq,
                    updatedAt: timestamp
                )
                try MSPAgentChatStore.writeLatestStateIndex(latestState, at: packageURL)
            }
            return built.result
        }
    }

    public func modelVisibleHistory() throws -> [MSPAgentJSONValue] {
        if let latestState = try latestStateIndexForCurrentManifest() {
            return latestState.modelVisibleHistory
        }
        let latestState = try rebuildLatestStateIndexForCurrentPackage()
        return latestState.modelVisibleHistory
    }

    private func latestStateIndexForCurrentManifest() throws -> MSPAgentChatLatestStateIndex? {
        let manifest = try MSPChatCoreReader().readManifest(at: packageURL)
        return try MSPAgentChatStore.latestStateIndex(at: packageURL, matching: manifest)
    }

    private func rebuildLatestStateIndexForCurrentPackage() throws -> MSPAgentChatLatestStateIndex {
        let latestState = try MSPAgentChatStore.latestStateIndex(at: packageURL)
        try? MSPAgentChatStore.writeLatestStateIndex(latestState, at: packageURL)
        return latestState
    }

    static func modelVisibleHistory(in package: MSPChatPackage) throws -> [MSPAgentJSONValue] {
        var items: [MSPAgentJSONValue] = []

        for event in package.timelineEvents {
            switch event.type {
            case Self.modelContextItemEventType:
                guard let item = event.payload["item"] else {
                    throw MSPAgentChatStoreError.missingAgentTranscriptItem(event.id)
                }
                items.append(try item.agentJSONValue())
            case Self.modelContextSnapshotEventType:
                guard let payloadItems = event.payload["items"]?.arrayValue else {
                    throw MSPAgentChatStoreError.invalidAgentTranscriptPayload(event.id)
                }
                items = try payloadItems.map { try $0.agentJSONValue() }
            default:
                continue
            }
        }

        return items
    }

    @discardableResult
    public func appendModelVisibleItems(
        _ items: [MSPAgentJSONValue],
        createdAt: String? = nil,
        turnID: String? = nil
    ) throws -> [MSPChatTimelineEvent] {
        guard !items.isEmpty else {
            return []
        }

        return try appendGeneratedEvents(createdAt: createdAt) { nextSeq, timestamp in
            let events = try items.enumerated().map { offset, item in
                let seq = nextSeq + offset
                return MSPChatTimelineEvent(
                    id: MSPAgentChatTimelineEventID.make(prefix: "agent_item", seq: seq),
                    type: Self.modelContextItemEventType,
                    seq: seq,
                    createdAt: timestamp,
                    turnID: turnID,
                    payload: [
                        "record_type": .string(Self.modelContextItemEventType),
                        "item_index": .int(seq),
                        "item": try item.chatJSONValue()
                    ]
                )
            }
            return (events, events)
        }
    }

    @discardableResult
    public func replaceModelVisibleHistory(
        _ items: [MSPAgentJSONValue],
        reason: MSPAgentChatSnapshotReason = .replaced,
        createdAt: String? = nil
    ) throws -> MSPChatTimelineEvent {
        try appendGeneratedEvents(createdAt: createdAt) { nextSeq, timestamp in
            let event = MSPChatTimelineEvent(
                id: MSPAgentChatTimelineEventID.make(prefix: "agent_snapshot", seq: nextSeq),
                type: Self.modelContextSnapshotEventType,
                seq: nextSeq,
                createdAt: timestamp,
                payload: try Self.modelContextSnapshotPayload(items, reason: reason)
            )
            return ([event], event)
        }
    }

    @discardableResult
    public func appendTurnStarted(
        turnID: String,
        createdAt: String? = nil
    ) throws -> MSPChatTimelineEvent {
        try appendGeneratedEvents(createdAt: createdAt) { nextSeq, timestamp in
            let event = MSPChatTimelineEvent(
                id: MSPAgentChatTimelineEventID.make(prefix: "turn_started", seq: nextSeq),
                type: "turn_started",
                seq: nextSeq,
                createdAt: timestamp,
                turnID: turnID,
                payload: [
                    "turn_id": .string(turnID),
                    "source": .string("MSPAgentChatStore")
                ]
            )
            return ([event], event)
        }
    }

    @discardableResult
    public func appendTurnCompleted(
        turnID: String,
        status: String = "completed",
        createdAt: String? = nil
    ) throws -> MSPChatTimelineEvent {
        try appendGeneratedEvents(createdAt: createdAt) { nextSeq, timestamp in
            let event = MSPChatTimelineEvent(
                id: MSPAgentChatTimelineEventID.make(prefix: "turn_completed", seq: nextSeq),
                type: "turn_completed",
                seq: nextSeq,
                createdAt: timestamp,
                turnID: turnID,
                payload: [
                    "turn_id": .string(turnID),
                    "status": .string(status),
                    "source": .string("MSPAgentChatStore")
                ]
            )
            return ([event], event)
        }
    }

    @discardableResult
    public func markOpenTurnsAborted(
        reason: String = "interrupted",
        createdAt: String? = nil
    ) throws -> [MSPChatTimelineEvent] {
        try MSPChatCoreWriter.withPackageWriteLock(at: packageURL) {
            let context = try appendContextForCurrentPackage()
            var appendState = context.appendState
            var latestState = context.latestState
            let timestamp = createdAt ?? currentTimestamp()
            let openTurnIDs = latestState.openTurnIDs

            guard !openTurnIDs.isEmpty else {
                return []
            }

            let events = openTurnIDs.enumerated().map { offset, turnID in
                let seq = appendState.nextSeq + offset
                return MSPChatTimelineEvent(
                    id: MSPAgentChatTimelineEventID.make(prefix: "turn_aborted", seq: seq),
                    type: "turn_aborted",
                    seq: seq,
                    createdAt: timestamp,
                    turnID: turnID,
                    payload: [
                        "turn_id": .string(turnID),
                        "reason": .string(reason),
                        "source": .string("MSPAgentChatStore")
                    ]
                )
            }
            try MSPChatCoreWriter().appendEvents(
                events,
                to: packageURL,
                state: &appendState,
                updatedAt: timestamp,
                validationPolicy: context.validationPolicy
            )
            try latestState.apply(
                events: events,
                timelineNextSeq: appendState.nextSeq,
                updatedAt: timestamp
            )
            try MSPAgentChatStore.writeLatestStateIndex(latestState, at: packageURL)
            return events
        }
    }

    @discardableResult
    public func appendApplicationStateSnapshot(
        type snapshotType: String,
        snapshot: MSPAgentJSONValue,
        createdAt: String? = nil
    ) throws -> MSPChatTimelineEvent {
        try appendGeneratedEvents(createdAt: createdAt) { nextSeq, timestamp in
            let event = MSPChatTimelineEvent(
                id: MSPAgentChatTimelineEventID.make(prefix: "application_snapshot", seq: nextSeq),
                type: Self.applicationStateSnapshotEventType,
                seq: nextSeq,
                createdAt: timestamp,
                payload: [
                    "record_type": .string(Self.applicationStateSnapshotEventType),
                    "snapshot_type": .string(snapshotType),
                    "snapshot": try snapshot.chatJSONValue()
                ]
            )
            return ([event], event)
        }
    }

    public func applicationStateSnapshots(
        type snapshotType: String
    ) throws -> [MSPAgentJSONValue] {
        let package = try packageSnapshot()
        return try Self.applicationStateSnapshots(in: package, type: snapshotType)
    }

    static func applicationStateSnapshots(
        in package: MSPChatPackage,
        type snapshotType: String
    ) throws -> [MSPAgentJSONValue] {
        return try package.timelineEvents.compactMap { event in
            guard event.type == Self.applicationStateSnapshotEventType,
                  event.payload["snapshot_type"]?.stringValue == snapshotType,
                  let snapshot = event.payload["snapshot"]
            else {
                return nil
            }
            return try snapshot.agentJSONValue()
        }
    }

    public func latestApplicationStateSnapshot(
        type snapshotType: String
    ) throws -> MSPAgentJSONValue? {
        if let latestState = try latestStateIndexForCurrentManifest() {
            return latestState.applicationSnapshotEntries[snapshotType]?.snapshot
        }
        let latestState = try rebuildLatestStateIndexForCurrentPackage()
        return latestState.applicationSnapshotEntries[snapshotType]?.snapshot
    }

    @discardableResult
    public func appendModelVisibleItemsAsync(
        _ items: [MSPAgentJSONValue],
        createdAt: String? = nil,
        turnID: String? = nil
    ) async throws -> [MSPChatTimelineEvent] {
        try await writeQueue.run {
            try appendModelVisibleItems(items, createdAt: createdAt, turnID: turnID)
        }
    }

    @discardableResult
    public func replaceModelVisibleHistoryAsync(
        _ items: [MSPAgentJSONValue],
        reason: MSPAgentChatSnapshotReason = .replaced,
        createdAt: String? = nil
    ) async throws -> MSPChatTimelineEvent {
        try await writeQueue.run {
            try replaceModelVisibleHistory(items, reason: reason, createdAt: createdAt)
        }
    }

    @discardableResult
    public func appendTurnStartedAsync(
        turnID: String,
        createdAt: String? = nil
    ) async throws -> MSPChatTimelineEvent {
        try await writeQueue.run {
            try appendTurnStarted(turnID: turnID, createdAt: createdAt)
        }
    }

    @discardableResult
    public func appendTurnCompletedAsync(
        turnID: String,
        status: String = "completed",
        createdAt: String? = nil
    ) async throws -> MSPChatTimelineEvent {
        try await writeQueue.run {
            try appendTurnCompleted(turnID: turnID, status: status, createdAt: createdAt)
        }
    }

    @discardableResult
    public func markOpenTurnsAbortedAsync(
        reason: String = "interrupted",
        createdAt: String? = nil
    ) async throws -> [MSPChatTimelineEvent] {
        try await writeQueue.run {
            try markOpenTurnsAborted(reason: reason, createdAt: createdAt)
        }
    }

    @discardableResult
    public func appendApplicationStateSnapshotAsync(
        type snapshotType: String,
        snapshot: MSPAgentJSONValue,
        createdAt: String? = nil
    ) async throws -> MSPChatTimelineEvent {
        try await writeQueue.run {
            try appendApplicationStateSnapshot(
                type: snapshotType,
                snapshot: snapshot,
                createdAt: createdAt
            )
        }
    }

    static func latestApplicationStateSnapshot(
        in package: MSPChatPackage,
        type snapshotType: String
    ) throws -> MSPAgentJSONValue? {
        try applicationStateSnapshots(in: package, type: snapshotType).last
    }

    static func modelContextSnapshotPayload(
        _ items: [MSPAgentJSONValue],
        reason: MSPAgentChatSnapshotReason
    ) throws -> [String: MSPChatJSONValue] {
        [
            "record_type": .string(Self.modelContextSnapshotEventType),
            "reason": .string(reason.rawValue),
            "item_count": .int(items.count),
            "items": .array(try items.map { try $0.chatJSONValue() })
        ]
    }

    private func currentTimestamp() -> String {
        MSPAgentChatStore.timestamp(for: clock())
    }
}
