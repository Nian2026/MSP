@testable import MSPAgentBridge

extension MSPCompactionHistoryRewriterTests {
    static func message(
        role: String,
        text: String,
        contentType: String = "input_text"
    ) -> MSPAgentJSONValue {
        message(
            role: role,
            content: [
                content(type: contentType, text: text)
            ]
        )
    }

    static func message(
        role: String,
        content: [MSPAgentJSONValue]
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .array(content)
        ])
    }

    static func content(type: String, text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string(type),
            "text": .string(text)
        ])
    }

    static func imageContent(_ imageURL: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("input_image"),
            "image_url": .string(imageURL)
        ])
    }

    static func functionCallOutput(
        callID: String,
        output: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(output)
        ])
    }

    static func customToolCallOutput(
        callID: String,
        name: String,
        output: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("custom_tool_call_output"),
            "call_id": .string(callID),
            "name": .string(name),
            "output": .string(output)
        ])
    }

    static func toolSearchOutput(
        callID: String,
        status: String,
        execution: String,
        tools: [MSPAgentJSONValue]
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("tool_search_output"),
            "call_id": .string(callID),
            "status": .string(status),
            "execution": .string(execution),
            "tools": .array(tools)
        ])
    }

    static func item(type: String) -> MSPAgentJSONValue {
        .object([
            "type": .string(type)
        ])
    }

    static func agentMessage(text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("agent_message"),
            "content": .array([
                content(type: "output_text", text: text)
            ])
        ])
    }

    static func compactionOutput(encryptedContent: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("compaction"),
            "encrypted_content": .string(encryptedContent)
        ])
    }

    static func contextCompaction(id: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("context_compaction"),
            "id": .string(id)
        ])
    }

    static func turnContext(
        turnID: String,
        model: String,
        compHash: String? = nil,
        realtimeActive: Bool? = nil
    ) -> MSPCompactionTurnContextSnapshot {
        MSPCompactionTurnContextSnapshot(
            turnID: turnID,
            cwd: "/workspace",
            workspaceRoots: ["/workspace"],
            currentDate: "2026-07-01",
            timezone: "Asia/Shanghai",
            approvalPolicy: "never",
            sandboxPolicy: "danger-full-access",
            model: model,
            compHash: compHash,
            realtimeActive: realtimeActive
        )
    }

    static func checkpoint(
        replacementHistory: [MSPAgentJSONValue]
    ) throws -> MSPCompactionCheckpoint {
        try MSPCompactionCheckpointBuilder.checkpoint(
            checkpointID: "checkpoint-1",
            sourceItems: [
                message(role: "user", text: "old user")
            ],
            replacementHistory: replacementHistory,
            summaryRef: nil,
            lineage: lineage()
        )
    }

    static func chatCheckpoint(
        checkpointID: String = "checkpoint-1",
        replacementHistory: [MSPAgentJSONValue]? = nil,
        replacementHistoryRef: String? = nil,
        replacementHistoryHash: String? = nil,
        summaryText: String? = nil,
        replayMode: MSPCompactionReplayMode = .exact
    ) throws -> MSPCompactionCheckpoint {
        MSPCompactionCheckpoint(
            checkpointID: checkpointID,
            sourceRange: MSPCompactionSourceRange(sourceHash: "source-hash"),
            replacementHistory: replacementHistory,
            replacementHistoryRef: replacementHistoryRef,
            replacementHistoryHash: replacementHistoryHash,
            summaryText: summaryText,
            lineage: lineage(),
            replayMode: replayMode
        )
    }

    static func lineage() -> MSPCompactionWindowLineage {
        MSPCompactionWindowLineage(
            windowNumber: 1,
            firstWindowID: "window-0",
            previousWindowID: "window-0",
            currentWindowID: "window-1"
        )
    }

    static func signatures(from items: [MSPAgentJSONValue]) -> [String] {
        items.map { item in
            let object = item.objectValue ?? [:]
            return [
                object["role"]?.stringValue ?? object["type"]?.stringValue ?? "",
                messageText(item)
            ].joined(separator: ":")
        }
    }

    static func messageTexts(from items: [MSPAgentJSONValue]) -> [String] {
        items.map(messageText)
    }

    static func messageText(_ item: MSPAgentJSONValue) -> String {
        guard let content = item.objectValue?["content"]?.arrayValue else {
            return ""
        }
        return content.compactMap { $0.objectValue?["text"]?.stringValue }
            .joined(separator: "\n")
    }
}
