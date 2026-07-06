import Foundation

enum MSPChatCompactionPackageStoreError: Error, Equatable, Sendable {
    case invalidBlobReference(String)
    case invalidNDJSONLine(file: String, line: Int)
    case missingTimeline
    case missingJournalReplacementHistory(String)
}

enum MSPChatCompactionPackageStore {
    static func writePackage(
        _ package: MSPChatCompactionPackageSnapshot,
        to packageURL: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: packageURL.appendingPathComponent("projections", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: packageURL.appendingPathComponent("blobs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: packageURL.appendingPathComponent("indexes", isDirectory: true),
            withIntermediateDirectories: true
        )

        try writeManifest(to: packageURL)
        try writeTimeline(package.timeline, to: packageURL)
        try writeJournal(package.journal, to: packageURL)
        try writeBlobs(package.blobs, to: packageURL)
        try rebuildModelContextProjection(at: packageURL)
        if let modelContextProjection = package.modelContextProjection {
            try writeProjectionLines(
                modelContextProjection,
                to: packageURL.appendingPathComponent("projections/model-context.ndjson")
            )
        }
    }

    static func loadPackage(at packageURL: URL) throws -> MSPChatCompactionPackageSnapshot {
        let timeline = try readTimeline(from: packageURL)
        let journal = try readJournal(from: packageURL)
        let blobs = try readBlobs(from: packageURL)
        let projection = try readOptionalProjection(from: packageURL)
        return MSPChatCompactionPackageSnapshot(
            timeline: timeline,
            journal: journal,
            blobs: blobs,
            modelContextProjection: projection
        )
    }

    static func rebuildModelContextProjection(at packageURL: URL) throws {
        let timelineURL = packageURL.appendingPathComponent("timeline.ndjson")
        guard FileManager.default.fileExists(atPath: timelineURL.path) else {
            throw MSPChatCompactionPackageStoreError.missingTimeline
        }
        let lines = try readNDJSONLines(from: timelineURL, file: "timeline.ndjson")
        let eventIDs = lines.compactMap { $0.objectValue?["id"]?.stringValue }
        let eventSeqs = lines.compactMap { $0.objectValue?["seq"]?.intValue }
        let sourceBytes = lines
            .map { try? encodeJSONLine($0) }
            .compactMap { $0 }
            .joined(separator: "\n")
            .data(using: .utf8) ?? Data()
        let projectionID = "proj-model-context-v1-\(eventSeqs.min() ?? 0)-\(eventSeqs.max() ?? 0)"
        let metadata: MSPAgentJSONValue = .object([
            "record_type": .string("projection_metadata"),
            "projection_id": .string(projectionID),
            "projection_kind": .string("model-context"),
            "projection_format": .string("ndjson"),
            "source_event_ids": .array(eventIDs.map(MSPAgentJSONValue.string)),
            "source_fingerprint": .string(stableProjectionFingerprint(sourceBytes)),
            "lossy": .bool(false),
            "redacted": .bool(false),
            "truncated": .bool(false),
            "context_policy": .object([
                "policy": .string("full-durable-timeline"),
                "source": .string("timeline.ndjson"),
                "artifact_blob_inclusion": .string("references-only"),
                "compaction_checkpoint": .null
            ]),
            "stale_if": .array([
                .string("timeline.ndjson source_event_range changes"),
                .string("timeline.ndjson source_fingerprint changes"),
                .string("timeline.ndjson source_event_ids change")
            ])
        ])
        let projectionEvents = lines.map { event -> MSPAgentJSONValue in
            .object([
                "record_type": .string("projection_event"),
                "projection_id": .string(projectionID),
                "projection_kind": .string("model-context"),
                "source_event_id": event.objectValue?["id"] ?? .null,
                "source_seq": event.objectValue?["seq"] ?? .null,
                "event_type": event.objectValue?["type"] ?? .null,
                "context_item": .object([
                    "not_canonical": .bool(true),
                    "synthetic": .bool(false),
                    "source_event": event
                ])
            ])
        }
        try writeProjectionLines(
            [metadata] + projectionEvents,
            to: packageURL.appendingPathComponent("projections/model-context.ndjson")
        )
    }

    private static func writeManifest(to packageURL: URL) throws {
        let manifest: MSPAgentJSONValue = .object([
            "format": .string("msp.chat"),
            "version": .number(1),
            "profiles": .array([
                .string("core-timeline"),
                .string("agent-timeline"),
                .string("projection-cache"),
                .string("resumable-context"),
                .string("runtime-journal")
            ]),
            "capabilities": .array([
                .string("read_core"),
                .string("write_core"),
                .string("preserve_unknown_events"),
                .string("generate_projection"),
                .string("replay_journal")
            ]),
            "storage": .object([
                "canonical_timeline": .string("timeline.ndjson"),
                "runtime_journal": .string("journal.ndjson"),
                "indexes": .object([
                    "compaction-checkpoints": .string("indexes/compaction-checkpoints.ndjson")
                ]),
                "projections": .object([
                    "model-context": .string("projections/model-context.ndjson")
                ])
            ])
        ])
        try writeJSON(manifest, to: packageURL.appendingPathComponent("manifest.json"))
    }

    private static func writeTimeline(
        _ timeline: [MSPChatCompactionTimelineEvent],
        to packageURL: URL
    ) throws {
        let lines = try timeline.enumerated().map { index, event in
            try encodeJSONLine(timelineRecord(for: event, index: index))
        }
        try lines.joined(separator: "\n")
            .appending(lines.isEmpty ? "" : "\n")
            .write(
                to: packageURL.appendingPathComponent("timeline.ndjson"),
                atomically: true,
                encoding: .utf8
            )
    }

    private static func writeJournal(
        _ journal: [MSPChatCompactionJournalEntry],
        to packageURL: URL
    ) throws {
        let lines = try journal.enumerated().map { index, entry in
            try encodeJSONLine(journalRecord(for: entry, index: index))
        }
        try lines.joined(separator: "\n")
            .appending(lines.isEmpty ? "" : "\n")
            .write(
                to: packageURL.appendingPathComponent("journal.ndjson"),
                atomically: true,
                encoding: .utf8
            )
    }

    private static func writeBlobs(
        _ blobs: [String: [MSPAgentJSONValue]],
        to packageURL: URL
    ) throws {
        for (ref, values) in blobs {
            let url = try blobURL(for: ref, packageURL: packageURL)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeJSON(.array(values), to: url)
        }
    }

    private static func readTimeline(
        from packageURL: URL
    ) throws -> [MSPChatCompactionTimelineEvent] {
        let url = packageURL.appendingPathComponent("timeline.ndjson")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MSPChatCompactionPackageStoreError.missingTimeline
        }
        return try readNDJSONLines(from: url, file: "timeline.ndjson").enumerated().map { index, line in
            try timelineEvent(from: line, lineNumber: index + 1)
        }
    }

    private static func readJournal(
        from packageURL: URL
    ) throws -> [MSPChatCompactionJournalEntry] {
        let url = packageURL.appendingPathComponent("journal.ndjson")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try readNDJSONLines(from: url, file: "journal.ndjson").enumerated().map { index, line in
            try journalEntry(from: line, lineNumber: index + 1)
        }
    }

    private static func readBlobs(
        from packageURL: URL
    ) throws -> [String: [MSPAgentJSONValue]] {
        let blobsURL = packageURL.appendingPathComponent("blobs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: blobsURL.path) else {
            return [:]
        }
        let enumerator = FileManager.default.enumerator(
            at: blobsURL,
            includingPropertiesForKeys: nil
        )
        var blobs: [String: [MSPAgentJSONValue]] = [:]
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(MSPAgentJSONValue.self, from: data)
            guard let values = value.arrayValue else {
                continue
            }
            let blobRootPath = blobsURL.resolvingSymlinksInPath().path + "/"
            let blobPath = url.resolvingSymlinksInPath().path
            let relative = "blobs/" + blobPath.replacingOccurrences(
                of: blobRootPath,
                with: ""
            )
            blobs[relative] = values
        }
        return blobs
    }

    private static func readOptionalProjection(
        from packageURL: URL
    ) throws -> [MSPAgentJSONValue]? {
        let url = packageURL.appendingPathComponent("projections/model-context.ndjson")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try readNDJSONLines(from: url, file: "projections/model-context.ndjson")
    }

    private static func timelineRecord(
        for event: MSPChatCompactionTimelineEvent,
        index: Int
    ) throws -> MSPAgentJSONValue {
        let seq = Double(index + 1)
        let eventID = "evt-\(String(format: "%020d", index + 1))"
        let type: String
        let body: MSPAgentJSONValue
        switch event {
        case .durableCompactionCheckpoint(let checkpoint):
            type = "durable_compaction_checkpoint"
            body = .object([
                "checkpoint": try MSPAgentJSONValue(encoding: checkpoint)
            ])
        case .modelVisibleSuffixItem(let item):
            type = "message"
            body = .object(["item": item])
        case .worldState(let item):
            type = item.kind == .patch ? "state_patch" : "state_snapshot"
            body = .object([
                "world_state": encodeWorldState(item)
            ])
        case .referenceContext(let item):
            type = "runtime_context_snapshot"
            body = .object([
                "reference_context": try encodeReferenceContext(item)
            ])
        case .rollback(let userTurns):
            type = "timeline_rollback"
            body = .object([
                "num_turns": .number(Double(max(0, userTurns)))
            ])
        case .ignored:
            type = "runtime_event"
            body = .object([:])
        }
        return .object([
            "id": .string(eventID),
            "type": .string(type),
            "seq": .number(seq),
            "commit_seq": .number(seq),
            "actor": .string("msp-agent"),
            "durability": .string("durable_replay"),
            "source_ref": .object([
                "journal_commit_seq": .number(seq)
            ]),
            "body": body
        ])
    }

    private static func timelineEvent(
        from value: MSPAgentJSONValue,
        lineNumber: Int
    ) throws -> MSPChatCompactionTimelineEvent {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue,
              let body = object["body"]?.objectValue else {
            throw MSPChatCompactionPackageStoreError.invalidNDJSONLine(
                file: "timeline.ndjson",
                line: lineNumber
            )
        }
        switch type {
        case "durable_compaction_checkpoint":
            guard let checkpointValue = body["checkpoint"] else {
                return .ignored
            }
            return .durableCompactionCheckpoint(try decode(
                MSPCompactionCheckpoint.self,
                from: checkpointValue
            ))
        case "message":
            if let item = body["item"] {
                return .modelVisibleSuffixItem(item)
            }
            return .ignored
        case "state_snapshot", "state_patch":
            guard let worldState = body["world_state"] else {
                return .ignored
            }
            return .worldState(try decodeWorldState(worldState))
        case "runtime_context_snapshot":
            guard let referenceContext = body["reference_context"] else {
                return .ignored
            }
            return .referenceContext(try decodeReferenceContext(referenceContext))
        case "timeline_rollback":
            return .rollback(userTurns: body["num_turns"]?.intValue ?? 0)
        default:
            return .ignored
        }
    }

    private static func journalRecord(
        for entry: MSPChatCompactionJournalEntry,
        index: Int
    ) throws -> MSPAgentJSONValue {
        let seq = Double(index + 1)
        var payload: [String: MSPAgentJSONValue] = [
            "ref": .string(entry.ref)
        ]
        if let sourceTransport = entry.sourceTransport {
            payload["source_transport"] = sourceTransport
        }
        if let replacementHistory = entry.replacementHistory {
            payload["replacement_history"] = .array(replacementHistory)
        }
        return .object([
            "commit_seq": .number(seq),
            "entry_type": .string("source_transport"),
            "event_id": .string("journal-\(String(format: "%020d", index + 1))"),
            "source_transport": .object([
                "schema": .string("msp.compaction.replay.v1"),
                "payload": .object(payload)
            ])
        ])
    }

    private static func journalEntry(
        from value: MSPAgentJSONValue,
        lineNumber: Int
    ) throws -> MSPChatCompactionJournalEntry {
        guard let object = value.objectValue,
              let transport = object["source_transport"]?.objectValue,
              let payload = transport["payload"]?.objectValue,
              let ref = payload["ref"]?.stringValue else {
            throw MSPChatCompactionPackageStoreError.invalidNDJSONLine(
                file: "journal.ndjson",
                line: lineNumber
            )
        }
        return MSPChatCompactionJournalEntry(
            ref: ref,
            sourceTransport: payload["source_transport"],
            replacementHistory: payload["replacement_history"]?.arrayValue
        )
    }

    private static func encodeWorldState(
        _ item: MSPCompactionWorldStateReplayItem
    ) -> MSPAgentJSONValue {
        .object([
            "kind": .string(item.kind.rawValue),
            "state": item.state ?? .null
        ])
    }

    private static func decodeWorldState(
        _ value: MSPAgentJSONValue
    ) throws -> MSPCompactionWorldStateReplayItem {
        guard let object = value.objectValue,
              let kindValue = object["kind"]?.stringValue,
              let kind = MSPCompactionWorldStateReplayKind(rawValue: kindValue) else {
            throw MSPChatCompactionPackageStoreError.invalidNDJSONLine(
                file: "timeline.ndjson",
                line: 0
            )
        }
        return MSPCompactionWorldStateReplayItem(
            kind: kind,
            state: object["state"] == .null ? nil : object["state"]
        )
    }

    private static func encodeReferenceContext(
        _ item: MSPCompactionReferenceContextReplayItem
    ) throws -> MSPAgentJSONValue {
        switch item {
        case .turnStarted(let id):
            return .object(["kind": .string("turn_started"), "id": .string(id)])
        case .turnComplete(let id):
            return .object(["kind": .string("turn_complete"), "id": .string(id)])
        case .turnAborted(let id):
            return .object(["kind": .string("turn_aborted"), "id": id.map(MSPAgentJSONValue.string) ?? .null])
        case .userMessage:
            return .object(["kind": .string("user_message")])
        case .responseItemUserTurnBoundary:
            return .object(["kind": .string("response_item_user_turn_boundary")])
        case .interAgentCommunication:
            return .object(["kind": .string("inter_agent_communication")])
        case .turnContext(let snapshot):
            return .object([
                "kind": .string("turn_context"),
                "snapshot": try MSPAgentJSONValue(encoding: snapshot)
            ])
        case .compaction:
            return .object(["kind": .string("compaction")])
        case .rollback(let userTurns):
            return .object([
                "kind": .string("rollback"),
                "user_turns": .number(Double(userTurns))
            ])
        case .ignored:
            return .object(["kind": .string("ignored")])
        }
    }

    private static func decodeReferenceContext(
        _ value: MSPAgentJSONValue
    ) throws -> MSPCompactionReferenceContextReplayItem {
        guard let object = value.objectValue,
              let kind = object["kind"]?.stringValue else {
            throw MSPChatCompactionPackageStoreError.invalidNDJSONLine(
                file: "timeline.ndjson",
                line: 0
            )
        }
        switch kind {
        case "turn_started":
            return .turnStarted(id: object["id"]?.stringValue ?? "")
        case "turn_complete":
            return .turnComplete(id: object["id"]?.stringValue ?? "")
        case "turn_aborted":
            return .turnAborted(id: object["id"]?.stringValue)
        case "user_message":
            return .userMessage
        case "response_item_user_turn_boundary":
            return .responseItemUserTurnBoundary
        case "inter_agent_communication":
            return .interAgentCommunication
        case "turn_context":
            guard let snapshot = object["snapshot"] else {
                return .ignored
            }
            return .turnContext(try decode(MSPCompactionTurnContextSnapshot.self, from: snapshot))
        case "compaction":
            return .compaction
        case "rollback":
            return .rollback(userTurns: object["user_turns"]?.intValue ?? 0)
        default:
            return .ignored
        }
    }

    private static func writeProjectionLines(
        _ lines: [MSPAgentJSONValue],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = try lines
            .map(encodeJSONLine)
            .joined(separator: "\n")
            .appending(lines.isEmpty ? "" : "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readNDJSONLines(
        from url: URL,
        file: String
    ) throws -> [MSPAgentJSONValue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .map { index, line in
                guard let data = line.data(using: .utf8),
                      let value = try? JSONDecoder().decode(MSPAgentJSONValue.self, from: data) else {
                    throw MSPChatCompactionPackageStoreError.invalidNDJSONLine(
                        file: file,
                        line: index + 1
                    )
                }
                return value
            }
    }

    private static func writeJSON(
        _ value: MSPAgentJSONValue,
        to url: URL
    ) throws {
        let data = try JSONEncoder.prettySorted.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func encodeJSONLine(_ value: MSPAgentJSONValue) throws -> String {
        let data = try JSONEncoder.sorted.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: MSPAgentJSONValue
    ) throws -> T {
        let data = try JSONEncoder.sorted.encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func blobURL(
        for ref: String,
        packageURL: URL
    ) throws -> URL {
        guard !ref.hasPrefix("/"),
              !ref.split(separator: "/").contains("..") else {
            throw MSPChatCompactionPackageStoreError.invalidBlobReference(ref)
        }
        let relative = ref.hasPrefix("blobs/") ? ref : "blobs/\(ref)"
        return packageURL.appendingPathComponent(relative)
    }

    private static func stableProjectionFingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return "fnv1a64:\(String(format: "%016llx", hash))"
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
