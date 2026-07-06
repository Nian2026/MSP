import Foundation
import MSPAgentBridge
import MSPChat

public struct MSPAgentChatStore: Sendable {
    public let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func createPackage(
        at packageURL: URL,
        packageID: String = UUID().uuidString,
        createdAt: String? = nil,
        initialModelVisibleHistory: [MSPAgentJSONValue] = []
    ) throws -> MSPAgentChatSession {
        let timestamp = createdAt ?? currentTimestamp()
        var initialEvents = [
            MSPChatTimelineEvent(
                id: MSPAgentChatTimelineEventID.make(prefix: "conversation_created", seq: 1),
                type: "conversation_lifecycle",
                seq: 1,
                createdAt: timestamp,
                payload: [
                    "operation": .string("create"),
                    "source": .string("MSPAgentChatStore")
                ]
            )
        ]
        if !initialModelVisibleHistory.isEmpty {
            let snapshotPayload = try MSPAgentChatSession.modelContextSnapshotPayload(
                initialModelVisibleHistory,
                reason: .initial
            )
            initialEvents.append(MSPChatTimelineEvent(
                id: MSPAgentChatTimelineEventID.make(prefix: "agent_snapshot", seq: 2),
                type: MSPAgentChatSession.modelContextSnapshotEventType,
                seq: 2,
                createdAt: timestamp,
                payload: snapshotPayload
            ))
        }

        try MSPChatCoreWriter().createMinimalPackage(
            at: packageURL,
            packageID: packageID,
            createdAt: timestamp,
            initialEvents: initialEvents,
            profiles: ["core-timeline", "agent-timeline"],
            capabilities: ["read_core", "write_core", "preserve_unknown_events"]
        )
        let standardizedURL = packageURL.standardizedFileURL
        var latestState = MSPAgentChatLatestStateIndex(
            timelinePath: MSPChat.defaultTimelinePath,
            timelineNextSeq: (initialEvents.map(\.seq).max() ?? 0) + 1,
            updatedAt: timestamp
        )
        try latestState.apply(
            events: initialEvents,
            timelineNextSeq: latestState.timelineNextSeq,
            updatedAt: timestamp
        )
        try Self.writeLatestStateIndex(latestState, at: standardizedURL)

        return MSPAgentChatSession(packageURL: standardizedURL, clock: clock)
    }

    public func openPackage(at packageURL: URL) throws -> MSPAgentChatSession {
        let standardizedURL = packageURL.standardizedFileURL
        let manifest = try MSPChatCoreReader().readManifest(at: standardizedURL)
        if try Self.latestStateIndex(at: standardizedURL, matching: manifest) == nil {
            let latestState = try Self.latestStateIndex(at: standardizedURL, manifest: manifest)
            try? Self.writeLatestStateIndex(latestState, at: standardizedURL)
        }
        return MSPAgentChatSession(packageURL: standardizedURL, clock: clock)
    }

    public func openPackage(
        at packageURL: URL,
        latestApplicationStateSnapshotType snapshotType: String?
    ) throws -> MSPAgentChatOpenResult {
        let standardizedURL = packageURL.standardizedFileURL
        let session = MSPAgentChatSession(packageURL: standardizedURL, clock: clock)
        let manifest = try MSPChatCoreReader().readManifest(at: standardizedURL)
        let latestState: MSPAgentChatLatestStateIndex
        if let index = try Self.latestStateIndex(at: standardizedURL, matching: manifest) {
            latestState = index
        } else {
            latestState = try Self.latestStateIndex(at: standardizedURL, manifest: manifest)
            try? Self.writeLatestStateIndex(latestState, at: standardizedURL)
        }
        let latestSnapshot = snapshotType.flatMap { type in
            latestState.applicationSnapshotEntries[type]?.snapshot
        }
        return MSPAgentChatOpenResult(
            session: session,
            modelVisibleHistory: latestState.modelVisibleHistory,
            latestApplicationStateSnapshot: latestSnapshot
        )
    }

    private func currentTimestamp() -> String {
        Self.timestamp(for: clock())
    }

    static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
