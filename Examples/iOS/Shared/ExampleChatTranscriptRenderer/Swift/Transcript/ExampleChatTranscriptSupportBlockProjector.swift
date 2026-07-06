import Foundation

enum ExampleChatTranscriptSupportBlockProjector {
    static func supportBlockPayload(_ block: AssistantSupportBlock) -> [String: Any] {
        var payload = encodableObject(block)
        removeLegacySchemaKeys(from: &payload)
        payload["id"] = block.id.uuidString
        payload["kind"] = chatKind(for: block.kind)
        payload["text"] = block.text ?? NSNull()
        payload["detailText"] = block.detailText ?? NSNull()
        payload["durationMilliseconds"] = block.durationMilliseconds ?? NSNull()
        payload["startedAtMilliseconds"] = block.startedAtMilliseconds ?? NSNull()
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatTurnStartedAtMilliseconds",
            value: block.chatTurnStartedAtMilliseconds ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatTurnDurationMilliseconds",
            value: block.chatTurnDurationMilliseconds ?? NSNull()
        )
        payload["summaryParts"] = block.summaryParts
        payload["summaryDurationsMilliseconds"] = block.summaryDurationsMilliseconds
        payload["searchQueries"] = block.searchQueries
        payload["searchReferences"] = block.searchReferences.map(encodableObject)
        payload["webSearchActions"] = block.webSearchActions.map(encodableObject)
        payload["images"] = block.images.map(encodableObject)
        payload["previewItems"] = block.previewItems.map(encodableObject)
        payload["items"] = block.activityItems.map {
            activityItemPayload($0, extraShellExecutionFields: [
                "user": "user@workspace",
                "sigil": "%"
            ])
        }
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatToolName",
            value: block.chatToolName ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatToolBatchID",
            value: block.chatToolBatchID?.uuidString ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProgressSegmentID",
            value: block.chatProgressSegmentID?.uuidString ?? NSNull()
        )
        payload["status"] = block.status ?? NSNull()
        payload["workedForItem"] = block.workedForItem.map(encodableObject) ?? NSNull()
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatTransferTaskID",
            value: block.chatTransferTaskID?.uuidString ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProcessingGroupId",
            value: block.chatProcessingGroupID ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProcessingChromeRole",
            value: block.chatProcessingChromeRole ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProcessingFoldGroupId",
            value: block.chatProcessingFoldGroupID ?? NSNull()
        )
        return payload
    }

    static func activityItemPayload(
        _ item: AssistantSupportActivityItem,
        extraShellExecutionFields: [String: Any] = [:]
    ) -> [String: Any] {
        var payload = encodableObject(item)
        payload["sourceBlockId"] = item.sourceBlockID ?? NSNull()
        payload["type"] = chatActivityItemType(item.type)
        payload["server"] = item.server ?? NSNull()
        payload["tool"] = item.tool ?? NSNull()
        payload["text"] = item.text ?? NSNull()
        payload["subtitleText"] = item.subtitleText ?? NSNull()
        payload["detailText"] = item.detailText ?? NSNull()
        payload["status"] = item.status ?? NSNull()
        payload["completed"] = item.completed ?? NSNull()
        payload["durationMilliseconds"] = item.durationMilliseconds ?? NSNull()
        payload["startedAtMilliseconds"] = item.startedAtMilliseconds ?? NSNull()
        payload["completedAtMilliseconds"] = item.completedAtMilliseconds ?? NSNull()
        payload["summaryParts"] = item.summaryParts
        payload["searchQueries"] = item.searchQueries
        payload["searchReferences"] = item.searchReferences.map(encodableObject)
        payload["webSearchActions"] = item.webSearchActions.map(encodableObject)
        payload["previewItems"] = item.previewItems.map(encodableObject)
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatToolName",
            value: item.chatToolName ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatToolBatchID",
            value: item.chatToolBatchID?.uuidString ?? NSNull()
        )
        payload["phase"] = item.phase ?? NSNull()
        payload["childItems"] = item.childItems.map { activityItemPayload($0) }

        if let shellExecution = item.shellExecution {
            var shellPayload = encodableObject(shellExecution)
            for (key, value) in extraShellExecutionFields {
                shellPayload[key] = value
            }
            payload["shellExecution"] = shellPayload
        }
        if let commandExecution = item.commandExecution {
            payload["commandExecution"] = encodableObject(commandExecution)
        }
        return payload
    }

    static func processingBlockPayload(
        _ block: AssistantSupportBlock,
        id: String,
        messageID: String,
        sourceBlockID: String,
        activityItems: [[String: Any]],
        processingActive: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "sourceBlockId": sourceBlockID,
            "messageId": messageID,
            "type": chatKind(for: block.kind),
            "status": block.status ?? NSNull(),
            "text": block.text ?? "",
            "durationMilliseconds": block.durationMilliseconds ?? NSNull(),
            "startedAtMilliseconds": block.startedAtMilliseconds ?? NSNull(),
            "summaryParts": block.summaryParts,
            "summaryDurationsMilliseconds": block.summaryDurationsMilliseconds,
            "searchQueries": block.searchQueries,
            "searchReferences": block.searchReferences.map(encodableObject),
            "webSearchActions": block.webSearchActions.map(encodableObject),
            "attachments": [],
            "images": block.images.map(encodableObject),
            "previewItems": block.previewItems.map(encodableObject),
            "items": activityItems,
        ]
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatTurnStartedAtMilliseconds",
            value: block.chatTurnStartedAtMilliseconds ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatTurnDurationMilliseconds",
            value: block.chatTurnDurationMilliseconds ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatToolName",
            value: block.chatToolName ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatToolBatchID",
            value: block.chatToolBatchID?.uuidString ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProcessingActive",
            value: processingActive
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProcessingGroupId",
            value: block.chatProcessingGroupID ?? NSNull()
        )
        setChatSchemaValue(
            in: &payload,
            chatKey: "chatProcessingChromeRole",
            value: block.chatProcessingChromeRole ?? NSNull()
        )
        return payload
    }

    private static func encodableObject<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func setChatSchemaValue(
        in payload: inout [String: Any],
        chatKey: String,
        value: Any
    ) {
        payload[chatKey] = value
    }

    private static func removeLegacySchemaKeys(from payload: inout [String: Any]) {
        [
            "readexTurnStartedAtMilliseconds",
            "readexTurnDurationMilliseconds",
            "readexToolName",
            "readexToolBatchID",
            "readexProgressSegmentID",
            "readexTransferTaskID",
            "readexProcessingGroupId",
            "readexProcessingGroupID",
            "readexProcessingChromeRole",
            "readexProcessingFoldGroupId",
            "readexProcessingFoldGroupID",
            "readexProcessingActive"
        ].forEach { payload.removeValue(forKey: $0) }
    }

    private static func chatKind(for kind: AssistantSupportBlock.Kind) -> String {
        switch kind {
        case .chatProcessing:
            return "chat_processing"
        case .chatProgress:
            return "chat_progress"
        case .chatVideoProgress:
            return "chat_video_progress"
        case .chatToolCall:
            return "chat_tool_call"
        case .chatStoppedMarker:
            return "chat_stopped_marker"
        case .thinking,
             .reasoningSummary,
             .searchResults,
             .textSegment,
             .proposedPlan,
             .image:
            return kind.rawValue
        }
    }

    private static func chatActivityItemType(_ type: String) -> String {
        switch type {
        case "chatToolCall":
            return "chatToolCall"
        case "chat_tool_call":
            return "chat_tool_call"
        case "readexToolCall":
            return "chatToolCall"
        case "readex_tool_call":
            return "chat_tool_call"
        default:
            return type
        }
    }

}
