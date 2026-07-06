import Foundation
import MSPChat

struct MSPChatReadProjection: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var conversation: Conversation
    var page: Page
    var turns: [Turn]

    struct Conversation: Codable, Equatable, Sendable {
        var id: String
        var hostId: String?
        var title: String
        var preview: String
        var status: ConversationStatus
        var path: String
        var cwd: String?
        var createdAt: Int?
        var updatedAt: Int?
    }

    struct ConversationStatus: Codable, Equatable, Sendable {
        var type: String
        var activeFlags: [String]
    }

    struct Page: Codable, Equatable, Sendable {
        var order: String
        var scope: MSPChatReadOptions.Scope
        var cursor: String?
        var limit: Int
        var nextCursor: String?
        var hasMore: Bool
        var itemsView: String
        var includeOutputs: Bool
        var maxOutputCharsPerItem: Int?
    }

    struct Turn: Codable, Equatable, Sendable {
        var id: String
        var status: String
        var error: TurnError?
        var startedAt: Int?
        var completedAt: Int?
        var durationMs: Int?
        var itemsView: String
        var items: [Item]
    }

    struct TurnError: Codable, Equatable, Sendable {
        var message: String
        var code: String?
        var additionalDetails: String?
    }

    struct Item: Codable, Equatable, Sendable {
        var type: String
        var id: String
        var seq: Int
        var createdAt: String
        var text: String?
        var phase: String?
        var content: [Content]
        var attachments: [Attachment]
        var toolCall: ToolCall?
        var toolResult: ToolResult?
        var event: Event?
        var artifact: Attachment?
        var sourceEventType: String

        static func userMessage(event: MSPChatTimelineEvent, text: String, attachments: [Attachment]) -> Item {
            Item(
                type: "userMessage",
                id: event.id,
                seq: event.seq,
                createdAt: event.createdAt,
                text: text,
                phase: nil,
                content: [.text(text)],
                attachments: attachments,
                toolCall: nil,
                toolResult: nil,
                event: nil,
                artifact: nil,
                sourceEventType: event.type
            )
        }

        static func agentMessage(event: MSPChatTimelineEvent, text: String, phase: String?) -> Item {
            Item(
                type: "agentMessage",
                id: event.id,
                seq: event.seq,
                createdAt: event.createdAt,
                text: text,
                phase: phase,
                content: [],
                attachments: [],
                toolCall: nil,
                toolResult: nil,
                event: nil,
                artifact: nil,
                sourceEventType: event.type
            )
        }

        static func toolCall(
            event: MSPChatTimelineEvent,
            type: String = "toolCall",
            _ call: ToolCall
        ) -> Item {
            Item(
                type: type,
                id: event.id,
                seq: event.seq,
                createdAt: event.createdAt,
                text: nil,
                phase: nil,
                content: [],
                attachments: [],
                toolCall: call,
                toolResult: nil,
                event: nil,
                artifact: nil,
                sourceEventType: event.type
            )
        }

        static func toolResult(
            event: MSPChatTimelineEvent,
            type: String = "toolResult",
            _ result: ToolResult
        ) -> Item {
            Item(
                type: type,
                id: event.id,
                seq: event.seq,
                createdAt: event.createdAt,
                text: nil,
                phase: nil,
                content: [],
                attachments: [],
                toolCall: nil,
                toolResult: result,
                event: nil,
                artifact: nil,
                sourceEventType: event.type
            )
        }

        static func error(source: MSPChatTimelineEvent, _ event: Event) -> Item {
            Item(
                type: "error",
                id: source.id,
                seq: source.seq,
                createdAt: source.createdAt,
                text: nil,
                phase: nil,
                content: [],
                attachments: [],
                toolCall: nil,
                toolResult: nil,
                event: event,
                artifact: nil,
                sourceEventType: source.type
            )
        }

        static func event(source: MSPChatTimelineEvent, _ event: Event) -> Item {
            Item(
                type: "event",
                id: source.id,
                seq: source.seq,
                createdAt: source.createdAt,
                text: nil,
                phase: nil,
                content: [],
                attachments: [],
                toolCall: nil,
                toolResult: nil,
                event: event,
                artifact: nil,
                sourceEventType: source.type
            )
        }

        static func artifact(event: MSPChatTimelineEvent, _ artifact: Attachment) -> Item {
            Item(
                type: "artifact",
                id: event.id,
                seq: event.seq,
                createdAt: event.createdAt,
                text: nil,
                phase: nil,
                content: [],
                attachments: [],
                toolCall: nil,
                toolResult: nil,
                event: nil,
                artifact: artifact,
                sourceEventType: event.type
            )
        }
    }

    struct Content: Codable, Equatable, Sendable {
        var type: String
        var text: String?

        static func text(_ text: String) -> Content {
            Content(type: "text", text: text)
        }
    }

    struct Attachment: Codable, Equatable, Sendable {
        var displayName: String
        var mimeType: String?
        var pageNumbers: [Int]
        var localPath: String?
    }

    struct ToolCall: Codable, Equatable, Sendable {
        var callID: String?
        var name: String
        var kind: String
        var server: String?
        var arguments: MSPChatJSONValue?
    }

    struct ToolResult: Codable, Equatable, Sendable {
        var status: String
        var success: Bool
        var output: String?
        var outputTruncated: Bool?
        var originalOutputCharCount: Int?
        var exitCode: Int?
        var durationMilliseconds: Int?
        var payload: MSPChatJSONValue?
        var stream: String?
        var images: [Image]
    }

    struct Image: Codable, Equatable, Sendable {
        var filePath: String?
        var url: String?
    }

    struct Event: Codable, Equatable, Sendable {
        var type: String
        var text: String?
        var payload: MSPChatJSONValue?
        var lossy: Bool?
    }
}

enum MSPChatReadProjectionError: Error, Equatable {
    case invalidCursor(String)
}

enum MSPChatReadProjector {
    static func project(
        _ package: MSPChatPackage,
        displayPath: String,
        options: MSPChatReadOptions
    ) throws -> MSPChatReadProjection {
        let events = package.timelineEvents.sorted { lhs, rhs in
            if lhs.seq != rhs.seq {
                return lhs.seq < rhs.seq
            }
            return lhs.id < rhs.id
        }
        let turns = buildTurns(from: events, options: options)

        let selectedRange: Range<Int>
        let nextCursor: String?
        let limit: Int
        let scope = try MSPChatReadCursor.scope(from: options.cursor) ?? options.scope
        switch scope {
        case .full:
            let startIndex = try MSPChatReadCursor.fullStartIndex(
                from: options.cursor,
                turns: turns
            )
            limit = options.turnLimit ?? turns.count
            let endIndex = min(turns.count, startIndex + limit)
            selectedRange = startIndex ..< endIndex
            nextCursor = endIndex < turns.count
                ? MSPChatReadCursor.encodeFull(afterTurnID: turns[endIndex - 1].id)
                : nil
        case .recent:
            let endIndex = try MSPChatReadCursor.recentEndIndex(
                from: options.cursor,
                turns: turns
            )
            limit = options.turnLimit ?? MSPChatReadOptions.defaultRecentTurnLimit
            let startIndex = max(0, endIndex - limit)
            selectedRange = startIndex ..< endIndex
            nextCursor = startIndex > 0
                ? MSPChatReadCursor.encodeRecent(beforeTurnID: turns[startIndex].id)
                : nil
        }

        let selectedTurns = selectedRange.map { turns[$0] }
        let hasRunningTurn = turns.contains { $0.status == "inProgress" }
        return MSPChatReadProjection(
            schemaVersion: 1,
            conversation: .init(
                id: package.manifest.packageID ?? package.packageURL.lastPathComponent,
                hostId: nil,
                title: title(from: package.manifest),
                preview: preview(from: turns),
                status: .init(
                    type: hasRunningTurn ? "active" : "notLoaded",
                    activeFlags: hasRunningTurn ? ["turnInProgress"] : []
                ),
                path: displayPath,
                cwd: string(package.manifest.rawJSON, keys: ["cwd", "working_directory", "workingDirectory"]),
                createdAt: events.first.flatMap { unixSeconds(from: $0.createdAt) },
                updatedAt: events.last.flatMap { unixSeconds(from: $0.createdAt) }
            ),
            page: .init(
                order: "oldest_first",
                scope: scope,
                cursor: options.cursor,
                limit: limit,
                nextCursor: nextCursor,
                hasMore: nextCursor != nil,
                itemsView: "full",
                includeOutputs: options.includeOutputs,
                maxOutputCharsPerItem: options.maxOutputCharsPerItem
            ),
            turns: selectedTurns
        )
    }

    private static func buildTurns(
        from events: [MSPChatTimelineEvent],
        options: MSPChatReadOptions
    ) -> [MSPChatReadProjection.Turn] {
        var builders: [TurnBuilder] = []

        for event in events {
            let key = groupingKey(for: event, builders: builders)
            if builders.last?.key != key {
                builders.append(TurnBuilder(
                    key: key,
                    id: event.turnID ?? key,
                    status: "completed",
                    error: nil,
                    startedAt: event.createdAt,
                    completedAt: nil,
                    lastEventAt: event.createdAt,
                    items: []
                ))
            }
            builders[builders.count - 1].lastEventAt = event.createdAt
            builders[builders.count - 1].status = status(for: event, current: builders[builders.count - 1].status)
            if event.type == "turn_started" {
                builders[builders.count - 1].startedAt = event.createdAt
            }
            if event.type == "turn_completed" {
                builders[builders.count - 1].completedAt = event.createdAt
            }
            if event.type == "error" {
                builders[builders.count - 1].error = turnError(from: event)
            }
            builders[builders.count - 1].items.append(projectedItem(for: event, options: options))
        }

        return builders.map { builder in
            let completedAt = builder.completedAt
                ?? ((builder.status == "completed" || builder.status == "failed")
                    ? builder.lastEventAt
                    : nil)
            return MSPChatReadProjection.Turn(
                id: builder.id,
                status: builder.status,
                error: builder.error,
                startedAt: builder.startedAt.flatMap(unixSeconds(from:)),
                completedAt: completedAt.flatMap(unixSeconds(from:)),
                durationMs: durationMilliseconds(startedAt: builder.startedAt, completedAt: completedAt),
                itemsView: "full",
                items: builder.items
            )
        }
    }

    private static func groupingKey(
        for event: MSPChatTimelineEvent,
        builders: [TurnBuilder]
    ) -> String {
        if let turnID = event.turnID {
            return "turn:\(turnID)"
        }
        if let commandID = string(event.payload, keys: ["command_id", "commandID"]) {
            return "command:\(commandID)"
        }
        if let callID = event.callID ?? string(event.payload, keys: ["call_id", "callID"]) {
            return "tool:\(callID)"
        }
        if event.type == "message",
           string(event.payload, keys: ["role"]) == "user" {
            return "implicit:\(event.seq)"
        }
        if let last = builders.last,
           last.key.hasPrefix("implicit:") {
            return last.key
        }
        return "__event_\(event.seq)"
    }

    private static func status(
        for event: MSPChatTimelineEvent,
        current: String
    ) -> String {
        if event.type == "turn_completed" {
            return "completed"
        }
        if event.type == "turn_started" {
            return "inProgress"
        }
        if event.type == "error" {
            return "failed"
        }
        return current
    }

    private static func projectedItem(
        for event: MSPChatTimelineEvent,
        options: MSPChatReadOptions
    ) -> MSPChatReadProjection.Item {
        switch event.type {
        case "message":
            let role = string(event.payload, keys: ["role"]) ?? event.actor ?? ""
            let text = string(event.payload, keys: ["content", "text", "message"]) ?? ""
            if role == "user" {
                return .userMessage(event: event, text: text, attachments: attachments(from: event.payload))
            }
            if role == "assistant" || event.actor == "assistant" {
                return .agentMessage(
                    event: event,
                    text: text,
                    phase: string(event.payload, keys: ["phase"])
                )
            }
            return .event(source: event, .init(
                type: event.type,
                text: text.isEmpty ? "role=\(role)" : text,
                payload: .object(event.payload),
                lossy: bool(event.payload, keys: ["lossy"])
            ))

        case "tool_call":
            return .toolCall(event: event, .init(
                callID: event.callID ?? string(event.payload, keys: ["call_id", "callID"]),
                name: string(event.payload, keys: ["tool_name", "name", "tool"]) ?? "tool",
                kind: string(event.payload, keys: ["kind"]) ?? "tool",
                server: string(event.payload, keys: ["server"]),
                arguments: value(event.payload, keys: ["input", "arguments", "args"])
            ))

        case "tool_output":
            return .toolResult(event: event, toolResult(
                payload: event.payload,
                successDefault: bool(event.payload, keys: ["success"]) ?? true,
                outputKeys: ["output", "text", "stdout"],
                includeStream: nil,
                options: options
            ))

        case "command_call":
            let rawCommand = string(event.payload, keys: ["raw_command", "command", "cmd"]) ?? ""
            return .toolCall(event: event, type: "commandExecution", .init(
                callID: string(event.payload, keys: ["command_id", "commandID"]),
                name: "msp.command",
                kind: "command",
                server: nil,
                arguments: .object(["cmd": .string(rawCommand)])
            ))

        case "command_output", "command_stage_output":
            return .toolResult(event: event, type: "commandOutput", toolResult(
                payload: event.payload,
                successDefault: true,
                outputKeys: ["text", "output"],
                includeStream: string(event.payload, keys: ["stream"]),
                options: options
            ))

        case "command_complete", "command_cancelled", "command_timeout":
            let exitCode = int(event.payload, keys: ["exit_status", "exitCode", "exit_code"])
            let failed = (exitCode ?? 0) != 0
                || bool(event.payload, keys: ["cancelled"]) == true
                || bool(event.payload, keys: ["timeout"]) == true
                || bool(event.payload, keys: ["permission_denied"]) == true
                || event.type != "command_complete"
            return .toolResult(event: event, type: "commandExecution", .init(
                status: failed ? "failed" : "completed",
                success: !failed,
                output: nil,
                outputTruncated: nil,
                originalOutputCharCount: nil,
                exitCode: exitCode,
                durationMilliseconds: int(event.payload, keys: ["duration_ms", "durationMilliseconds"]),
                payload: nil,
                stream: nil,
                images: []
            ))

        case "artifact_ref":
            return .artifact(event: event, attachment(fromArtifact: event.payload))

        case "error":
            let message = string(event.payload, keys: ["message", "error"]) ?? ""
            let code = string(event.payload, keys: ["code"])
            return .error(source: event, .init(
                type: event.type,
                text: [code, message].compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }.joined(separator: ": "),
                payload: .object(event.payload),
                lossy: bool(event.payload, keys: ["lossy"])
            ))

        default:
            return .event(source: event, .init(
                type: event.type,
                text: nil,
                payload: .object(event.payload),
                lossy: bool(event.payload, keys: ["lossy"])
            ))
        }
    }

    private static func toolResult(
        payload: [String: MSPChatJSONValue],
        successDefault: Bool,
        outputKeys: [String],
        includeStream: String?,
        options: MSPChatReadOptions
    ) -> MSPChatReadProjection.ToolResult {
        let output = string(payload, keys: outputKeys)
        let truncated = truncated(output, limit: options.maxOutputCharsPerItem)
        let success = bool(payload, keys: ["success"]) ?? successDefault
        return MSPChatReadProjection.ToolResult(
            status: success ? "completed" : "failed",
            success: success,
            output: options.includeOutputs ? truncated?.text : nil,
            outputTruncated: options.includeOutputs && truncated?.truncated == true ? true : nil,
            originalOutputCharCount: options.includeOutputs && truncated?.truncated == true ? truncated?.originalCharCount : nil,
            exitCode: int(payload, keys: ["exit_code", "exitCode", "exit_status"]),
            durationMilliseconds: int(payload, keys: ["duration_ms", "durationMilliseconds"]),
            payload: options.includeOutputs ? value(payload, keys: ["payload", "result"]) : nil,
            stream: includeStream,
            images: images(from: payload)
        )
    }

    private static func title(from manifest: MSPChatManifest) -> String {
        string(manifest.rawJSON, keys: ["title", "display_title", "name"]) ?? ""
    }

    private static func preview(from turns: [MSPChatReadProjection.Turn]) -> String {
        for turn in turns {
            for item in turn.items where item.type == "userMessage" {
                let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    private static func turnError(from event: MSPChatTimelineEvent) -> MSPChatReadProjection.TurnError {
        MSPChatReadProjection.TurnError(
            message: string(event.payload, keys: ["message", "error"]) ?? "Turn failed.",
            code: string(event.payload, keys: ["code"]),
            additionalDetails: string(event.payload, keys: ["details", "additional_details", "additionalDetails"])
        )
    }

    private static func attachments(
        from payload: [String: MSPChatJSONValue]
    ) -> [MSPChatReadProjection.Attachment] {
        let attachmentValues = payload["attachments"]?.arrayValue ?? []
        let attachments = attachmentValues.compactMap { value -> MSPChatReadProjection.Attachment? in
            guard let object = value.objectValue else { return nil }
            return attachment(fromArtifact: object)
        }

        let artifactValues = payload["artifact_refs"]?.arrayValue ?? []
        let artifacts = artifactValues.compactMap { value -> MSPChatReadProjection.Attachment? in
            guard let object = value.objectValue else { return nil }
            return attachment(fromArtifact: object)
        }

        return attachments + artifacts
    }

    private static func attachment(
        fromArtifact payload: [String: MSPChatJSONValue]
    ) -> MSPChatReadProjection.Attachment {
        MSPChatReadProjection.Attachment(
            displayName: string(payload, keys: ["display_name", "displayName", "name", "artifact_id", "blob_id"]) ?? "附件",
            mimeType: string(payload, keys: ["mime_type", "mimeType", "media_type"]),
            pageNumbers: intArray(payload, keys: ["page_numbers", "pageNumbers"]),
            localPath: string(payload, keys: ["path", "local_path", "localPath", "url"])
        )
    }

    private static func images(
        from payload: [String: MSPChatJSONValue]
    ) -> [MSPChatReadProjection.Image] {
        guard let images = payload["images"]?.arrayValue else {
            return []
        }
        return images.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return MSPChatReadProjection.Image(
                filePath: string(object, keys: ["file_path", "filePath", "path"]),
                url: string(object, keys: ["url"])
            )
        }
    }

    private static func truncated(
        _ output: String?,
        limit: Int?
    ) -> (text: String, truncated: Bool, originalCharCount: Int)? {
        guard let output else {
            return nil
        }
        guard let limit, output.count > limit else {
            return (output, false, output.count)
        }
        return (String(output.prefix(limit)), true, output.count)
    }

    private static func string(
        _ object: [String: MSPChatJSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private static func value(
        _ object: [String: MSPChatJSONValue],
        keys: [String]
    ) -> MSPChatJSONValue? {
        for key in keys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static func int(
        _ object: [String: MSPChatJSONValue],
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = object[key]?.intValue {
                return value
            }
        }
        return nil
    }

    private static func bool(
        _ object: [String: MSPChatJSONValue],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            if let value = object[key]?.boolValue {
                return value
            }
        }
        return nil
    }

    private static func intArray(
        _ object: [String: MSPChatJSONValue],
        keys: [String]
    ) -> [Int] {
        for key in keys {
            if let array = object[key]?.arrayValue {
                return array.compactMap(\.intValue)
            }
        }
        return []
    }

    private static func unixSeconds(from timestamp: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            return Int(date.timeIntervalSince1970)
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    private static func durationMilliseconds(startedAt: String?, completedAt: String?) -> Int? {
        guard let startedAt,
              let completedAt,
              let startedSeconds = unixSeconds(from: startedAt),
              let completedSeconds = unixSeconds(from: completedAt),
              completedSeconds >= startedSeconds else {
            return nil
        }
        return (completedSeconds - startedSeconds) * 1_000
    }
}

private struct TurnBuilder {
    var key: String
    var id: String
    var status: String
    var error: MSPChatReadProjection.TurnError?
    var startedAt: String?
    var completedAt: String?
    var lastEventAt: String
    var items: [MSPChatReadProjection.Item]
}

private enum MSPChatReadCursor {
    private static let fullAfterPrefix = "full-after:"
    private static let legacyFullPrefix = "full:"
    private static let recentPrefix = "recent-before:"

    static func encodeFull(afterTurnID turnID: String) -> String {
        fullAfterPrefix + turnID
    }

    static func encodeRecent(beforeTurnID turnID: String) -> String {
        recentPrefix + turnID
    }

    static func fullStartIndex(from cursor: String?, turns: [MSPChatReadProjection.Turn]) throws -> Int {
        guard let cursor, !cursor.isEmpty else { return 0 }
        if cursor.hasPrefix(fullAfterPrefix) {
            let anchor = String(cursor.dropFirst(fullAfterPrefix.count))
            guard let index = turns.firstIndex(where: { $0.id == anchor }) else {
                throw MSPChatReadProjectionError.invalidCursor(cursor)
            }
            return index + 1
        }
        if cursor.hasPrefix(legacyFullPrefix),
           let index = Int(cursor.dropFirst(legacyFullPrefix.count)),
           index >= 0,
           index <= turns.count {
            return index
        }
        throw MSPChatReadProjectionError.invalidCursor(cursor)
    }

    static func recentEndIndex(from cursor: String?, turns: [MSPChatReadProjection.Turn]) throws -> Int {
        guard let cursor, !cursor.isEmpty else { return turns.count }
        guard cursor.hasPrefix(recentPrefix) else {
            throw MSPChatReadProjectionError.invalidCursor(cursor)
        }
        let anchor = String(cursor.dropFirst(recentPrefix.count))
        if let legacyIndex = Int(anchor), legacyIndex >= 0, legacyIndex <= turns.count {
            return legacyIndex
        }
        guard let index = turns.firstIndex(where: { $0.id == anchor }) else {
            throw MSPChatReadProjectionError.invalidCursor(cursor)
        }
        return index
    }

    static func scope(from cursor: String?) throws -> MSPChatReadOptions.Scope? {
        guard let cursor, !cursor.isEmpty else {
            return nil
        }
        if cursor.hasPrefix(fullAfterPrefix) || cursor.hasPrefix(legacyFullPrefix) {
            return .full
        }
        if cursor.hasPrefix(recentPrefix) {
            return .recent
        }
        throw MSPChatReadProjectionError.invalidCursor(cursor)
    }
}
