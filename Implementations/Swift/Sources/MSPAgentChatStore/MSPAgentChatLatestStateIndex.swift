import Foundation
import MSPAgentBridge
import MSPChat

extension MSPAgentChatStore {
    static func latestStateIndex(from package: MSPChatPackage) throws -> MSPAgentChatLatestStateIndex {
        var index = MSPAgentChatLatestStateIndex(
            timelinePath: package.manifest.timelinePath,
            timelineNextSeq: package.nextSeq,
            updatedAt: package.manifest.updatedAt ?? package.manifest.createdAt ?? ""
        )
        try index.apply(
            events: package.timelineEvents,
            timelineNextSeq: package.nextSeq,
            updatedAt: package.manifest.updatedAt ?? package.manifest.createdAt ?? ""
        )
        return index
    }

    static func latestStateIndex(at packageURL: URL) throws -> MSPAgentChatLatestStateIndex {
        let standardizedURL = packageURL.standardizedFileURL
        let manifest = try MSPChatCoreReader().readManifest(at: standardizedURL)
        return try latestStateIndex(at: standardizedURL, manifest: manifest)
    }

    static func latestStateIndex(
        at packageURL: URL,
        manifest: MSPChatManifest
    ) throws -> MSPAgentChatLatestStateIndex {
        var index = MSPAgentChatLatestStateIndex(
            timelinePath: manifest.timelinePath,
            timelineNextSeq: manifest.timelineNextSeq ?? 1,
            updatedAt: manifest.updatedAt ?? manifest.createdAt ?? ""
        )
        let readResult = try MSPChatCoreReader().forEachTimelineEvent(
            at: packageURL,
            manifest: manifest
        ) { event in
            try index.apply(event: event)
        }
        index.timelineNextSeq = max(manifest.timelineNextSeq ?? 1, readResult.nextSeq)
        index.updatedAt = manifest.updatedAt ?? manifest.createdAt ?? ""
        return index
    }

    static func writeLatestStateIndex(
        _ index: MSPAgentChatLatestStateIndex,
        at packageURL: URL
    ) throws {
        try index.write(to: packageURL)
    }

    static func latestStateIndex(
        at packageURL: URL,
        matching manifest: MSPChatManifest
    ) throws -> MSPAgentChatLatestStateIndex? {
        guard let index = try MSPAgentChatLatestStateIndex.read(from: packageURL) else {
            return nil
        }
        guard index.isFresh(for: manifest) else {
            return nil
        }
        return index
    }
}

struct MSPAgentChatLatestStateIndex: Sendable, Equatable {
    static let relativePath = "indexes/latest-agent-state.json"
    static let schemaVersion = 1

    var timelinePath: String
    var timelineNextSeq: Int
    var updatedAt: String
    var modelVisibleHistory: [MSPAgentJSONValue]
    var applicationSnapshotEntries: [String: MSPAgentChatApplicationSnapshotIndexEntry]
    var openTurnIDs: [String]

    init(
        timelinePath: String,
        timelineNextSeq: Int,
        updatedAt: String,
        modelVisibleHistory: [MSPAgentJSONValue] = [],
        applicationSnapshotEntries: [String: MSPAgentChatApplicationSnapshotIndexEntry] = [:],
        openTurnIDs: [String] = []
    ) {
        self.timelinePath = timelinePath
        self.timelineNextSeq = timelineNextSeq
        self.updatedAt = updatedAt
        self.modelVisibleHistory = modelVisibleHistory
        self.applicationSnapshotEntries = applicationSnapshotEntries
        self.openTurnIDs = openTurnIDs
    }

    init(rawJSON: [String: MSPChatJSONValue]) throws {
        guard rawJSON["schema_version"]?.intValue == Self.schemaVersion,
              rawJSON["index_kind"]?.stringValue == "msp.agent.latest-state" else {
            throw MSPChatError.invalidJSON("latest agent state index has an unsupported schema.")
        }
        guard let timelineObject = rawJSON["timeline"]?.objectValue,
              let timelinePath = timelineObject["path"]?.stringValue,
              let timelineNextSeq = timelineObject["next_seq"]?.intValue else {
            throw MSPChatError.invalidJSON("latest agent state index timeline is invalid.")
        }
        let modelHistory = try (rawJSON["model_visible_history"]?.arrayValue ?? [])
            .map { try $0.agentJSONValue() }
        let snapshotEntriesObject = rawJSON["latest_application_snapshots"]?.objectValue ?? [:]
        let snapshotEntries = try snapshotEntriesObject.mapValues {
            try MSPAgentChatApplicationSnapshotIndexEntry(chatJSONValue: $0)
        }
        self.init(
            timelinePath: timelinePath,
            timelineNextSeq: timelineNextSeq,
            updatedAt: rawJSON["updated_at"]?.stringValue ?? "",
            modelVisibleHistory: modelHistory,
            applicationSnapshotEntries: snapshotEntries,
            openTurnIDs: rawJSON["open_turn_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    mutating func apply(
        events: [MSPChatTimelineEvent],
        timelineNextSeq: Int,
        updatedAt: String
    ) throws {
        for event in events {
            try apply(event: event)
        }
        self.timelineNextSeq = timelineNextSeq
        self.updatedAt = updatedAt
    }

    mutating func apply(event: MSPChatTimelineEvent) throws {
        switch event.type {
        case MSPAgentChatSession.modelContextItemEventType:
            guard let item = event.payload["item"] else {
                throw MSPAgentChatStoreError.missingAgentTranscriptItem(event.id)
            }
            modelVisibleHistory.append(try item.agentJSONValue())
        case MSPAgentChatSession.modelContextSnapshotEventType:
            guard let payloadItems = event.payload["items"]?.arrayValue else {
                throw MSPAgentChatStoreError.invalidAgentTranscriptPayload(event.id)
            }
            modelVisibleHistory = try payloadItems.map { try $0.agentJSONValue() }
        case MSPAgentChatSession.applicationStateSnapshotEventType:
            guard let snapshotType = event.payload["snapshot_type"]?.stringValue,
                  let snapshot = event.payload["snapshot"] else {
                throw MSPAgentChatStoreError.invalidAgentTranscriptPayload(event.id)
            }
            applicationSnapshotEntries[snapshotType] = MSPAgentChatApplicationSnapshotIndexEntry(
                eventID: event.id,
                seq: event.seq,
                createdAt: event.createdAt,
                snapshot: try snapshot.agentJSONValue()
            )
        case "turn_started":
            guard let turnID = event.turnID ?? event.payload["turn_id"]?.stringValue else {
                return
            }
            if !openTurnIDs.contains(turnID) {
                openTurnIDs.append(turnID)
            }
        case "turn_completed", "turn_aborted":
            guard let turnID = event.turnID ?? event.payload["turn_id"]?.stringValue else {
                return
            }
            openTurnIDs.removeAll { $0 == turnID }
        default:
            return
        }
    }

    static func read(from packageURL: URL) throws -> MSPAgentChatLatestStateIndex? {
        let url = packageURL.standardizedFileURL.appendingPathComponent(Self.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              case let .object(value) = try MSPChatJSONValue.fromAny(dictionary) else {
            throw MSPChatError.invalidJSON("\(url.path) must contain a JSON object.")
        }
        return try MSPAgentChatLatestStateIndex(rawJSON: value)
    }

    func isFresh(for manifest: MSPChatManifest) -> Bool {
        timelinePath == manifest.timelinePath
            && timelineNextSeq == manifest.timelineNextSeq
    }

    func write(to packageURL: URL) throws {
        let url = packageURL.standardizedFileURL.appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: rawJSON().mapValues { $0.toAny() },
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func rawJSON() throws -> [String: MSPChatJSONValue] {
        let lastSeq = max(1, timelineNextSeq - 1)
        return [
            "schema_version": .int(Self.schemaVersion),
            "index_kind": .string("msp.agent.latest-state"),
            "updated_at": .string(updatedAt),
            "timeline": .object([
                "path": .string(timelinePath),
                "next_seq": .int(timelineNextSeq)
            ]),
            "source_event_range": .object([
                "from_seq": .int(1),
                "to_seq": .int(lastSeq)
            ]),
            "source_fingerprint": .string("timeline:\(timelinePath):next_seq:\(timelineNextSeq)"),
            "generator": .object([
                "name": .string("MSPAgentChatStore"),
                "version": .string("1")
            ]),
            "stale_if": .object([
                "timeline_path_changes_from": .string(timelinePath),
                "timeline_next_seq_changes_from": .int(timelineNextSeq)
            ]),
            "model_visible_history": .array(try modelVisibleHistory.map { try $0.chatJSONValue() }),
            "open_turn_ids": .array(openTurnIDs.map(MSPChatJSONValue.string)),
            "latest_application_snapshots": .object(try applicationSnapshotEntries.mapValues { entry in
                try entry.chatJSONValue()
            })
        ]
    }
}

struct MSPAgentChatApplicationSnapshotIndexEntry: Sendable, Equatable {
    var eventID: String
    var seq: Int
    var createdAt: String
    var snapshot: MSPAgentJSONValue

    init(
        eventID: String,
        seq: Int,
        createdAt: String,
        snapshot: MSPAgentJSONValue
    ) {
        self.eventID = eventID
        self.seq = seq
        self.createdAt = createdAt
        self.snapshot = snapshot
    }

    init(chatJSONValue value: MSPChatJSONValue) throws {
        guard let object = value.objectValue,
              let eventID = object["event_id"]?.stringValue,
              let seq = object["seq"]?.intValue,
              let createdAt = object["created_at"]?.stringValue,
              let snapshot = object["snapshot"] else {
            throw MSPChatError.invalidJSON("latest application snapshot index entry is invalid.")
        }
        self.init(
            eventID: eventID,
            seq: seq,
            createdAt: createdAt,
            snapshot: try snapshot.agentJSONValue()
        )
    }

    func chatJSONValue() throws -> MSPChatJSONValue {
        .object([
            "event_id": .string(eventID),
            "seq": .int(seq),
            "created_at": .string(createdAt),
            "snapshot": try snapshot.chatJSONValue()
        ])
    }
}
