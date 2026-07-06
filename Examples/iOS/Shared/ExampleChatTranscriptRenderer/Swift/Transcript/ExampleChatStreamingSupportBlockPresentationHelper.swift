import Foundation

enum ExampleChatStreamingSupportBlockPresentationHelper {
    static func processingStartedAtMilliseconds(in blocks: [AssistantSupportBlock]) -> Int? {
        blocks.compactMap { block -> Int? in
            guard isProcessingBlockKind(block.kind),
                  let startedAtMilliseconds = block.startedAtMilliseconds,
                  startedAtMilliseconds > 0 else {
                return nil
            }
            return startedAtMilliseconds
        }.min()
    }

    static func processingStartedAtDate(in blocks: [AssistantSupportBlock]) -> Date? {
        guard let startedAtMilliseconds = processingStartedAtMilliseconds(in: blocks) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(startedAtMilliseconds) / 1000)
    }

    static func workedForItem(
        status: AssistantSupportWorkedForItem.Status,
        startedAtMilliseconds: Int?,
        durationMilliseconds: Int? = nil
    ) -> AssistantSupportWorkedForItem? {
        guard let startedAtMilliseconds,
              startedAtMilliseconds > 0 else {
            return nil
        }
        let completedAtMilliseconds: Int?
        if status == .worked, let durationMilliseconds {
            completedAtMilliseconds = startedAtMilliseconds + max(0, durationMilliseconds)
        } else {
            completedAtMilliseconds = nil
        }
        return AssistantSupportWorkedForItem(
            status: status,
            startedAtMilliseconds: startedAtMilliseconds,
            completedAtMilliseconds: completedAtMilliseconds
        )
    }

    static func firstProcessingBlockIndex(in blocks: [AssistantSupportBlock]) -> Int? {
        blocks.firstIndex { isProcessingBlockKind($0.kind) }
    }

    static func firstActivityBlockIndex(in blocks: [AssistantSupportBlock]) -> Int? {
        blocks.firstIndex { isActivityBlockKind($0.kind) }
    }

    static func upsertToolActivityItem(
        in block: inout AssistantSupportBlock,
        call: ExampleChatToolCall,
        text: String,
        detailText: String?,
        status: String,
        completed: Bool,
        startedAtMilliseconds: Int?,
        completedAtMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil,
        previewItems: [AssistantSupportPreviewItem] = [],
        chatToolBatchID: UUID? = nil
    ) {
        let existing = block.activityItems.first { $0.id == call.id }
        let resolvedPreviewItems = previewItems.isEmpty
            ? (existing?.previewItems ?? block.previewItems)
            : previewItems
        let shellExecution = ExampleChatShellTranscriptDisplaySupport.shellExecution(
            for: call,
            cwd: existing?.shellExecution?.cwd
        ) ?? existing?.shellExecution
        let commandExecution = ExampleChatShellTranscriptDisplaySupport.commandExecution(
            for: call,
            cwd: existing?.commandExecution?.cwd
        ) ?? existing?.commandExecution
        let item = AssistantSupportActivityItem(
            id: call.id,
            sourceBlockID: block.id.uuidString,
            type: "chatToolCall",
            server: "workspace",
            tool: call.name.rawValue,
            arguments: .object(call.arguments),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detailText: detailText?.trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            completed: completed,
            durationMilliseconds: durationMilliseconds ?? existing?.durationMilliseconds,
            startedAtMilliseconds: startedAtMilliseconds
                ?? existing?.startedAtMilliseconds
                ?? block.startedAtMilliseconds,
            completedAtMilliseconds: completedAtMilliseconds ?? existing?.completedAtMilliseconds,
            previewItems: resolvedPreviewItems,
            chatToolName: call.name.rawValue,
            chatToolBatchID: chatToolBatchID ?? existing?.chatToolBatchID ?? block.chatToolBatchID,
            shellExecution: shellExecution,
            commandExecution: commandExecution
        )
        upsertActivityItem(item, in: &block)
    }

    static func upsertToolActivityItem(
        in block: inout AssistantSupportBlock,
        result: ExampleChatToolResult,
        text: String,
        detailText: String?,
        status: String,
        startedAtMilliseconds: Int?,
        completedAtMilliseconds: Int,
        durationMilliseconds: Int,
        previewItems: [AssistantSupportPreviewItem],
        chatToolBatchID: UUID?
    ) {
        let existing = block.activityItems.first { $0.id == result.callID }
        let resolvedPreviewItems = previewItems.isEmpty
            ? (existing?.previewItems ?? block.previewItems)
            : previewItems
        let errorMessage = result.ok
            ? nil
            : (result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "工具调用失败。")
        let shellExecution = ExampleChatShellTranscriptDisplaySupport.shellExecution(
            for: result,
            existing: existing?.shellExecution
        ) ?? existing?.shellExecution
        let commandExecution = ExampleChatShellTranscriptDisplaySupport.commandExecution(
            for: result,
            existing: existing?.commandExecution
        ) ?? existing?.commandExecution
        let item = AssistantSupportActivityItem(
            id: result.callID,
            sourceBlockID: block.id.uuidString,
            type: "chatToolCall",
            server: "workspace",
            tool: result.name.rawValue,
            arguments: existing?.arguments,
            result: existing?.result,
            error: errorMessage,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detailText: detailText?.trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            completed: true,
            durationMilliseconds: durationMilliseconds,
            startedAtMilliseconds: startedAtMilliseconds
                ?? existing?.startedAtMilliseconds
                ?? block.startedAtMilliseconds,
            completedAtMilliseconds: completedAtMilliseconds,
            previewItems: resolvedPreviewItems,
            chatToolName: result.name.rawValue,
            chatToolBatchID: chatToolBatchID ?? existing?.chatToolBatchID ?? block.chatToolBatchID,
            shellExecution: shellExecution,
            commandExecution: commandExecution
        )
        upsertActivityItem(item, in: &block)
    }

    static func milliseconds(since1970 date: Date) -> Int {
        max(0, Int(date.timeIntervalSince1970 * 1000))
    }

    static func trimmedNonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isProcessingBlockKind(_ kind: AssistantSupportBlock.Kind) -> Bool {
        isActivityBlockKind(kind)
    }

    private static func isActivityBlockKind(_ kind: AssistantSupportBlock.Kind) -> Bool {
        kind == .chatToolCall
            || kind == .chatProgress
            || kind == .chatVideoProgress
            || kind == .searchResults
    }

    private static func upsertActivityItem(
        _ item: AssistantSupportActivityItem,
        in block: inout AssistantSupportBlock
    ) {
        if let index = block.activityItems.firstIndex(where: { $0.id == item.id }) {
            block.activityItems[index] = item
        } else {
            block.activityItems.append(item)
        }
    }
}
