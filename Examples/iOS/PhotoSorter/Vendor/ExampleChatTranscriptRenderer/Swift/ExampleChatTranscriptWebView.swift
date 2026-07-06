import Foundation
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class ExampleChatTranscriptExportController: ObservableObject {
    enum ExportError: LocalizedError {
        case webViewUnavailable
        case invalidDocumentSize

        var errorDescription: String? {
            switch self {
            case .webViewUnavailable:
                return "聊天内容还没有准备好。"
            case .invalidDocumentSize:
                return "无法读取当前聊天内容尺寸。"
            }
        }
    }

    private weak var webView: WKWebView?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func exportFullTranscriptPDF() async throws -> URL {
        guard let webView else {
            throw ExportError.webViewUnavailable
        }

        let contentSize = try await webView.chatFullDocumentContentSize()
        let captureWidth = max(contentSize.width, webView.bounds.width, 1)
        let captureHeight = max(contentSize.height, webView.bounds.height, 1)
        guard captureWidth.isFinite,
              captureHeight.isFinite,
              captureWidth > 0,
              captureHeight > 0 else {
            throw ExportError.invalidDocumentSize
        }

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0,
            y: 0,
            width: captureWidth.rounded(.up),
            height: captureHeight.rounded(.up)
        )
        if #available(iOS 17.0, macOS 14.0, *) {
            configuration.allowTransparentBackground = false
        }

        let pdfData = try await webView.pdf(configuration: configuration)
        let exportURL = Self.temporaryExportURL()
        try pdfData.write(to: exportURL, options: .atomic)
        return exportURL
    }

    private static func temporaryExportURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Chat-Transcript-\(timestamp).pdf", isDirectory: false)
    }
}

struct ExampleChatTranscriptRenderState {
    var payload: [String: Any]
    var imageCacheEntries: [ExampleChatTranscriptImageCacheEntry] = []
    var presentation: [String: Any]
    var isGenerating: Bool = false

    static let empty = ExampleChatTranscriptRenderState(
        payload: ExampleChatTranscriptPayloadFactory.payload(from: []),
        imageCacheEntries: [],
        presentation: ExampleChatTranscriptPayloadFactory.presentation(isGenerating: false),
        isGenerating: false
    )
}

struct ExampleChatTranscriptRenderSnapshot {
    var state: ExampleChatTranscriptRenderState?
    var stateRevision: Int?
    var streamingUpdate: ExampleChatTranscriptStreamingMarkdownUpdateBatch?
    var streamingUpdateRevision: Int
}

extension Notification.Name {
    static let chatTranscriptStreamTraceDiagnostic = Notification.Name(
        "ExampleChatTranscriptStreamTraceDiagnostic"
    )
}

private enum ExampleChatTranscriptStreamTrace {
    static func log(_ event: String, fields: [String: Any?] = [:]) {
        guard enabled else {
            return
        }
        var allFields = fields
        allFields["t_ms"] = String(format: "%.3f", nowMilliseconds())
        let lineFields = allFields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(token($0.value))" }
            .joined(separator: " ")
        print("PST_STREAM_TRACE \(event)\(lineFields.isEmpty ? "" : " \(lineFields)")")
        NotificationCenter.default.post(
            name: .chatTranscriptStreamTraceDiagnostic,
            object: nil,
            userInfo: [
                "event": event,
                "fields": allFields.reduce(into: [String: String]()) { result, entry in
                    result[entry.key] = token(entry.value)
                }
            ]
        )
    }

    static var enabled: Bool {
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--photosorter-stream-trace")
            || process.environment["PHOTOSORTER_STREAM_TRACE"] == "1"
            || process.environment["SIMCTL_CHILD_PHOTOSORTER_STREAM_TRACE"] == "1"
    }

    static func nowMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }

    static func elapsedMilliseconds(since start: Double) -> String {
        String(format: "%.3f", max(0, nowMilliseconds() - start))
    }

    private static func token(_ value: Any?) -> String {
        switch value {
        case nil:
            return "nil"
        case is NSNull:
            return "null"
        case let value as String:
            return sanitized(value)
        case let value as NSNumber:
            return sanitized(value.stringValue)
        case let value as Bool:
            return value ? "true" : "false"
        case let value as Int:
            return "\(value)"
        case let value as Double:
            return "\(value)"
        default:
            return sanitized(String(describing: value ?? "nil"))
        }
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: " ", with: "_")
    }
}

@MainActor
final class ExampleChatTranscriptRenderController: ObservableObject {
    @Published private(set) var snapshot: ExampleChatTranscriptRenderSnapshot

    private(set) var currentState: ExampleChatTranscriptRenderState
    private var stateRevision = 0
    private var streamingUpdateRevision = 0
    private var cachedToolTargetsByCallID: [String: StreamingToolTarget] = [:]

    init(state: ExampleChatTranscriptRenderState = .empty) {
        currentState = state
        snapshot = ExampleChatTranscriptRenderSnapshot(
            state: state,
            stateRevision: stateRevision,
            streamingUpdate: nil,
            streamingUpdateRevision: streamingUpdateRevision
        )
    }

    func replaceState(_ state: ExampleChatTranscriptRenderState) {
        currentState = state
        cachedToolTargetsByCallID.removeAll(keepingCapacity: true)
        stateRevision += 1
        snapshot = ExampleChatTranscriptRenderSnapshot(
            state: state,
            stateRevision: stateRevision,
            streamingUpdate: nil,
            streamingUpdateRevision: streamingUpdateRevision
        )
    }

    func applyStreamingToolActivity(
        callID: String,
        fallbackTargetIDs: [String] = [],
        supportBlock: [String: Any]
    ) -> Bool {
        guard let target = toolTarget(
            callID: callID,
            fallbackTargetIDs: fallbackTargetIDs
        ) else {
            return false
        }
        let update = ExampleChatTranscriptStreamingMarkdownUpdateBatch.toolActivityUpdate(
            message: target.message,
            messageIndex: target.messageIndex,
            supportBlock: supportBlock,
            supportBlockIndex: target.supportBlockIndex
        )
        publishStreamingUpdate(update)
        return true
    }

    func applyStreamingMainText(
        messageID: String,
        text: String,
        previousTextLength: Int,
        appendText: String
    ) -> Bool {
        let startedAtMilliseconds = ExampleChatTranscriptStreamTrace.nowMilliseconds()
        guard let target = mainTextTarget(messageID: messageID) else {
            ExampleChatTranscriptStreamTrace.log("render_controller.apply_main_text_target_miss", fields: [
                "message_id": messageID,
                "previous_text_length": previousTextLength,
                "append_text_length": appendText.count,
                "text_length": text.count,
                "elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
            ])
            return false
        }
        let update = ExampleChatTranscriptStreamingMarkdownUpdateBatch.mainTextUpdate(
            message: target.message,
            messageIndex: target.messageIndex,
            text: text,
            previousTextLength: previousTextLength,
            appendText: appendText
        )
        ExampleChatTranscriptStreamTrace.log("render_controller.apply_main_text_target_hit", fields: [
            "message_id": messageID,
            "message_index": target.messageIndex,
            "previous_text_length": previousTextLength,
            "append_text_length": appendText.count,
            "text_length": text.count,
            "elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
        ])
        publishStreamingUpdate(update)
        return true
    }

    func applyStreamingProgressText(
        supportBlockID: String,
        text: String,
        previousTextLength: Int,
        appendText: String
    ) -> Bool {
        let startedAtMilliseconds = ExampleChatTranscriptStreamTrace.nowMilliseconds()
        guard let target = progressTarget(supportBlockID: supportBlockID) else {
            ExampleChatTranscriptStreamTrace.log("render_controller.apply_progress_text_target_miss", fields: [
                "support_block_id": supportBlockID,
                "previous_text_length": previousTextLength,
                "append_text_length": appendText.count,
                "text_length": text.count,
                "elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
            ])
            return false
        }

        var supportBlock = target.supportBlock
        supportBlock["text"] = text
        supportBlock["status"] = "streaming"
        let update = ExampleChatTranscriptStreamingMarkdownUpdateBatch.progressUpdate(
            message: target.message,
            messageIndex: target.messageIndex,
            supportBlock: supportBlock,
            supportBlockIndex: target.supportBlockIndex,
            text: text,
            previousTextLength: previousTextLength,
            appendText: appendText
        )
        ExampleChatTranscriptStreamTrace.log("render_controller.apply_progress_text_target_hit", fields: [
            "support_block_id": supportBlockID,
            "message_index": target.messageIndex,
            "support_block_index": target.supportBlockIndex,
            "previous_text_length": previousTextLength,
            "append_text_length": appendText.count,
            "text_length": text.count,
            "elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
        ])
        publishStreamingUpdate(update)
        return true
    }

    private func toolTarget(
        callID: String,
        fallbackTargetIDs: [String]
    ) -> StreamingToolTarget? {
        let targetIDs = ([callID] + fallbackTargetIDs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targetIDs.isEmpty else {
            return nil
        }
        for targetID in targetIDs {
            if let cachedTarget = cachedToolTargetsByCallID[targetID] {
                return cachedTarget
            }
        }
        guard let messages = currentState.payload["messages"] as? [[String: Any]] else {
            return nil
        }
        for messageIndex in messages.indices {
            let message = messages[messageIndex]
            guard let supportBlocks = message["supportBlocks"] as? [[String: Any]] else {
                continue
            }
            for supportBlockIndex in supportBlocks.indices {
                let supportBlock = supportBlocks[supportBlockIndex]
                guard Self.supportBlockKindIsToolCall(Self.stringValue(supportBlock["kind"])),
                      targetIDs.contains(where: { Self.supportBlock(supportBlock, containsCallID: $0) }) else {
                    continue
                }
                let target = StreamingToolTarget(
                    message: message,
                    messageIndex: messageIndex,
                    supportBlockIndex: supportBlockIndex
                )
                targetIDs.forEach { cachedToolTargetsByCallID[$0] = target }
                return target
            }
        }
        return nil
    }

    private func mainTextTarget(messageID: String) -> StreamingMainTextTarget? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              let messages = currentState.payload["messages"] as? [[String: Any]] else {
            return nil
        }
        let patchKey = "msp:\(normalizedMessageID)"
        for (messageIndex, message) in messages.enumerated() {
            if Self.stringValue(message["id"]) == normalizedMessageID
                || Self.stringValue(message["patchKey"]) == patchKey {
                return StreamingMainTextTarget(
                    message: message,
                    messageIndex: messageIndex
                )
            }
        }
        return nil
    }

    private func progressTarget(supportBlockID: String) -> StreamingProgressTarget? {
        let normalizedSupportBlockID = supportBlockID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSupportBlockID.isEmpty,
              let messages = currentState.payload["messages"] as? [[String: Any]] else {
            return nil
        }
        for (messageIndex, message) in messages.enumerated() {
            guard let supportBlocks = message["supportBlocks"] as? [[String: Any]] else {
                continue
            }
            for supportBlockIndex in supportBlocks.indices {
                let supportBlock = supportBlocks[supportBlockIndex]
                guard Self.supportBlockKindIsProgress(Self.stringValue(supportBlock["kind"])),
                      Self.stringValue(supportBlock["id"]) == normalizedSupportBlockID else {
                    continue
                }
                return StreamingProgressTarget(
                    message: message,
                    messageIndex: messageIndex,
                    supportBlock: supportBlock,
                    supportBlockIndex: supportBlockIndex
                )
            }
        }
        return nil
    }

    private func publishStreamingUpdate(
        _ update: ExampleChatTranscriptStreamingMarkdownUpdateBatch
    ) {
        guard !update.isEmpty else {
            return
        }
        streamingUpdateRevision += 1
        ExampleChatTranscriptStreamTrace.log("render_controller.publish_streaming_update", fields: [
            "revision": streamingUpdateRevision,
            "update_count": update.updates.count,
            "summary": update.traceSummary
        ])
        snapshot = ExampleChatTranscriptRenderSnapshot(
            state: nil,
            stateRevision: stateRevision,
            streamingUpdate: update,
            streamingUpdateRevision: streamingUpdateRevision
        )
    }

    private struct StreamingToolTarget {
        var message: [String: Any]
        var messageIndex: Int
        var supportBlockIndex: Int
    }

    private struct StreamingMainTextTarget {
        var message: [String: Any]
        var messageIndex: Int
    }

    private struct StreamingProgressTarget {
        var message: [String: Any]
        var messageIndex: Int
        var supportBlock: [String: Any]
        var supportBlockIndex: Int
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func supportBlockKindIsProgress(_ kind: String?) -> Bool {
        kind == "chat_progress" || kind == "readex_progress"
    }

    private static func supportBlockKindIsToolCall(_ kind: String?) -> Bool {
        kind == "chat_tool_call" || kind == "readex_tool_call"
    }

    private static func supportBlock(
        _ supportBlock: [String: Any],
        containsCallID callID: String
    ) -> Bool {
        if stringValue(supportBlock["id"]) == callID ||
            stringValue(supportBlock["callID"]) == callID ||
            stringValue(supportBlock["callId"]) == callID {
            return true
        }
        guard let items = supportBlock["items"] as? [[String: Any]] else {
            return false
        }
        return items.contains { item in
            stringValue(item["id"]) == callID ||
                stringValue(item["sourceBlockId"]) == callID ||
                stringValue(item["sourceBlockID"]) == callID ||
                stringValue(item["callID"]) == callID ||
                stringValue(item["callId"]) == callID ||
                nestedStringValue(item["commandExecution"], key: "callID") == callID ||
                nestedStringValue(item["commandExecution"], key: "callId") == callID
        }
    }

    private static func nestedStringValue(_ value: Any?, key: String) -> String? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        return stringValue(object[key])
    }
}

struct ExampleChatTranscriptStreamingMarkdownUpdateBatch {
    var updates: [[String: Any]]

    var isEmpty: Bool {
        updates.isEmpty
    }

    var payload: [String: Any] {
        ["updates": updates]
    }

    var traceSummary: String {
        updates.prefix(3).map { update in
            let kind = Self.stringValue(update["kind"]) ?? "unknown"
            let previousLength = Self.intValue(update["previousTextLength"]).map { "\($0)" } ?? "nil"
            let textLength = Self.stringValue(update["text"])?.count ?? 0
            let appendLength = Self.stringValue(update["appendText"])?.count ?? 0
            return "\(kind):prev\(previousLength):text\(textLength):append\(appendLength)"
        }.joined(separator: ",")
    }

    static func toolActivityUpdate(
        message: [String: Any],
        messageIndex: Int,
        supportBlock: [String: Any],
        supportBlockIndex: Int
    ) -> ExampleChatTranscriptStreamingMarkdownUpdateBatch {
        let blockID = toolActivityBlockID(
            message: message,
            supportBlockIndex: supportBlockIndex
        )
        let block = toolActivityBlock(
            id: blockID,
            supportBlock: supportBlock,
            supportBlockIndex: supportBlockIndex
        )
        return ExampleChatTranscriptStreamingMarkdownUpdateBatch(updates: [
            markdownUpdate(
                message: message,
                messageIndex: messageIndex,
                blockID: blockID,
                block: block,
                previousTextLength: 0,
                kind: "chat_tool_activity"
            )
        ])
    }

    static func mainTextUpdate(
        message: [String: Any],
        messageIndex: Int,
        text: String,
        previousTextLength: Int,
        appendText: String
    ) -> ExampleChatTranscriptStreamingMarkdownUpdateBatch {
        let blockID = runtimeScopedBlockID(
            message: message,
            localBlockID: "content"
        )
        let block = mainTextBlock(
            id: blockID,
            messageID: stringValue(message["id"]) ?? "",
            text: text
        )
        var update = markdownUpdate(
            message: message,
            messageIndex: messageIndex,
            blockID: blockID,
            block: block,
            previousTextLength: previousTextLength,
            kind: "main_text"
        )
        update["appendText"] = appendText
        update["messageState"] = [
            "status": "streaming"
        ]
        update["syncMessageChrome"] = true
        return ExampleChatTranscriptStreamingMarkdownUpdateBatch(updates: [update])
    }

    static func progressUpdate(
        message: [String: Any],
        messageIndex: Int,
        supportBlock: [String: Any],
        supportBlockIndex: Int,
        text: String,
        previousTextLength: Int,
        appendText: String
    ) -> ExampleChatTranscriptStreamingMarkdownUpdateBatch {
        let blockID = runtimeScopedBlockID(
            message: message,
            localBlockID: "chat_progress:\(supportBlockIndex)"
        )
        let block = progressBlock(
            id: blockID,
            supportBlock: supportBlock,
            text: text
        )
        var update = markdownUpdate(
            message: message,
            messageIndex: messageIndex,
            blockID: blockID,
            block: block,
            previousTextLength: previousTextLength,
            kind: "chat_progress"
        )
        update["appendText"] = appendText
        return ExampleChatTranscriptStreamingMarkdownUpdateBatch(updates: [update])
    }

    private static func markdownUpdate(
        message: [String: Any],
        messageIndex: Int,
        blockID: String,
        block: [String: Any],
        previousTextLength: Int,
        kind: String
    ) -> [String: Any] {
        let messageKey = stringValue(message["patchKey"])
            ?? stringValue(message["id"])
            ?? "__message_index_\(messageIndex)"
        var resolvedBlock = block
        resolvedBlock["id"] = blockID
        return [
            "kind": kind,
            "messageKey": messageKey,
            "messageID": stringValue(message["id"]) ?? NSNull(),
            "blockID": blockID,
            "block": resolvedBlock,
            "text": stringValue(resolvedBlock["text"]) ?? "",
            "previousTextLength": previousTextLength,
            "syncMessageChrome": false
        ]
    }

    private static func toolActivityBlockID(
        message: [String: Any],
        supportBlockIndex: Int
    ) -> String {
        runtimeScopedBlockID(
            message: message,
            localBlockID: "chat_tool_activity:\(supportBlockIndex)"
        )
    }

    private static func toolActivityBlock(
        id: String,
        supportBlock: [String: Any],
        supportBlockIndex: Int
    ) -> [String: Any] {
        let items = toolActivityItems(from: supportBlock, supportBlockIndex: supportBlockIndex)
        return [
            "id": id,
            "sourceBlockId": toolActivitySourceBlockID(supportBlock: supportBlock, items: items),
            "type": "chat_tool_activity",
            "status": toolActivityStatus(items: items),
            "text": "",
            "durationMilliseconds": toolActivityDurationMilliseconds(items: items, supportBlock: supportBlock),
            "startedAtMilliseconds": toolActivityStartedAtMilliseconds(items: items, supportBlock: supportBlock),
            "searchQueries": [],
            "searchReferences": [],
            "items": items
        ]
    }

    private static func mainTextBlock(
        id: String,
        messageID: String,
        text: String
    ) -> [String: Any] {
        [
            "id": id,
            "messageId": messageID,
            "sourceBlockId": NSNull(),
            "type": "main_text",
            "status": "streaming",
            "text": text,
            "subtitleText": NSNull(),
            "detailText": NSNull(),
            "durationMilliseconds": NSNull(),
            "startedAtMilliseconds": NSNull(),
            "chatTurnStartedAtMilliseconds": NSNull(),
            "chatTurnDurationMilliseconds": NSNull(),
            "summaryParts": [],
            "summaryDurationsMilliseconds": [],
            "searchQueries": [],
            "searchReferences": [],
            "webSearchActions": [],
            "attachments": [],
            "images": [],
            "previewItems": [],
            "items": [],
            "chatToolName": NSNull(),
            "chatToolBatchID": NSNull(),
            "chatProcessingActive": false
        ]
    }

    private static func progressBlock(
        id: String,
        supportBlock: [String: Any],
        text: String
    ) -> [String: Any] {
        [
            "id": id,
            "sourceBlockId": stringValue(supportBlock["id"]) ?? id,
            "messageId": NSNull(),
            "type": "chat_progress",
            "status": stringValue(supportBlock["status"]) ?? "streaming",
            "text": text,
            "subtitleText": NSNull(),
            "detailText": NSNull(),
            "durationMilliseconds": supportBlock["durationMilliseconds"] ?? NSNull(),
            "startedAtMilliseconds": supportBlock["startedAtMilliseconds"] ?? NSNull(),
            "chatTurnStartedAtMilliseconds": supportBlock["chatTurnStartedAtMilliseconds"] ?? supportBlock["readexTurnStartedAtMilliseconds"] ?? NSNull(),
            "chatTurnDurationMilliseconds": supportBlock["chatTurnDurationMilliseconds"] ?? supportBlock["readexTurnDurationMilliseconds"] ?? NSNull(),
            "summaryParts": [],
            "summaryDurationsMilliseconds": [],
            "searchQueries": [],
            "searchReferences": [],
            "webSearchActions": [],
            "attachments": [],
            "images": [],
            "previewItems": [],
            "items": [],
            "chatToolName": NSNull(),
            "chatToolBatchID": NSNull(),
            "chatProcessingActive": false
        ]
    }

    private static func toolActivityItems(
        from supportBlock: [String: Any],
        supportBlockIndex: Int
    ) -> [[String: Any]] {
        let sourceBlockID = stringValue(supportBlock["sourceBlockId"])
            ?? stringValue(supportBlock["sourceBlockID"])
            ?? stringValue(supportBlock["id"])
            ?? "chat_tool_call:\(supportBlockIndex)"
        let items = supportBlock["items"] as? [[String: Any]] ?? []
        return items.enumerated().map { index, item in
            var resolved = item
            let itemID = stringValue(item["id"])
                ?? stringValue(item["sourceBlockId"])
                ?? stringValue(item["sourceBlockID"])
                ?? [sourceBlockID, "item", "\(index)"].joined(separator: ":")
            resolved["id"] = itemID
            if stringValue(resolved["sourceBlockId"]) == nil,
               stringValue(resolved["sourceBlockID"]) == nil {
                resolved["sourceBlockId"] = sourceBlockID
            }
            return resolved
        }
    }

    private static func toolActivitySourceBlockID(
        supportBlock: [String: Any],
        items: [[String: Any]]
    ) -> String {
        stringValue(supportBlock["sourceBlockId"])
            ?? stringValue(supportBlock["sourceBlockID"])
            ?? stringValue(items.first?["id"])
            ?? ""
    }

    private static func toolActivityStatus(items: [[String: Any]]) -> String {
        items.contains { item in
            switch normalizedStatus(item["status"]) {
            case "pending", "processing", "streaming", "searching", "inprogress", "running":
                return true
            default:
                return false
            }
        } ? "processing" : "success"
    }

    private static func toolActivityDurationMilliseconds(
        items: [[String: Any]],
        supportBlock: [String: Any]
    ) -> Any {
        let durations = items.compactMap { intValue($0["durationMilliseconds"]) }
        if !durations.isEmpty {
            return durations.reduce(0, +)
        }
        return supportBlock["durationMilliseconds"] ?? NSNull()
    }

    private static func toolActivityStartedAtMilliseconds(
        items: [[String: Any]],
        supportBlock: [String: Any]
    ) -> Any {
        let startedValues = items.compactMap { intValue($0["startedAtMilliseconds"]) }
        if let started = startedValues.min() {
            return started
        }
        return supportBlock["startedAtMilliseconds"] ?? NSNull()
    }

    private static func runtimeScopedBlockID(message: [String: Any], localBlockID: String) -> String {
        let namespace = stringValue(message["id"])
            ?? stringValue(message["patchKey"])
            ?? ""
        return namespace.isEmpty ? localBlockID : "\(namespace):\(localBlockID)"
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func normalizedStatus(_ value: Any?) -> String {
        switch stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inprogress", "running", "processing", "streaming", "pending":
            return "processing"
        case "searching":
            return "searching"
        case "completed", "complete", "success", "succeeded":
            return "success"
        case "failed", "failure", "error":
            return "failed"
        case "stopped", "cancelled", "canceled", "interrupted":
            return "stopped"
        default:
            return ""
        }
    }
}

struct ExampleChatTranscriptImageCacheEntry: Equatable {
    var key: String
    var base64: String
    var mimeType: String?
}

struct ExampleChatTranscriptVisibleTextProbe: Equatable {
    struct MessageLayout: Equatable, Hashable {
        var role: String
        var dataRole: String
        var left: Double
        var right: Double
        var width: Double
        var centerX: Double
    }

    var visibleText: String
    var normalizedVisibleText: String
    var chatTranscriptTheme: String = ""
    var messageLayouts: [MessageLayout] = []
    var visibleMessageRoleTexts: [String] = []
    var chatSupportLineTitles: [String] = []
    var chatTerminalSupportLineTitles: [String] = []
    var chatToolActivityItemTitles: [String] = []
    var chatProcessingTitles: [String] = []
    var chatProcessingClassNames: [String] = []
    var chatProcessingDurationTexts: [String] = []
    var chatProcessingDurationSeconds: [Int] = []
    var chatToolActivityTitles: [String] = []
    var liveExampleChatProcessingBlockCount: Int = 0
    var terminalCommandIconCount: Int = 0
    var mainFlowNormalizedText: String = ""
    var toolActivityDetailsCount: Int = 0
    var toolActivityDisclosureCount: Int = 0
    var shellExecutionDisclosureCount: Int = 0
    var shellExecutionOutputBlockCount: Int = 0
    var shellExecutionOutputNormalizedText: String = ""
    var katexElementCount: Int = 0
    var highlightedCodeElementCount: Int = 0
    var markdownCodeBlockCount: Int = 0
    var capturedAtMilliseconds: Int?
}

struct ExampleChatTranscriptWebView: View {
    var state: ExampleChatTranscriptRenderState
    var bottomContentInset: CGFloat = 0
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?
    var onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?

    var body: some View {
        PlatformExampleChatTranscriptWebView(
            renderController: nil,
            state: state,
            stateRevision: nil,
            streamingUpdate: nil,
            streamingUpdateRevision: 0,
            bottomContentInset: bottomContentInset,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExpansionStateChange: onExpansionStateChange,
            onAddSelectedTextToChat: onAddSelectedTextToChat
        )
            .background(Color.clear)
    }
}

struct ExampleChatTranscriptControlledWebView: View {
    @ObservedObject var renderController: ExampleChatTranscriptRenderController
    var bottomContentInset: CGFloat = 0
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?
    var onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?

    var body: some View {
        let snapshot = renderController.snapshot
        PlatformExampleChatTranscriptWebView(
            renderController: renderController,
            state: snapshot.state,
            stateRevision: snapshot.stateRevision,
            streamingUpdate: snapshot.streamingUpdate,
            streamingUpdateRevision: snapshot.streamingUpdateRevision,
            bottomContentInset: bottomContentInset,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExpansionStateChange: onExpansionStateChange,
            onAddSelectedTextToChat: onAddSelectedTextToChat
        )
        .background(Color.clear)
    }
}

#if os(iOS)
private struct PlatformExampleChatTranscriptWebView: UIViewRepresentable {
    var renderController: ExampleChatTranscriptRenderController?
    var state: ExampleChatTranscriptRenderState?
    var stateRevision: Int?
    var streamingUpdate: ExampleChatTranscriptStreamingMarkdownUpdateBatch?
    var streamingUpdateRevision: Int
    var bottomContentInset: CGFloat
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?
    var onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExpansionStateChange: onExpansionStateChange,
            onAddSelectedTextToChat: onAddSelectedTextToChat
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(
            initialState: state ?? renderController?.currentState ?? .empty
        )
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        context.coordinator.update(
            webView: webView,
            state: state,
            stateRevision: stateRevision,
            streamingUpdate: streamingUpdate,
            streamingUpdateRevision: streamingUpdateRevision,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExpansionStateChange: onExpansionStateChange,
            onAddSelectedTextToChat: onAddSelectedTextToChat
        )
    }
}
#elseif os(macOS)
private struct PlatformExampleChatTranscriptWebView: NSViewRepresentable {
    var renderController: ExampleChatTranscriptRenderController?
    var state: ExampleChatTranscriptRenderState?
    var stateRevision: Int?
    var streamingUpdate: ExampleChatTranscriptStreamingMarkdownUpdateBatch?
    var streamingUpdateRevision: Int
    var bottomContentInset: CGFloat
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?
    var onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExpansionStateChange: onExpansionStateChange,
            onAddSelectedTextToChat: onAddSelectedTextToChat
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(
            initialState: state ?? renderController?.currentState ?? .empty
        )
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        context.coordinator.update(
            webView: webView,
            state: state,
            stateRevision: stateRevision,
            streamingUpdate: streamingUpdate,
            streamingUpdateRevision: streamingUpdateRevision,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExpansionStateChange: onExpansionStateChange,
            onAddSelectedTextToChat: onAddSelectedTextToChat
        )
    }
}
#endif

#if os(iOS)
private final class PhotoSorterTranscriptWKWebView: WKWebView {
    var onAddSelectedTextMenuPayload: ((Any?) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let action = UIAction(
            title: "添加到对话",
            image: UIImage(systemName: "bubble.left")
        ) { [weak self] _ in
            self?.addSelectedTextToChatFromNativeMenu()
        }
        let menu = UIMenu(title: "", options: .displayInline, children: [action])
        builder.insertChild(menu, atStartOfMenu: .standardEdit)
    }

    private func addSelectedTextToChatFromNativeMenu() {
        evaluateJavaScript(Self.nativeSelectedTextPayloadScript) { [weak self] result, _ in
            self?.onAddSelectedTextMenuPayload?(result)
        }
    }

    private static let nativeSelectedTextPayloadScript = """
    (() => {
      const repair = window.__chatTranscriptCurrentRepairSelectionPayload;
      const payload = typeof repair === "function" ? repair(true) : null;
      if (payload && String(payload.selectedText || "").trim()) {
        payload.type = "addToChat";
        return payload;
      }
      const text = window.getSelection ? String(window.getSelection()) : "";
      return text.trim() ? { type: "addToChat", selectedText: text } : null;
    })();
    """
}
#endif

@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let selectionContextMenuMessageHandlerName = "readexTranscriptSelectionContextMenu"

    private struct PendingStreamingUpdate {
        var update: ExampleChatTranscriptStreamingMarkdownUpdateBatch
        var revision: Int?
    }

    private var isLoaded = false
    private var pendingState: ExampleChatTranscriptRenderState?
    private var lastReceivedStateRevision: Int?
    private var lastAppliedStreamingUpdateRevision = 0
    private var pendingStreamingUpdates: [PendingStreamingUpdate] = []
    private var lastRenderedSignature: String?
    private var isRenderInFlight = false
    private var pendingVisibleTextProbeToken: UUID?
    private var lastVisibleTextProbeFingerprint: String?
    private var registeredImageCacheKeys = Set<String>()
    private weak var exportController: ExampleChatTranscriptExportController?
    private var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    private var onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?
    private var onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?

    init(
        exportController: ExampleChatTranscriptExportController?,
        onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?,
        onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?,
        onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?
    ) {
        self.exportController = exportController
        self.onRenderedProbe = onRenderedProbe
        self.onExpansionStateChange = onExpansionStateChange
        self.onAddSelectedTextToChat = onAddSelectedTextToChat
    }

    func makeWebView(initialState: ExampleChatTranscriptRenderState) -> WKWebView {
        pendingState = initialState

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "readexTranscriptHost")
        configuration.userContentController.add(self, name: "presentationProbe")
        configuration.userContentController.add(self, name: "readexTranscriptExpansionState")
        configuration.userContentController.add(self, name: Self.selectionContextMenuMessageHandlerName)
        if ExampleChatTranscriptStreamTrace.enabled {
            configuration.userContentController.addUserScript(Self.streamTraceUserScript())
        }
        configuration.userContentController.addUserScript(Self.selectionContextMenuOptionsUserScript())
        configuration.userContentController.addUserScript(Self.selectionContextMenuUserScript())

        #if os(iOS)
        let webView = PhotoSorterTranscriptWKWebView(frame: .zero, configuration: configuration)
        webView.onAddSelectedTextMenuPayload = { [weak self] payload in
            self?.handleNativeSelectedTextMenuPayload(payload)
        }
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        applyScrollIndicatorStyle(to: webView, presentation: initialState.presentation)
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        exportController?.attach(webView: webView)

        webView.loadHTMLString(
            ExampleChatTranscriptRendererShell.htmlString(initialMetadata: initialState.presentation),
            baseURL: ExampleChatTranscriptRendererShell.resourcesBaseURL()
        )
        return webView
    }

    func applyScrollInsets(to webView: WKWebView, bottomContentInset: CGFloat) {
        #if os(iOS)
        var contentInset = webView.scrollView.contentInset
        contentInset.bottom = bottomContentInset
        webView.scrollView.contentInset = contentInset

        var indicatorInsets = webView.scrollView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = bottomContentInset
        webView.scrollView.verticalScrollIndicatorInsets = indicatorInsets
        #endif
    }

    func applyScrollIndicatorStyle(to webView: WKWebView, presentation: [String: Any]) {
        #if os(iOS)
        let theme = presentation["theme"] as? String
        webView.scrollView.indicatorStyle = theme == PhotoSorterInterfaceTheme.dark.rawValue ? .white : .black
        #endif
    }

    func update(
        webView: WKWebView,
        state: ExampleChatTranscriptRenderState?,
        stateRevision: Int?,
        streamingUpdate: ExampleChatTranscriptStreamingMarkdownUpdateBatch?,
        streamingUpdateRevision: Int,
        exportController: ExampleChatTranscriptExportController?,
        onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?,
        onExpansionStateChange: ((ExampleChatTranscriptExpansionStateChange) -> Void)?,
        onAddSelectedTextToChat: ((PhotoSorterTextSelectionSnapshot) -> Void)?
    ) {
        if let state {
            pendingState = state
        }
        self.exportController = exportController
        exportController?.attach(webView: webView)
        self.onRenderedProbe = onRenderedProbe
        self.onExpansionStateChange = onExpansionStateChange
        self.onAddSelectedTextToChat = onAddSelectedTextToChat
        #if os(iOS)
        if let transcriptWebView = webView as? PhotoSorterTranscriptWKWebView {
            transcriptWebView.onAddSelectedTextMenuPayload = { [weak self] payload in
                self?.handleNativeSelectedTextMenuPayload(payload)
            }
        }
        #endif

        let shouldRenderFullState: Bool
        if let stateRevision, state != nil {
            shouldRenderFullState = lastReceivedStateRevision != stateRevision
            lastReceivedStateRevision = stateRevision
        } else if stateRevision == nil, state != nil {
            shouldRenderFullState = true
            lastReceivedStateRevision = nil
        } else {
            shouldRenderFullState = false
        }

        ExampleChatTranscriptStreamTrace.log("webview.update", fields: [
            "is_loaded": isLoaded,
            "state_revision": stateRevision ?? -1,
            "has_state": state != nil,
            "should_render_full_state": shouldRenderFullState,
            "streaming_revision": streamingUpdateRevision,
            "last_applied_streaming_revision": lastAppliedStreamingUpdateRevision,
            "has_streaming_update": streamingUpdate?.isEmpty == false,
            "streaming_summary": streamingUpdate?.traceSummary ?? "",
            "is_render_in_flight": isRenderInFlight,
            "has_pending_streaming_update": !pendingStreamingUpdates.isEmpty,
            "pending_streaming_update_count": pendingStreamingUpdates.count
        ])

        guard isLoaded else {
            return
        }
        if shouldRenderFullState, let state {
            pendingState = state
            renderPendingState(in: webView)
            return
        }

        guard let streamingUpdate,
              !streamingUpdate.isEmpty,
              streamingUpdateRevision != lastAppliedStreamingUpdateRevision else {
            ExampleChatTranscriptStreamTrace.log("webview.streaming_update_skipped", fields: [
                "reason": "missing_empty_or_same_revision",
                "streaming_revision": streamingUpdateRevision,
                "last_applied_streaming_revision": lastAppliedStreamingUpdateRevision
            ])
            return
        }
        applyStreamingMarkdownUpdate(
            streamingUpdate,
            revision: streamingUpdateRevision,
            in: webView
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        registeredImageCacheKeys.removeAll(keepingCapacity: true)
        lastRenderedSignature = nil
        isRenderInFlight = false
        pendingStreamingUpdates.removeAll(keepingCapacity: true)
        renderPendingState(in: webView)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "readexTranscriptExpansionState":
            guard let change = Self.expansionStateChange(from: message.body) else {
                return
            }
            onExpansionStateChange?(change)
        case "readexTranscriptHost":
            Self.handleHostMessage(message.body)
        case "presentationProbe":
            Self.handlePresentationProbe(message.body)
        case Self.selectionContextMenuMessageHandlerName:
            handleSelectionContextMenuMessage(message.body)
        default:
            return
        }
    }

    private static func selectionContextMenuOptionsUserScript() -> WKUserScript {
        WKUserScript(
            source: "window.__chatTranscriptSelectionContextMenuOptions = { copyShortcutRequiresMeta: false, usesNativeSelectionCopy: true };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    private static func streamTraceUserScript() -> WKUserScript {
        WKUserScript(
            source: """
            window.__chatTranscriptDebugPresentationProbesEnabled = true;
            window.__chatTranscriptRenderPerfProbeEnabled = true;
            window.__photoSorterStreamTraceEnabled = true;
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    private static func selectionContextMenuUserScript() -> WKUserScript {
        let source = ExampleChatTranscriptRendererShell.selectionContextMenuUserScriptSource(
            handlerName: selectionContextMenuMessageHandlerName
        )
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    private func handleSelectionContextMenuMessage(_ value: Any) {
        guard let object = value as? [String: Any],
              Self.stringValue(object["type"]) == "addToChat" else {
            return
        }
        Self.selectionSnapshots(from: object).forEach { snapshot in
            onAddSelectedTextToChat?(snapshot)
        }
    }

    private func handleNativeSelectedTextMenuPayload(_ value: Any?) {
        guard let object = value as? [String: Any] else {
            return
        }
        Self.selectionSnapshots(from: object).forEach { snapshot in
            onAddSelectedTextToChat?(snapshot)
        }
    }

    private static func selectionSnapshots(from object: [String: Any]) -> [PhotoSorterTextSelectionSnapshot] {
        if let selections = object["selections"] as? [[String: Any]] {
            return selections.compactMap(selectionSnapshot(from:))
        }
        return selectionSnapshot(from: object).map { [$0] } ?? []
    }

    private static func selectionSnapshot(from object: [String: Any]) -> PhotoSorterTextSelectionSnapshot? {
        guard let selectedText = stringValue(object["selectedText"]) else {
            return nil
        }
        return PhotoSorterTextSelectionSnapshot(
            selectedText: selectedText,
            sourceMessageID: stringValue(object["messageID"]),
            sourceMessageRole: stringValue(object["messageRole"]),
            selectedTextOccurrenceIndexInMessage: intValue(object["selectedTextOccurrenceIndexInMessage"]),
            renderedTextSegments: stringArrayValue(object["renderedTextSegments"])
        )
    }

    private func renderPendingState(in webView: WKWebView) {
        guard let state = pendingState else {
            return
        }

        ExampleChatTranscriptStreamTrace.log("webview.render_pending_state", fields: [
            "is_generating": state.isGenerating,
            "is_streaming_update_in_flight": isRenderInFlight
        ])

        applyScrollIndicatorStyle(to: webView, presentation: state.presentation)

        let signature = Self.signature(for: state)
        guard signature != lastRenderedSignature else {
            return
        }

        lastRenderedSignature = signature
        let shouldPreserveScrollAnchor = !state.isGenerating
        invoke(command: "set_presentation", payload: state.presentation, options: [
            "suppressConversationRerender": true,
            "preserveScrollAnchor": shouldPreserveScrollAnchor,
            "followBottomIfNearBottom": false
        ], in: webView)
        let imageCacheEntries = unregisteredImageCacheEntries(from: state.imageCacheEntries)
        invoke(command: "render_payload", payload: state.payload, options: [
            "followBottomIfNearBottom": false,
            "preserveScrollAnchor": shouldPreserveScrollAnchor,
            "forceImmediateRender": true,
            "debugReason": "msp_playground_render"
        ], imageCacheEntries: imageCacheEntries, in: webView) { [weak self, weak webView] succeeded in
            guard let self, let webView else {
                return
            }
            if !succeeded {
                self.lastRenderedSignature = nil
            }
            if self.drainNextPendingStreamingUpdate(
                reason: "webview.render_pending_state_drain_streaming_update",
                in: webView
            ) {
                return
            }
            if succeeded {
                self.scheduleVisibleTextProbe(in: webView)
            }
        }
    }

    private func applyStreamingMarkdownUpdate(
        _ update: ExampleChatTranscriptStreamingMarkdownUpdateBatch,
        revision: Int?,
        in webView: WKWebView
    ) {
        guard !update.isEmpty else {
            return
        }
        let startedAtMilliseconds = ExampleChatTranscriptStreamTrace.nowMilliseconds()
        ExampleChatTranscriptStreamTrace.log("webview.apply_streaming_update", fields: [
            "revision": revision ?? -1,
            "summary": update.traceSummary,
            "is_render_in_flight": isRenderInFlight,
            "has_pending_streaming_update": !pendingStreamingUpdates.isEmpty,
            "pending_streaming_update_count": pendingStreamingUpdates.count
        ])
        guard !isRenderInFlight else {
            enqueuePendingStreamingUpdate(
                update,
                revision: revision
            )
            return
        }

        if let revision {
            lastAppliedStreamingUpdateRevision = revision
        }
        isRenderInFlight = true
        invoke(command: "update_streaming_markdown_blocks", payload: update.payload, options: [
            "followBottomIfNearBottom": false,
            "forceImmediateRender": false,
            "preserveScrollAnchor": false,
            "debugReason": "msp_playground_streaming_markdown"
        ], in: webView) { [weak self, weak webView] succeeded in
            guard let self, let webView else {
                return
            }
            self.isRenderInFlight = false
            ExampleChatTranscriptStreamTrace.log("webview.apply_streaming_update_completion", fields: [
                "revision": revision ?? -1,
                "succeeded": succeeded,
                "has_pending_streaming_update": !self.pendingStreamingUpdates.isEmpty,
                "pending_streaming_update_count": self.pendingStreamingUpdates.count,
                "elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
            ])
            if self.drainNextPendingStreamingUpdate(
                reason: "webview.apply_streaming_update_drain_pending",
                in: webView
            ) {
                return
            }
            if succeeded {
                self.scheduleVisibleTextProbe(in: webView)
            } else {
                self.renderPendingState(in: webView)
            }
        }
    }

    private func enqueuePendingStreamingUpdate(
        _ update: ExampleChatTranscriptStreamingMarkdownUpdateBatch,
        revision: Int?
    ) {
        ExampleChatTranscriptStreamTrace.log("webview.enqueue_pending_streaming_update", fields: [
            "revision": revision ?? -1,
            "new_summary": update.traceSummary,
            "last_pending_summary": pendingStreamingUpdates.last?.update.traceSummary ?? "",
            "pending_streaming_update_count": pendingStreamingUpdates.count + 1
        ])
        pendingStreamingUpdates.append(PendingStreamingUpdate(update: update, revision: revision))
    }

    @discardableResult
    private func drainNextPendingStreamingUpdate(
        reason: String,
        in webView: WKWebView
    ) -> Bool {
        guard !pendingStreamingUpdates.isEmpty else {
            return false
        }
        let pending = pendingStreamingUpdates.removeFirst()
        ExampleChatTranscriptStreamTrace.log(reason, fields: [
            "revision": pending.revision ?? -1,
            "summary": pending.update.traceSummary,
            "pending_streaming_update_count": pendingStreamingUpdates.count
        ])
        applyStreamingMarkdownUpdate(
            pending.update,
            revision: pending.revision,
            in: webView
        )
        return true
    }

    private func unregisteredImageCacheEntries(
        from entries: [ExampleChatTranscriptImageCacheEntry]
    ) -> [ExampleChatTranscriptImageCacheEntry] {
        var output: [ExampleChatTranscriptImageCacheEntry] = []
        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !registeredImageCacheKeys.contains(key) else {
                continue
            }
            registeredImageCacheKeys.insert(key)
            output.append(entry)
        }
        return output
    }

    private func invoke(
        command: String,
        payload: [String: Any],
        options: [String: Any],
        imageCacheEntries: [ExampleChatTranscriptImageCacheEntry] = [],
        in webView: WKWebView,
        completion: ((Bool) -> Void)? = nil
    ) {
        let startedAtMilliseconds = ExampleChatTranscriptStreamTrace.nowMilliseconds()
        let imageCacheKeys = imageCacheEntries.map(\.key)
        guard let payloadJSON = Self.javascriptLiteral(payload),
              let optionsJSON = Self.javascriptLiteral(options) else {
            imageCacheKeys.forEach { registeredImageCacheKeys.remove($0) }
            completion?(false)
            return
        }

        let imageCachePayloadJSON: String
        if imageCacheEntries.isEmpty {
            imageCachePayloadJSON = "{}"
        } else if let literal = Self.imageCachePayloadLiteral(for: imageCacheEntries) {
            imageCachePayloadJSON = literal
        } else {
            imageCacheKeys.forEach { registeredImageCacheKeys.remove($0) }
            completion?(false)
            return
        }
        let functionBody = ExampleChatTranscriptRendererShell.hostCommandInvocationScriptSource()
        let script = """
        (() => {
          const command = \(Self.javascriptStringLiteral(command));
          const payload = \(payloadJSON);
          const options = \(optionsJSON);
          const imageCachePayload = \(imageCachePayloadJSON);
          if (Array.isArray(imageCachePayload.entries) && imageCachePayload.entries.length) {
            const cache = window.__readexTranscriptImageCache || (window.__readexTranscriptImageCache = Object.create(null));
            const objectURLs = window.__readexTranscriptImageObjectURLs || (window.__readexTranscriptImageObjectURLs = Object.create(null));
            const cachedImageSource = (key, source) => {
              if (
                !source ||
                source.slice(0, 5).toLowerCase() !== "data:" ||
                typeof window.atob !== "function" ||
                typeof Blob === "undefined" ||
                typeof Uint8Array === "undefined" ||
                !window.URL ||
                typeof window.URL.createObjectURL !== "function"
              ) {
                return source;
              }
              const commaIndex = source.indexOf(",");
              if (commaIndex < 0) {
                return source;
              }
              const header = source.slice(0, commaIndex);
              if (header.toLowerCase().indexOf(";base64") < 0) {
                return source;
              }
              try {
                const mimeType = header.slice(5).split(";")[0].trim() || "image/png";
                const binary = window.atob(source.slice(commaIndex + 1));
                const chunkSize = 8192;
                const chunks = [];
                for (let offset = 0; offset < binary.length; offset += chunkSize) {
                  const slice = binary.slice(offset, offset + chunkSize);
                  const bytes = new Uint8Array(slice.length);
                  for (let index = 0; index < slice.length; index += 1) {
                    bytes[index] = slice.charCodeAt(index);
                  }
                  chunks.push(bytes);
                }
                const blobURL = window.URL.createObjectURL(new Blob(chunks, { type: mimeType }));
                if (objectURLs[key]) {
                  window.URL.revokeObjectURL(objectURLs[key]);
                }
                objectURLs[key] = blobURL;
                return blobURL;
              } catch (error) {
                return source;
              }
            };
            imageCachePayload.entries.forEach((entry) => {
              const key = String(entry?.key || "").trim();
              const source = String(entry?.source || "");
              if (key && source) {
                cache[key] = cachedImageSource(key, source);
              }
            });
          }
          \(functionBody)
        })();
        """

        ExampleChatTranscriptStreamTrace.log("webview.invoke", fields: [
            "command": command,
            "payload_summary": Self.tracePayloadSummary(command: command, payload: payload),
            "debug_reason": Self.stringValue(options["debugReason"]) ?? "",
            "force_immediate_render": Self.boolValue(options["forceImmediateRender"]).map { "\($0)" } ?? "",
            "payload_json_length": payloadJSON.count,
            "script_length": script.count,
            "prepare_elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
        ])
        webView.evaluateJavaScript(script) { result, error in
            var succeeded = false
            if let error {
                imageCacheKeys.forEach { self.registeredImageCacheKeys.remove($0) }
                debugPrint("Chat transcript command failed:", command, error)
            } else if let result = result as? [String: Any], result["ok"] as? Bool == false {
                imageCacheKeys.forEach { self.registeredImageCacheKeys.remove($0) }
                debugPrint("Chat transcript command returned failure:", command, result)
            } else {
                succeeded = true
            }
            ExampleChatTranscriptStreamTrace.log("webview.invoke_completion", fields: [
                "command": command,
                "succeeded": succeeded,
                "result_summary": Self.traceResultSummary(result),
                "error": error.map { String(describing: $0) } ?? "",
                "elapsed_ms": ExampleChatTranscriptStreamTrace.elapsedMilliseconds(since: startedAtMilliseconds)
            ])
            completion?(succeeded)
        }
    }

    private static func tracePayloadSummary(command: String, payload: [String: Any]) -> String {
        if command == "update_streaming_markdown_blocks",
           let updates = payload["updates"] as? [[String: Any]] {
            let summary = ExampleChatTranscriptStreamingMarkdownUpdateBatch(updates: updates).traceSummary
            return "updates\(updates.count):\(summary)"
        }
        if let messages = payload["messages"] as? [[String: Any]] {
            return "messages\(messages.count)"
        }
        let keySummary = payload.keys.sorted().joined(separator: ",")
        return "keys:\(keySummary)"
    }

    private static func traceResultSummary(_ result: Any?) -> String {
        guard let object = result as? [String: Any] else {
            return result.map { String(describing: $0) } ?? "nil"
        }
        let resultObject = object["result"] as? [String: Any]
        let inspectedObject = resultObject ?? object
        let ok = boolValue(object["ok"]).map { "\($0)" } ?? ""
        let applied = boolValue(inspectedObject["applied"]).map { "\($0)" } ?? ""
        let reason = traceStringValue(inspectedObject["reason"])
        let engine = traceStringValue(inspectedObject["engine"])
        let errorName = traceStringValue(object["errorName"])
        let errorMessage = traceStringValue(object["errorMessage"], maxLength: 240)
        let timings = inspectedObject["timings"] as? [String: Any]
        let totalMs = traceNumberValue(timings?["totalMs"])
        let payloadMs = traceNumberValue(timings?["payloadMs"])
        let domMs = traceNumberValue(timings?["domMs"])
        let followBottomMs = traceNumberValue(timings?["followBottomMs"])
        return [
            "ok\(ok)",
            "applied\(applied)",
            "reason\(reason)",
            "engine\(engine)",
            "errorName\(errorName)",
            "errorMessage\(errorMessage)",
            "jsTotalMs\(totalMs)",
            "jsPayloadMs\(payloadMs)",
            "jsDomMs\(domMs)",
            "jsFollowMs\(followBottomMs)"
        ].joined(separator: ":")
    }

    private static func traceNumberValue(_ value: Any?) -> String {
        guard let value else {
            return ""
        }
        if let double = value as? Double {
            return String(format: "%.3f", double)
        }
        if let number = value as? NSNumber {
            return String(format: "%.3f", number.doubleValue)
        }
        return stringValue(value) ?? ""
    }

    private static func traceStringValue(_ value: Any?, maxLength: Int = 120) -> String {
        guard let string = stringValue(value) else {
            return ""
        }
        let singleLine = string
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > maxLength else {
            return singleLine
        }
        return String(singleLine.prefix(maxLength)) + "…"
    }

    private func scheduleVisibleTextProbe(in webView: WKWebView) {
        guard onRenderedProbe != nil else {
            return
        }
        let token = UUID()
        pendingVisibleTextProbeToken = token
        for delay in [0.35, 1.55, 2.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.pendingVisibleTextProbeToken == token else {
                    return
                }
                self.captureVisibleTextProbe(in: webView)
            }
        }
    }

    private func captureVisibleTextProbe(in webView: WKWebView) {
        let script = """
        (() => {
          const text = document.body && typeof document.body.innerText === "string"
            ? document.body.innerText
            : "";
          const normalizedText = text.replace(/\\s+/g, " ").trim();
          const normalizedDetachedText = (element) => {
            if (!element) {
              return "";
            }
            const source = typeof element.innerText === "string"
              ? element.innerText
              : (element.textContent || "");
            return source.replace(/\\s+/g, " ").trim();
          };
          const mainFlowClone = document.body ? document.body.cloneNode(true) : null;
          if (mainFlowClone) {
            mainFlowClone.querySelectorAll(
              ".readex-tool-activity-details, .readex-tool-activity-nested, .readex-shell-execution"
            ).forEach((element) => element.remove());
          }
          const mainFlowNormalizedText = normalizedDetachedText(mainFlowClone);
          const processingBlocks = Array.from(document.querySelectorAll(".readex-processing-block"));
          const toolActivityBlocks = Array.from(document.querySelectorAll(".readex-tool-activity-block"));
          const supportLines = Array.from(document.querySelectorAll(".support-line"));
          const shellExecutionOutputBlocks = Array.from(document.querySelectorAll(".readex-shell-execution-output-block"));
          const titleText = (block) => {
            const title = block.querySelector(".support-line-title");
            return title && typeof title.innerText === "string"
              ? title.innerText.replace(/\\s+/g, " ").trim()
              : "";
          };
          const durationText = (block) => {
            const duration = block.querySelector(".readex-processing-duration");
            return duration && typeof duration.innerText === "string"
              ? duration.innerText.replace(/\\s+/g, " ").trim()
              : "";
          };
          const durationSeconds = (text) => {
            const source = String(text || "").trim();
            if (!source) {
              return null;
            }
            const pieces = source.match(/(\\d+)\\s*([hms])/g) || [];
            if (!pieces.length) {
              return null;
            }
            return pieces.reduce((total, piece) => {
              const match = /(\\d+)\\s*([hms])/.exec(piece);
              if (!match) {
                return total;
              }
              const value = Number(match[1]);
              if (!Number.isFinite(value)) {
                return total;
              }
              if (match[2] === "h") {
                return total + value * 3600;
              }
              if (match[2] === "m") {
                return total + value * 60;
              }
              return total + value;
            }, 0);
          };
          const visibleText = (element) => {
            if (!element) {
              return "";
            }
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            if (
              style.display === "none" ||
              style.visibility === "hidden" ||
              Number(rect.width) <= 0 ||
              Number(rect.height) <= 0
            ) {
              return "";
            }
            return typeof element.innerText === "string"
              ? element.innerText.replace(/\\s+/g, " ").trim()
              : "";
          };
          const messageRole = (message) => {
            if (message.classList.contains("user")) {
              return "user";
            }
            if (message.classList.contains("assistant")) {
              return "assistant";
            }
            return message.getAttribute("data-message-role") || "";
          };
          const messageLayouts = Array.from(document.querySelectorAll(".message"))
            .filter((message) => !message.classList.contains("steered"))
            .map((message) => {
              const rect = message.getBoundingClientRect();
              return {
                role: messageRole(message),
                dataRole: message.getAttribute("data-message-role") || "",
                left: rect.left,
                right: rect.right,
                width: rect.width,
                centerX: rect.left + rect.width / 2
              };
            });
          const durationTexts = processingBlocks.map(durationText).filter(Boolean);
          return {
            text,
            normalizedText,
            chatTranscriptTheme: document.documentElement.getAttribute("data-readex-transcript-theme") || "",
            messageLayouts,
            visibleMessageRoleTexts: Array.from(document.querySelectorAll(".message-role"))
              .map(visibleText)
              .filter(Boolean),
            capturedAtMilliseconds: Date.now(),
            chatSupportLineTitles: supportLines.map(titleText).filter(Boolean),
            chatTerminalSupportLineTitles: supportLines
              .filter((line) => line.querySelector(".readex-terminal-command-icon"))
              .map(titleText)
              .filter(Boolean),
            chatToolActivityItemTitles: Array.from(document.querySelectorAll(".readex-tool-activity-item-title"))
              .map((title) => typeof title.innerText === "string"
                ? title.innerText.replace(/\\s+/g, " ").trim()
                : "")
              .filter(Boolean),
            chatProcessingTitles: processingBlocks.map(titleText).filter(Boolean),
            chatProcessingClassNames: processingBlocks
              .map((block) => block.className || "")
              .filter(Boolean),
            chatProcessingDurationTexts: durationTexts,
            chatProcessingDurationSeconds: durationTexts
              .map(durationSeconds)
              .filter((value) => Number.isFinite(value)),
            chatToolActivityTitles: toolActivityBlocks.map(titleText).filter(Boolean),
            liveExampleChatProcessingBlockCount: processingBlocks
              .filter((block) => block.classList.contains("is-live"))
              .length,
            terminalCommandIconCount: document.querySelectorAll(".readex-terminal-command-icon").length,
            mainFlowNormalizedText,
            toolActivityDetailsCount: document.querySelectorAll(".readex-tool-activity-details").length,
            toolActivityDisclosureCount: document.querySelectorAll(".readex-tool-activity-disclosure").length,
            shellExecutionDisclosureCount: document.querySelectorAll(".readex-shell-execution-disclosure").length,
            shellExecutionOutputBlockCount: shellExecutionOutputBlocks.length,
            shellExecutionOutputNormalizedText: shellExecutionOutputBlocks
              .map(normalizedDetachedText)
              .filter(Boolean)
              .join("\\n"),
            katexElementCount: document.querySelectorAll(".katex").length,
            highlightedCodeElementCount: document.querySelectorAll("code.hljs, pre code.hljs, .hljs").length,
            markdownCodeBlockCount: document.querySelectorAll("pre code, .code-block, .message-code-block, .markdown-code-block").length
          };
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard error == nil,
                  let self,
                  let object = result as? [String: Any] else {
                return
            }
            let probe = ExampleChatTranscriptVisibleTextProbe(
                visibleText: object["text"] as? String ?? "",
                normalizedVisibleText: object["normalizedText"] as? String ?? "",
                chatTranscriptTheme: object["chatTranscriptTheme"] as? String ?? "",
                messageLayouts: (object["messageLayouts"] as? [Any] ?? [])
                    .compactMap(Self.messageLayout),
                visibleMessageRoleTexts: object["visibleMessageRoleTexts"] as? [String] ?? [],
                chatSupportLineTitles: object["chatSupportLineTitles"] as? [String] ?? [],
                chatTerminalSupportLineTitles: object["chatTerminalSupportLineTitles"] as? [String] ?? [],
                chatToolActivityItemTitles: object["chatToolActivityItemTitles"] as? [String] ?? [],
                chatProcessingTitles: object["chatProcessingTitles"] as? [String] ?? [],
                chatProcessingClassNames: object["chatProcessingClassNames"] as? [String] ?? [],
                chatProcessingDurationTexts: object["chatProcessingDurationTexts"] as? [String] ?? [],
                chatProcessingDurationSeconds: (object["chatProcessingDurationSeconds"] as? [Any] ?? [])
                    .compactMap { value in
                        if let intValue = value as? Int {
                            return intValue
                        }
                        if let doubleValue = value as? Double {
                            return Int(doubleValue)
                        }
                        return nil
                    },
                chatToolActivityTitles: object["chatToolActivityTitles"] as? [String] ?? [],
                liveExampleChatProcessingBlockCount: object["liveExampleChatProcessingBlockCount"] as? Int ?? 0,
                terminalCommandIconCount: object["terminalCommandIconCount"] as? Int ?? 0,
                mainFlowNormalizedText: object["mainFlowNormalizedText"] as? String ?? "",
                toolActivityDetailsCount: object["toolActivityDetailsCount"] as? Int ?? 0,
                toolActivityDisclosureCount: object["toolActivityDisclosureCount"] as? Int ?? 0,
                shellExecutionDisclosureCount: object["shellExecutionDisclosureCount"] as? Int ?? 0,
                shellExecutionOutputBlockCount: object["shellExecutionOutputBlockCount"] as? Int ?? 0,
                shellExecutionOutputNormalizedText: object["shellExecutionOutputNormalizedText"] as? String ?? "",
                katexElementCount: object["katexElementCount"] as? Int ?? 0,
                highlightedCodeElementCount: object["highlightedCodeElementCount"] as? Int ?? 0,
                markdownCodeBlockCount: object["markdownCodeBlockCount"] as? Int ?? 0,
                capturedAtMilliseconds: object["capturedAtMilliseconds"] as? Int
            )
            let fingerprint = Self.fingerprint(for: probe)
            guard fingerprint != self.lastVisibleTextProbeFingerprint else {
                return
            }
            self.lastVisibleTextProbeFingerprint = fingerprint
            self.onRenderedProbe?(probe)
        }
    }

    private static func messageLayout(_ value: Any) -> ExampleChatTranscriptVisibleTextProbe.MessageLayout? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        return ExampleChatTranscriptVisibleTextProbe.MessageLayout(
            role: object["role"] as? String ?? "",
            dataRole: object["dataRole"] as? String ?? "",
            left: doubleValue(object["left"]) ?? 0,
            right: doubleValue(object["right"]) ?? 0,
            width: doubleValue(object["width"]) ?? 0,
            centerX: doubleValue(object["centerX"]) ?? 0
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    private static func expansionStateChange(from value: Any) -> ExampleChatTranscriptExpansionStateChange? {
        guard let object = value as? [String: Any],
              let kind = stringValue(object["kind"]),
              let expanded = boolValue(object["changedExpanded"]),
              let sourceBlockID = stringValue(object["changedSourceBlockId"])
                ?? stringValue(object["changedSourceBlockID"]) else {
            return nil
        }

        switch kind {
        case "readex_processing_expansion_state":
            return ExampleChatTranscriptExpansionStateChange(
                kind: .processing,
                sourceBlockID: sourceBlockID,
                key: nil,
                expanded: expanded
            )
        case "readex_tool_activity_expansion_state":
            return ExampleChatTranscriptExpansionStateChange(
                kind: .toolActivity,
                sourceBlockID: sourceBlockID,
                key: nil,
                expanded: expanded
            )
        case "readex_nested_disclosure_expansion_state":
            guard let key = stringValue(object["changedKey"]) else {
                return nil
            }
            return ExampleChatTranscriptExpansionStateChange(
                kind: .nestedDisclosure,
                sourceBlockID: sourceBlockID,
                key: key,
                expanded: expanded
            )
        default:
            return nil
        }
    }

    private static func handleHostMessage(_ value: Any) {
        guard let object = value as? [String: Any],
              let kind = stringValue(object["kind"]) else {
            return
        }

        switch kind {
        case "copy_text", "copyText":
            guard let text = object["text"] as? String else {
                return
            }
            writeTextToPasteboard(text)
        default:
            return
        }
    }

    private static func handlePresentationProbe(_ value: Any) {
        guard ExampleChatTranscriptStreamTrace.enabled,
              let object = value as? [String: Any] else {
            return
        }
        let kind = stringValue(object["kind"]) ?? "unknown"
        let event = stringValue(object["event"]) ?? "unknown"
        guard kind == "streaming_render"
            || kind == "render"
            || kind == "mutation"
            || kind == "patch"
            || kind == "presentation" else {
            return
        }
        ExampleChatTranscriptStreamTrace.log("js.presentation_probe", fields: [
            "kind": kind,
            "event": event,
            "text_length": intValue(object["textLength"]) ?? intValue(object["text_length"]) ?? 0,
            "engine": stringValue(object["engine"]) ?? stringValue(object["renderEngine"]) ?? "",
            "reason": stringValue(object["reason"]) ?? "",
            "render_phase": stringValue(object["renderPhase"]) ?? "",
            "restore_strategy": stringValue(object["restoreStrategy"]) ?? "",
            "scroll_top": traceNumberValue(object["scrollTop"]),
            "scroll_height": traceNumberValue(object["scrollHeight"]),
            "client_height": traceNumberValue(object["clientHeight"]),
            "delta": traceNumberValue(object["delta"]),
            "fallback_offset": traceNumberValue(object["fallbackOffset"]),
            "anchor_role": stringValue(object["anchorRole"]) ?? "",
            "anchor_message_id": stringValue(object["anchorMessageID"]) ?? "",
            "anchor_distance_from_bottom": traceNumberValue(object["anchorDistanceFromBottom"]),
            "was_at_bottom": boolValue(object["wasAtConversationBottom"]).map { "\($0)" } ?? "",
            "should_follow_bottom": boolValue(object["shouldFollowBottom"]).map { "\($0)" } ?? "",
            "should_pin_top": boolValue(object["shouldPinTop"]).map { "\($0)" } ?? "",
            "preserve_scroll_anchor": boolValue(object["preserveScrollAnchor"]).map { "\($0)" } ?? ""
        ])
    }

    private static func writeTextToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let string = item as? String else {
                return nil
            }
            return string
        }
    }

    private static func javascriptLiteral(_ value: [String: Any]) -> String? {
        let object = value.mapValues { anyJSONValue($0) }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
            .replacingOccurrences(of: "</script", with: "<\\/script")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func imageCachePayloadLiteral(
        for entries: [ExampleChatTranscriptImageCacheEntry]
    ) -> String? {
        guard !entries.isEmpty else {
            return nil
        }
        let payload: [String: Any] = [
            "entries": entries.compactMap { entry -> [String: Any]? in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let base64 = trimImageSourceIfNeeded(entry.base64)
                guard !key.isEmpty,
                      !base64.isEmpty else {
                    return nil
                }
                return [
                    "key": key,
                    "source": imageDataURL(base64: base64, mimeType: entry.mimeType)
                ]
            }
        ]
        return javascriptLiteral(payload)
    }

    private static func imageDataURL(base64: String, mimeType: String?) -> String {
        let normalizedBase64 = trimImageSourceIfNeeded(base64)
        let prefixEnd = normalizedBase64.index(
            normalizedBase64.startIndex,
            offsetBy: 5,
            limitedBy: normalizedBase64.endIndex
        ) ?? normalizedBase64.endIndex
        if normalizedBase64.range(
            of: "data:",
            options: [.caseInsensitive],
            range: normalizedBase64.startIndex..<prefixEnd
        ) != nil {
            return normalizedBase64
        }
        let normalizedMimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMimeType: String
        if let normalizedMimeType,
           !normalizedMimeType.isEmpty {
            resolvedMimeType = normalizedMimeType
        } else {
            resolvedMimeType = "image/png"
        }
        return "data:\(resolvedMimeType);base64,\(normalizedBase64)"
    }

    private static func trimImageSourceIfNeeded(_ source: String) -> String {
        guard let first = source.unicodeScalars.first,
              let last = source.unicodeScalars.last else {
            return ""
        }
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard whitespace.contains(first) || whitespace.contains(last) else {
            return source
        }
        return source.trimmingCharacters(in: whitespace)
    }

    private static func anyJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { anyJSONValue($0) }
        case let array as [Any]:
            return array.map { anyJSONValue($0) }
        default:
            return value
        }
    }

    private static func javascriptStringLiteral(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    private static func signature(for state: ExampleChatTranscriptRenderState) -> String {
        let object: [String: Any] = [
            "payload": state.payload,
            "presentation": state.presentation
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return UUID().uuidString
        }
        return json
    }

    private static func fingerprint(for probe: ExampleChatTranscriptVisibleTextProbe) -> String {
        [
            "\(probe.visibleText.count)",
            "\(probe.normalizedVisibleText.hashValue)",
            "\(probe.chatTranscriptTheme)",
            "\(probe.messageLayouts.hashValue)",
            "\(probe.visibleMessageRoleTexts.hashValue)",
            "\(probe.chatSupportLineTitles.hashValue)",
            "\(probe.chatTerminalSupportLineTitles.hashValue)",
            "\(probe.chatToolActivityItemTitles.hashValue)",
            "\(probe.chatProcessingTitles.hashValue)",
            "\(probe.chatProcessingClassNames.hashValue)",
            "\(probe.chatProcessingDurationTexts.hashValue)",
            "\(probe.chatToolActivityTitles.hashValue)",
            "\(probe.terminalCommandIconCount)",
            "\(probe.liveExampleChatProcessingBlockCount)",
            "\(probe.mainFlowNormalizedText.hashValue)",
            "\(probe.toolActivityDetailsCount)",
            "\(probe.toolActivityDisclosureCount)",
            "\(probe.shellExecutionDisclosureCount)",
            "\(probe.shellExecutionOutputBlockCount)",
            "\(probe.shellExecutionOutputNormalizedText.hashValue)",
            "\(probe.katexElementCount)",
            "\(probe.highlightedCodeElementCount)",
            "\(probe.markdownCodeBlockCount)"
        ].joined(separator: ":")
    }
}

private extension WKWebView {
    @MainActor
    func chatFullDocumentContentSize() async throws -> CGSize {
        let script = """
        (() => {
          const root = document.scrollingElement || document.documentElement || document.body;
          const html = document.documentElement || root;
          const body = document.body || root;
          const width = Math.max(
            root ? root.scrollWidth : 0,
            html ? html.scrollWidth : 0,
            body ? body.scrollWidth : 0,
            root ? root.clientWidth : 0,
            html ? html.clientWidth : 0
          );
          const height = Math.max(
            root ? root.scrollHeight : 0,
            html ? html.scrollHeight : 0,
            body ? body.scrollHeight : 0,
            root ? root.clientHeight : 0,
            html ? html.clientHeight : 0
          );
          return JSON.stringify({ width, height });
        })();
        """
        let result = try await evaluateJavaScriptValue(script)
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = Self.doubleValue(payload["width"]),
              let height = Self.doubleValue(payload["height"]) else {
            throw ExampleChatTranscriptExportController.ExportError.invalidDocumentSize
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    private func evaluateJavaScriptValue(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }
}
