import Foundation

struct ExampleChatStreamingToolStartedPresentation {
    var blocks: [AssistantSupportBlock]
    var activeBlockID: UUID
    var activeStartedAt: Date
}

struct ExampleChatStreamingToolFinalizedPresentation {
    var blocks: [AssistantSupportBlock]
}

enum ExampleChatStreamingToolPresentationHelper {
    static func startedPresentation(
        in existingBlocks: [AssistantSupportBlock],
        activeBlockID: UUID?,
        activeStartedAt: Date?,
        text: String,
        detailText: String?,
        previewItems: [AssistantSupportPreviewItem],
        chatToolCall: ExampleChatToolCall?,
        chatToolName: ExampleChatToolName?,
        chatToolBatchID: UUID?,
        processingStartedAtMilliseconds: Int?,
        at date: Date = .now
    ) -> ExampleChatStreamingToolStartedPresentation? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let chatToolNameValue = chatToolName?.rawValue ?? chatToolCall?.name.rawValue
        let startedAt = activeStartedAt ?? date
        let startedAtMilliseconds = ExampleChatStreamingSupportBlockPresentationHelper.milliseconds(since1970: startedAt)
        var blocks = existingBlocks

        if let activeBlockID,
           let index = blocks.firstIndex(where: { $0.id == activeBlockID }) {
            updateStartedToolBlock(
                &blocks[index],
                text: trimmedText,
                detailText: detailText,
                previewItems: previewItems,
                chatToolCall: chatToolCall,
                chatToolNameValue: chatToolNameValue,
                chatToolBatchID: chatToolBatchID,
                processingStartedAtMilliseconds: processingStartedAtMilliseconds,
                startedAtMilliseconds: startedAtMilliseconds
            )
            return ExampleChatStreamingToolStartedPresentation(
                blocks: blocks,
                activeBlockID: activeBlockID,
                activeStartedAt: startedAt
            )
        }

        var block = startedToolBlock(
            text: trimmedText,
            detailText: detailText,
            previewItems: previewItems,
            chatToolNameValue: chatToolNameValue,
            chatToolBatchID: chatToolBatchID,
            processingStartedAtMilliseconds: processingStartedAtMilliseconds
        )
        if let chatToolCall {
            ExampleChatStreamingSupportBlockPresentationHelper.upsertToolActivityItem(
                in: &block,
                call: chatToolCall,
                text: trimmedText,
                detailText: detailText,
                status: "inProgress",
                completed: false,
                startedAtMilliseconds: startedAtMilliseconds,
                previewItems: previewItems,
                chatToolBatchID: chatToolBatchID
            )
        }
        blocks.append(block)
        return ExampleChatStreamingToolStartedPresentation(
            blocks: blocks,
            activeBlockID: block.id,
            activeStartedAt: startedAt
        )
    }

    static func finalizedPresentation(
        in existingBlocks: [AssistantSupportBlock],
        activeBlockID: UUID?,
        targetBlockID: UUID,
        activeStartedAt: Date?,
        explicitStartedAt: Date?,
        text: String?,
        detailText: String?,
        previewItems: [AssistantSupportPreviewItem],
        chatToolName: ExampleChatToolName?,
        chatToolBatchID: UUID?,
        result: ExampleChatToolResult?,
        at date: Date = .now
    ) -> ExampleChatStreamingToolFinalizedPresentation? {
        var blocks = existingBlocks
        guard let index = blocks.firstIndex(where: { $0.id == targetBlockID }) else { return nil }

        if let text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalizedDetail = detailText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        blocks[index].detailText = normalizedDetail.isEmpty ? nil : normalizedDetail
        if !previewItems.isEmpty {
            blocks[index].previewItems = previewItems
        }
        if let chatToolName {
            blocks[index].chatToolName = chatToolName.rawValue
        }
        if let chatToolBatchID {
            blocks[index].chatToolBatchID = chatToolBatchID
        }

        let startedAt = explicitStartedAt
            ?? (activeBlockID == targetBlockID ? activeStartedAt : nil)
        let durationMilliseconds = startedAt
            .map { max(100, Int(date.timeIntervalSince($0) * 1000)) }
            ?? 100
        blocks[index].durationMilliseconds = durationMilliseconds
        blocks[index].status = result?.ok == false ? "failed" : "completed"

        if let result {
            ExampleChatStreamingSupportBlockPresentationHelper.upsertToolActivityItem(
                in: &blocks[index],
                result: result,
                text: blocks[index].text ?? "",
                detailText: blocks[index].detailText,
                status: result.ok ? "completed" : "failed",
                startedAtMilliseconds: startedAt.map {
                    ExampleChatStreamingSupportBlockPresentationHelper.milliseconds(since1970: $0)
                },
                completedAtMilliseconds: ExampleChatStreamingSupportBlockPresentationHelper.milliseconds(since1970: date),
                durationMilliseconds: durationMilliseconds,
                previewItems: blocks[index].previewItems,
                chatToolBatchID: chatToolBatchID
            )
        }

        return ExampleChatStreamingToolFinalizedPresentation(blocks: blocks)
    }

    static func discardingActiveToolBlock(
        in existingBlocks: [AssistantSupportBlock],
        activeBlockID: UUID?
    ) -> [AssistantSupportBlock] {
        guard let activeBlockID else { return existingBlocks }
        var blocks = existingBlocks
        blocks.removeAll { $0.id == activeBlockID }
        return blocks
    }

    private static func startedToolBlock(
        text: String,
        detailText: String?,
        previewItems: [AssistantSupportPreviewItem],
        chatToolNameValue: String?,
        chatToolBatchID: UUID?,
        processingStartedAtMilliseconds: Int?
    ) -> AssistantSupportBlock {
        AssistantSupportBlock(
            kind: .chatToolCall,
            text: text,
            detailText: detailText?.trimmingCharacters(in: .whitespacesAndNewlines),
            durationMilliseconds: nil,
            startedAtMilliseconds: processingStartedAtMilliseconds,
            previewItems: previewItems,
            chatToolName: chatToolNameValue,
            chatToolBatchID: chatToolBatchID,
            status: "inProgress"
        )
    }

    private static func updateStartedToolBlock(
        _ block: inout AssistantSupportBlock,
        text: String,
        detailText: String?,
        previewItems: [AssistantSupportPreviewItem],
        chatToolCall: ExampleChatToolCall?,
        chatToolNameValue: String?,
        chatToolBatchID: UUID?,
        processingStartedAtMilliseconds: Int?,
        startedAtMilliseconds: Int
    ) {
        block.text = text
        block.detailText = detailText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previewItems.isEmpty {
            block.previewItems = previewItems
        }
        if let chatToolNameValue {
            block.chatToolName = chatToolNameValue
        }
        if let chatToolBatchID {
            block.chatToolBatchID = chatToolBatchID
        }
        block.status = "inProgress"
        if block.startedAtMilliseconds == nil {
            block.startedAtMilliseconds = processingStartedAtMilliseconds
        }
        if let chatToolCall {
            ExampleChatStreamingSupportBlockPresentationHelper.upsertToolActivityItem(
                in: &block,
                call: chatToolCall,
                text: text,
                detailText: detailText,
                status: "inProgress",
                completed: false,
                startedAtMilliseconds: startedAtMilliseconds,
                previewItems: previewItems,
                chatToolBatchID: chatToolBatchID
            )
        }
    }
}
