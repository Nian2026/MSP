import Foundation
import MSPAgentBridge

enum PhotoSorterChatPersistence {
    static let conversationsDirectoryName = "对话"
    static let conversationsVirtualPath = "/对话"
    static let transcriptSnapshotType = "photosorter.transcript.v1"
    static let uiProjectionRelativePath = "indexes/photosorter-current-ui-projection.json"
    static let latestAgentStateRelativePath = "indexes/latest-agent-state.json"
    static let uiProjectionVersion = "photosorter-current-ui-projection-v1"
    static let defaultChatTimelinePath = "timeline.ndjson"

    enum ChatPackageEnvelopeError: Error, Equatable, LocalizedError {
        case packageNotDirectory(String)
        case missingManifest(String)
        case invalidManifest(String)
        case unsafeTimelinePath(String)
        case missingTimeline(String)

        var errorDescription: String? {
            switch self {
            case .packageNotDirectory(let path):
                return "chat package is not a directory: \(path)"
            case .missingManifest(let path):
                return "chat package manifest is missing: \(path)"
            case .invalidManifest(let message):
                return "chat package manifest is invalid: \(message)"
            case .unsafeTimelinePath(let path):
                return "chat package timeline path is unsafe: \(path)"
            case .missingTimeline(let path):
                return "chat package timeline is missing: \(path)"
            }
        }
    }

    struct UIProjection: Equatable, Sendable {
        var activeChatVirtualPath: String?
        var totalItemCount: Int
        var items: [MSPAgentTimelineItem]
        var projectionVersion: String?
        var sourceFingerprint: String?
    }

    static func ensureConversationsDirectory(
        in workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: workspaceURL.appendingPathComponent(conversationsDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    static func defaultPackageLocation(
        in workspaceURL: URL,
        firstUserMessage: String,
        fileManager: FileManager = .default
    ) -> (packageURL: URL, virtualPath: String) {
        let conversationsURL = workspaceURL.appendingPathComponent(
            conversationsDirectoryName,
            isDirectory: true
        )
        let baseName = titleStem(from: firstUserMessage)
        var candidateName = "\(baseName).chat"
        var suffix = 2
        while fileManager.fileExists(atPath: conversationsURL.appendingPathComponent(candidateName, isDirectory: true).path) {
            candidateName = "\(baseName) \(suffix).chat"
            suffix += 1
        }
        return (
            conversationsURL.appendingPathComponent(candidateName, isDirectory: true),
            "\(conversationsVirtualPath)/\(candidateName)"
        )
    }

    static func titleStem(
        from firstUserMessage: String,
        maxCharacters: Int = 24
    ) -> String {
        let collapsedWhitespace = firstUserMessage
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = collapsedWhitespace
            .map { character -> Character in
                switch character {
                case "/", "\\", ":", "\0":
                    return " "
                default:
                    return character
                }
            }
        let compact = String(sanitized)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = compact.isEmpty
            ? fallbackTitleStem()
            : String(compact.prefix(max(1, maxCharacters)))
        let trimmedStem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmedStem.isEmpty ? fallbackTitleStem() : trimmedStem
    }

    static func transcriptSnapshot(
        items: [MSPAgentTimelineItem],
        activeChatVirtualPath: String?
    ) -> MSPAgentJSONValue {
        .object([
            "schema_version": .number(1),
            "active_chat_virtual_path": activeChatVirtualPath.map(MSPAgentJSONValue.string) ?? .null,
            "items": .array(items.map { $0.agentChatJSONValue })
        ])
    }

    static func uiProjectionSnapshot(
        items: [MSPAgentTimelineItem],
        activeChatVirtualPath: String?,
        projectionVersion: String? = uiProjectionVersion,
        sourceFingerprint: String? = nil
    ) -> MSPAgentJSONValue {
        return .object([
            "schema_version": .number(1),
            "projection_kind": .string("photosorter.current-ui"),
            "projection_version": projectionVersion.map(MSPAgentJSONValue.string) ?? .null,
            "source_fingerprint": sourceFingerprint.map(MSPAgentJSONValue.string) ?? .null,
            "active_chat_virtual_path": activeChatVirtualPath.map(MSPAgentJSONValue.string) ?? .null,
            "total_item_count": .number(Double(items.count)),
            "items": .array(items.map { $0.agentChatJSONValue })
        ])
    }

    static func transcriptItems(
        from snapshot: MSPAgentJSONValue
    ) -> [MSPAgentTimelineItem] {
        guard let object = snapshot.objectValue,
              let values = object["items"]?.arrayValue else {
            return []
        }
        return values.compactMap(MSPAgentTimelineItem.init(agentChatJSONValue:))
    }

    static func uiProjection(
        from snapshot: MSPAgentJSONValue
    ) -> UIProjection? {
        guard let object = snapshot.objectValue,
              object["projection_kind"]?.stringValue == "photosorter.current-ui",
              let values = object["items"]?.arrayValue else {
            return nil
        }
        let items = values.compactMap(MSPAgentTimelineItem.init(agentChatJSONValue:))
        let totalItemCount = object["total_item_count"]?.intValue ?? items.count
        return UIProjection(
            activeChatVirtualPath: object["active_chat_virtual_path"]?.stringValue,
            totalItemCount: totalItemCount,
            items: items,
            projectionVersion: object["projection_version"]?.stringValue,
            sourceFingerprint: object["source_fingerprint"]?.stringValue
        )
    }

    static func writeUIProjection(
        items: [MSPAgentTimelineItem],
        activeChatVirtualPath: String?,
        to packageURL: URL,
        projectionVersion: String? = uiProjectionVersion,
        sourceFingerprint: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let resolvedSourceFingerprint = sourceFingerprint
            ?? (try? currentSourceFingerprint(from: packageURL, fileManager: fileManager))
        let snapshot = uiProjectionSnapshot(
            items: items,
            activeChatVirtualPath: activeChatVirtualPath,
            projectionVersion: projectionVersion,
            sourceFingerprint: resolvedSourceFingerprint
        )
        let projectionURL = packageURL
            .standardizedFileURL
            .appendingPathComponent(uiProjectionRelativePath)
        try fileManager.createDirectory(
            at: projectionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: projectionURL, options: .atomic)
    }

    static func readUIProjection(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> UIProjection? {
        let projectionURL = packageURL
            .standardizedFileURL
            .appendingPathComponent(uiProjectionRelativePath)
        guard fileManager.fileExists(atPath: projectionURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: projectionURL)
        let snapshot = try JSONDecoder().decode(MSPAgentJSONValue.self, from: data)
        return uiProjection(from: snapshot)
    }

    static func currentSourceFingerprint(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> String? {
        let manifestURL = packageURL
            .standardizedFileURL
            .appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            return nil
        }
        let timeline = object["timeline"] as? [String: Any]
        let timelinePath = timeline?["path"] as? String ?? defaultChatTimelinePath
        guard let timelineNextSeq = manifestTimelineNextSeq(from: timeline?["next_seq"]),
              timelineNextSeq > 0 else {
            return nil
        }
        return "timeline:\(timelinePath):next_seq:\(timelineNextSeq)"
    }

    private static func manifestTimelineNextSeq(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    static func readCurrentUIProjection(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) -> UIProjection? {
        guard let sourceFingerprint = try? currentSourceFingerprint(
            from: packageURL,
            fileManager: fileManager
        ) else {
            return nil
        }
        if let projection = try? readUIProjection(from: packageURL, fileManager: fileManager),
           !projection.items.isEmpty,
           projection.projectionVersion == uiProjectionVersion,
           projection.sourceFingerprint == sourceFingerprint,
           projection.totalItemCount == projection.items.count {
            return projection
        }
        return nil
    }

    static func validateChatPackageEnvelopeForProjectionOpen(
        at packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let packageURL = packageURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ChatPackageEnvelopeError.packageNotDirectory(packageURL.path)
        }

        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ChatPackageEnvelopeError.missingManifest(manifestURL.path)
        }

        let timelinePath = try chatTimelinePath(fromManifestAt: manifestURL)
        let timelineURL = packageURL.appendingPathComponent(timelinePath)
        guard fileManager.fileExists(atPath: timelineURL.path) else {
            throw ChatPackageEnvelopeError.missingTimeline(timelineURL.path)
        }
    }

    static func chatTimelinePath(fromManifestAt manifestURL: URL) throws -> String {
        let data = try Data(contentsOf: manifestURL)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw ChatPackageEnvelopeError.invalidManifest("manifest root must be an object")
        }
        let timeline = object["timeline"] as? [String: Any]
        let path = timeline?["path"] as? String ?? defaultChatTimelinePath
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw ChatPackageEnvelopeError.unsafeTimelinePath(path)
        }
        return path
    }

    private static func fallbackTitleStem() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }
}

private extension MSPAgentTimelineItem.Kind {
    var chatPersistenceName: String {
        switch self {
        case .system:
            return "system"
        case .user:
            return "user"
        case .assistantProgress:
            return "assistantProgress"
        case .toolCall:
            return "toolCall"
        case .toolResult:
            return "toolResult"
        case .assistantFinal:
            return "assistantFinal"
        case .stoppedMarker:
            return "stoppedMarker"
        case .error:
            return "error"
        }
    }

    init?(chatPersistenceName: String) {
        switch chatPersistenceName {
        case "system":
            self = .system
        case "user":
            self = .user
        case "assistantProgress":
            self = .assistantProgress
        case "toolCall":
            self = .toolCall
        case "toolResult":
            self = .toolResult
        case "assistantFinal":
            self = .assistantFinal
        case "stoppedMarker":
            self = .stoppedMarker
        case "error":
            self = .error
        default:
            return nil
        }
    }
}

private extension MSPAgentTimelineItem {
    var agentChatJSONValue: MSPAgentJSONValue {
        .object([
            "id": .string(id.uuidString),
            "kind": .string(kind.chatPersistenceName),
            "title": .string(title),
            "body": .string(body),
            "detail": detail.chatJSONValue,
            "call_id": callID.chatJSONValue,
            "batch_id": batchID.map { .string($0.uuidString) } ?? .null,
            "tool_name": toolName.chatJSONValue,
            "command": command.chatJSONValue,
            "cwd": cwd.chatJSONValue,
            "stdout": stdout.chatJSONValue,
            "stderr": stderr.chatJSONValue,
            "exit_code": exitCode.chatJSONValue,
            "exec_session_id": execSessionID.chatJSONValue,
            "parent_call_id": parentCallID.chatJSONValue,
            "status": status.chatJSONValue,
            "started_at_ms": startedAtMilliseconds.chatJSONValue,
            "completed_at_ms": completedAtMilliseconds.chatJSONValue,
            "duration_ms": durationMilliseconds.chatJSONValue,
            "turn_started_at_ms": turnStartedAtMilliseconds.chatJSONValue,
            "turn_duration_ms": turnDurationMilliseconds.chatJSONValue,
            "images": .array(images.map(\.agentChatJSONValue)),
            "source_text_selections": .array(sourceTextSelections.map(\.agentChatJSONValue))
        ])
    }

    init?(agentChatJSONValue value: MSPAgentJSONValue) {
        guard let object = value.objectValue,
              let kindName = object["kind"]?.stringValue,
              let kind = Kind(chatPersistenceName: kindName) else {
            return nil
        }
        self.init(
            id: object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(),
            kind: kind,
            title: object["title"]?.stringValue ?? "",
            body: object["body"]?.stringValue ?? "",
            detail: object["detail"]?.stringValue,
            callID: object["call_id"]?.stringValue,
            batchID: object["batch_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            toolName: object["tool_name"]?.stringValue,
            command: object["command"]?.stringValue,
            cwd: object["cwd"]?.stringValue,
            stdout: object["stdout"]?.stringValue,
            stderr: object["stderr"]?.stringValue,
            exitCode: object["exit_code"]?.intValue,
            execSessionID: object["exec_session_id"]?.intValue,
            parentCallID: object["parent_call_id"]?.stringValue,
            status: object["status"]?.stringValue,
            startedAtMilliseconds: object["started_at_ms"]?.intValue,
            completedAtMilliseconds: object["completed_at_ms"]?.intValue,
            durationMilliseconds: object["duration_ms"]?.intValue,
            turnStartedAtMilliseconds: object["turn_started_at_ms"]?.intValue,
            turnDurationMilliseconds: object["turn_duration_ms"]?.intValue,
            images: object["images"]?.arrayValue?.compactMap(MSPAgentTimelineImage.init(agentChatJSONValue:)) ?? [],
            sourceTextSelections: object["source_text_selections"]?.arrayValue?.compactMap(PhotoSorterTextSelectionSnapshot.init(agentChatJSONValue:)) ?? []
        )
    }
}

private extension MSPAgentTimelineImage {
    var agentChatJSONValue: MSPAgentJSONValue {
        .object([
            "id": .string(id.uuidString),
            "base64": .string(base64),
            "mime_type": mimeType.chatJSONValue
        ])
    }

    init?(agentChatJSONValue value: MSPAgentJSONValue) {
        guard let object = value.objectValue,
              let base64 = object["base64"]?.stringValue else {
            return nil
        }
        self.init(
            id: object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(),
            base64: base64,
            mimeType: object["mime_type"]?.stringValue
        )
    }
}

private extension PhotoSorterTextSelectionSnapshot {
    var agentChatJSONValue: MSPAgentJSONValue {
        .object([
            "id": .string(id.uuidString),
            "selected_text": .string(selectedText),
            "source_kind": .string(sourceKind),
            "source_display_name": .string(sourceDisplayName),
            "source_message_id": sourceMessageID.chatJSONValue,
            "source_message_role": sourceMessageRole.chatJSONValue,
            "selected_text_occurrence_index_in_message": selectedTextOccurrenceIndexInMessage.chatJSONValue,
            "rendered_text_segments": .array(renderedTextSegments.map(MSPAgentJSONValue.string))
        ])
    }

    init?(agentChatJSONValue value: MSPAgentJSONValue) {
        guard let object = value.objectValue,
              let selectedText = object["selected_text"]?.stringValue else {
            return nil
        }
        self.init(
            id: object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(),
            selectedText: selectedText,
            sourceKind: object["source_kind"]?.stringValue ?? "conversation",
            sourceDisplayName: object["source_display_name"]?.stringValue ?? "对话摘录",
            sourceMessageID: object["source_message_id"]?.stringValue,
            sourceMessageRole: object["source_message_role"]?.stringValue,
            selectedTextOccurrenceIndexInMessage: object["selected_text_occurrence_index_in_message"]?.intValue,
            renderedTextSegments: object["rendered_text_segments"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

private extension Optional where Wrapped == String {
    var chatJSONValue: MSPAgentJSONValue {
        map(MSPAgentJSONValue.string) ?? .null
    }
}

private extension Optional where Wrapped == Int {
    var chatJSONValue: MSPAgentJSONValue {
        map { .number(Double($0)) } ?? .null
    }
}
