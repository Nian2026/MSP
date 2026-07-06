import Foundation

enum ExampleChatTranscriptPayloadFactory {
    static func renderState(
        from items: [MSPAgentTimelineItem],
        isGenerating: Bool,
        expandToolActivityBlocks: Bool = false,
        fontScale: Double = 1
    ) -> ExampleChatTranscriptRenderState {
        ExampleChatTranscriptRenderState(
            payload: payload(
                from: items,
                isGenerating: isGenerating,
                expandToolActivityBlocks: expandToolActivityBlocks,
                fontScale: fontScale
            ),
            presentation: presentation(isGenerating: isGenerating, fontScale: fontScale),
            isGenerating: isGenerating
        )
    }

    static func payload(
        from items: [MSPAgentTimelineItem],
        isGenerating: Bool = false,
        expandToolActivityBlocks: Bool = false,
        fontScale: Double = 1
    ) -> [String: Any] {
        let messages = buildMessages(from: items, isGenerating: isGenerating)
        let messageGroups = messages.compactMap { message -> [String: Any]? in
            guard let id = message["id"] as? String,
                  let role = message["role"] as? String else {
                return nil
            }
            return [
                "id": "group-\(id)",
                "role": role,
                "messageIDs": [id]
            ]
        }
        let expandedToolActivityBlockIDs = expandToolActivityBlocks
            ? toolActivityBlockIDs(from: messages)
            : []

        return [
            "conversationTitle": "MSP Playground",
            "theme": "light",
            "chatMarkdownRendererProfile": NSNull(),
            "style": style(fontScale: fontScale),
            "displayWindow": NSNull(),
            "expandedExampleChatProcessingBlockIDs": [],
            "collapsedExampleChatProcessingBlockIDs": [],
            "expandedExampleChatToolActivityBlockIDs": expandedToolActivityBlockIDs,
            "collapsedExampleChatToolActivityBlockIDs": [],
            "expandedExampleChatNestedDisclosureKeysBySourceBlockID": [:],
            "collapsedExampleChatNestedDisclosureKeysBySourceBlockID": [:],
            "messages": messages,
            "blockCatalog": [],
            "messageGroups": messageGroups
        ]
    }

    private static func toolActivityBlockIDs(from messages: [[String: Any]]) -> [String] {
        messages.flatMap { message -> [String] in
            guard let supportBlocks = message["supportBlocks"] as? [[String: Any]] else {
                return []
            }
            return supportBlocks.compactMap { block -> String? in
                guard isToolCallSupportKind(block["kind"] as? String) else {
                    return nil
                }
                return block["sourceBlockId"] as? String
                    ?? block["sourceBlockID"] as? String
                    ?? block["id"] as? String
            }
        }
    }

    static func presentation(
        isGenerating: Bool,
        fontScale: Double = 1
    ) -> [String: Any] {
        var presentation = ExampleChatTranscriptThemePreset.presentation(isGenerating: isGenerating)
        setPixelValues(
            in: &presentation,
            values: [
                "bodyFontSize": MSPPlaygroundTypography.transcriptBodyFontSize,
                "roleFontSize": MSPPlaygroundTypography.transcriptRoleFontSize,
                "metaFontSize": MSPPlaygroundTypography.transcriptMetaFontSize,
                "supportFontSize": MSPPlaygroundTypography.transcriptSupportFontSize,
                "historyEditorFontSize": MSPPlaygroundTypography.transcriptHistoryEditorFontSize
            ]
        )
        let scale = MSPPlaygroundTypography.clampedScale(fontScale)
        scalePixelValues(
            in: &presentation,
            keys: [
                "bodyFontSize",
                "roleFontSize",
                "metaFontSize",
                "supportFontSize",
                "historyEditorFontSize"
            ],
            by: scale
        )
        presentation["style"] = style(fontScale: scale)
        return presentation
    }

    private static func style(fontScale: Double) -> [String: Any] {
        var style = ExampleChatTranscriptThemePreset.style()
        setPixelValues(
            in: &style,
            values: [
                "chatThinkingIndicatorFontSize": MSPPlaygroundTypography.transcriptThinkingIndicatorFontSize,
                "chatToolActivityFontSize": MSPPlaygroundTypography.transcriptToolActivityFontSize
            ]
        )
        scalePixelValues(
            in: &style,
            keys: [
                "chatThinkingIndicatorFontSize",
                "chatToolActivityFontSize"
            ],
            by: MSPPlaygroundTypography.clampedScale(fontScale)
        )
        return style
    }

    private static func isToolCallSupportKind(_ kind: String?) -> Bool {
        kind == "chat_tool_call" || kind == "readex_tool_call"
    }

    private static func setPixelValues(
        in object: inout [String: Any],
        values: [String: Double]
    ) {
        for (key, value) in values {
            object[key] = value
        }
    }

    private static func scalePixelValues(
        in object: inout [String: Any],
        keys: [String],
        by scale: Double
    ) {
        for key in keys {
            guard let value = object[key] as? Double else {
                continue
            }
            object[key] = value * scale
        }
    }

    private static func buildMessages(
        from items: [MSPAgentTimelineItem],
        isGenerating: Bool
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var assistantGroup: [MSPAgentTimelineItem] = []
        var lastUserTurnStartedAt: Int?
        var lastItemWasUser = false

        func flushAssistantGroup() {
            guard !assistantGroup.isEmpty else {
                return
            }
            messages.append(assistantMessage(
                from: assistantGroup,
                index: messages.count,
                isGenerating: isGenerating,
                activeTurnStartedAt: nil
            ))
            assistantGroup.removeAll()
        }

        for item in items {
            switch item.kind {
            case .user:
                flushAssistantGroup()
                lastUserTurnStartedAt = item.turnStartedAtMilliseconds
                lastItemWasUser = true
                messages.append(message(
                    id: "message-\(item.id.uuidString)",
                    role: "user",
                    text: item.body,
                    status: "success"
                ))
            case .system:
                continue
            case .assistantProgress, .toolCall, .toolResult, .assistantFinal, .error:
                lastItemWasUser = false
                assistantGroup.append(item)
            }
        }
        flushAssistantGroup()
        if isGenerating,
           lastItemWasUser,
           let lastUserTurnStartedAt {
            messages.append(assistantMessage(
                from: [],
                index: messages.count,
                isGenerating: true,
                activeTurnStartedAt: lastUserTurnStartedAt
            ))
        }

        return messages
    }

    private static func assistantMessage(
        from items: [MSPAgentTimelineItem],
        index: Int,
        isGenerating: Bool,
        activeTurnStartedAt: Int?
    ) -> [String: Any] {
        let messageID = "assistant-group-\(index)"
        var supportBlocks: [AssistantSupportBlock] = []
        var errorBlocks: [[String: Any]] = []
        var finalParts: [String] = []
        let turnStartedAt = activeTurnStartedAt ?? firstTurnStartedAt(in: items)
        let appendsPendingThinkingBlock = shouldAppendPendingThinkingBlock(
            to: items,
            isGenerating: isGenerating,
            turnStartedAtMilliseconds: turnStartedAt
        )

        for (itemIndex, item) in items.enumerated() {
            switch item.kind {
            case .assistantProgress:
                supportBlocks.append(progressSupportBlock(
                    from: item,
                    completed: processingItemIsCompleted(
                        in: items,
                        at: itemIndex,
                        isGenerating: isGenerating,
                        hasPendingThinkingBlock: appendsPendingThinkingBlock
                    )
                ))
            case .toolCall:
                supportBlocks.append(toolSupportBlock(
                    item,
                    completed: processingItemIsCompleted(
                        in: items,
                        at: itemIndex,
                        isGenerating: isGenerating,
                        hasPendingThinkingBlock: appendsPendingThinkingBlock
                    )
                ))
            case .toolResult:
                supportBlocks.append(toolSupportBlock(item, completed: true))
            case .assistantFinal:
                finalParts.append(item.body)
            case .error:
                errorBlocks.append(errorMessageBlock(
                    id: "\(messageID):error-\(item.id.uuidString)",
                    messageID: messageID,
                    text: item.body
                ))
            case .system, .user:
                break
            }
        }

        if appendsPendingThinkingBlock,
           let turnStartedAt {
            supportBlocks.append(pendingThinkingSupportBlock(turnStartedAtMilliseconds: turnStartedAt))
        }

        let finalText = finalParts.joined(separator: "\n\n")
        if supportBlocks.isEmpty
            && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && errorBlocks.isEmpty {
            errorBlocks.append(messageBlock(
                id: "\(messageID):fallback",
                messageID: messageID,
                type: "main_text",
                text: items.map(\.body).joined(separator: "\n\n"),
                status: "success"
            ))
        }

        return legacyAssistantMessage(
            id: messageID,
            content: finalText,
            supportBlocks: supportBlocks,
            errorBlocks: errorBlocks,
            status: assistantMessageStatus(
                supportBlocks: supportBlocks,
                errorBlocks: errorBlocks,
                isGenerating: isGenerating
            ),
            isStreaming: isGenerating
        )
    }

    private static func assistantMessageStatus(
        supportBlocks: [AssistantSupportBlock],
        errorBlocks: [[String: Any]],
        isGenerating: Bool
    ) -> String {
        if supportBlocks.contains(where: { normalizedStatus($0.status) == "failed" })
            || supportBlocks.flatMap(\.activityItems).contains(where: { normalizedStatus($0.status) == "failed" })
            || errorBlocks.contains(where: { normalizedStatus($0["status"] as? String) == "failed" }) {
            return "failed"
        }
        if isGenerating
            || supportBlocks.contains(where: { normalizedStatus($0.status) == "processing" || normalizedStatus($0.status) == "streaming" })
            || supportBlocks.flatMap(\.activityItems).contains(where: {
                let status = normalizedStatus($0.status)
                return status == "processing" || status == "streaming" || status == "pending"
            }) {
            return "streaming"
        }
        return "success"
    }

    private static func processingItemIsCompleted(
        in items: [MSPAgentTimelineItem],
        at index: Int,
        isGenerating: Bool,
        hasPendingThinkingBlock: Bool
    ) -> Bool {
        guard isGenerating else {
            return true
        }
        if hasPendingThinkingBlock {
            return true
        }
        return items.indices.contains { candidateIndex in
            candidateIndex > index && items[candidateIndex].kind != .system
        }
    }

    private static func shouldAppendPendingThinkingBlock(
        to items: [MSPAgentTimelineItem],
        isGenerating: Bool,
        turnStartedAtMilliseconds: Int?
    ) -> Bool {
        guard isGenerating,
              turnStartedAtMilliseconds != nil else {
            return false
        }
        if items.contains(where: { item in
            item.kind == .assistantFinal || item.kind == .error
        }) {
            return false
        }
        if items.contains(where: { item in
            switch item.kind {
            case .toolCall, .toolResult:
                return normalizedStatus(item.status) == "processing"
            case .system, .user, .assistantProgress, .assistantFinal, .error:
                return false
            }
        }) {
            return false
        }
        return true
    }

    private static func firstTurnStartedAt(in items: [MSPAgentTimelineItem]) -> Int? {
        items.lazy.compactMap(\.turnStartedAtMilliseconds).first
    }

    private static func processingStatus(
        from items: [[String: Any]],
        isGenerating: Bool
    ) -> String {
        if items.contains(where: { normalizedStatus($0["status"] as? String) == "failed" }) {
            return "failed"
        }
        if items.contains(where: { ($0["completed"] as? Bool) == false }) || isGenerating {
            return "processing"
        }
        return "success"
    }

    private static func message(
        id: String,
        role: String,
        text: String,
        status: String
    ) -> [String: Any] {
        structuredMessage(
            id: id,
            role: role,
            status: status,
            blocks: [
                messageBlock(
                    id: "\(id):content",
                    messageID: id,
                    type: "main_text",
                    text: text,
                    status: status
                )
            ]
        )
    }

    private static func structuredMessage(
        id: String,
        role: String,
        status: String,
        blocks: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": id,
            "patchKey": "msp:\(id)",
            "role": role,
            "replyToMessageID": NSNull(),
            "title": "",
            "timeText": "",
            "renderHarness": NSNull(),
            "content": "",
            "headerPageSummary": NSNull(),
            "footerPageSummary": NSNull(),
            "branchNoticeText": NSNull(),
            "attachments": [],
            "supportBlocks": [],
            "status": status,
            "isStreaming": false,
            "isSearchInProgress": false,
            "hasRenderPatches": false,
            "hasEnabledRenderPatches": false,
            "expertDomainID": NSNull(),
            "expertDomainName": NSNull(),
            "expertDomainUsesGlobalPrompt": NSNull(),
            "expertRoutingStatus": NSNull(),
            "expertRoutingSummary": NSNull(),
            "expertRoutingReason": NSNull(),
            "expertRoutingFailureMessage": NSNull(),
            "expertRoutingDetail": NSNull(),
            "expertRoutingConfidence": NSNull(),
            "expertRoutingModelName": NSNull(),
            "chatProcessingFoldGroupId": NSNull(),
            "chatTurnID": NSNull(),
            "chatCodexTurnID": NSNull(),
            "completedGoalDurationMilliseconds": NSNull(),
            "blockIDs": blocks.compactMap { $0["id"] as? String },
            "blocks": blocks
        ]
    }

    private static func legacyAssistantMessage(
        id: String,
        content: String,
        supportBlocks: [AssistantSupportBlock],
        errorBlocks: [[String: Any]],
        status: String,
        isStreaming: Bool
    ) -> [String: Any] {
        [
            "id": id,
            "patchKey": "msp:\(id)",
            "role": "assistant",
            "replyToMessageID": NSNull(),
            "title": "",
            "timeText": "",
            "renderHarness": NSNull(),
            "content": content,
            "headerPageSummary": NSNull(),
            "footerPageSummary": NSNull(),
            "branchNoticeText": NSNull(),
            "attachments": [],
            "supportBlocks": supportBlocks.map(ExampleChatTranscriptSupportBlockProjector.supportBlockPayload),
            "status": status,
            "isStreaming": isStreaming,
            "isSearchInProgress": false,
            "hasRenderPatches": false,
            "hasEnabledRenderPatches": false,
            "expertDomainID": NSNull(),
            "expertDomainName": NSNull(),
            "expertDomainUsesGlobalPrompt": NSNull(),
            "expertRoutingStatus": NSNull(),
            "expertRoutingSummary": NSNull(),
            "expertRoutingReason": NSNull(),
            "expertRoutingFailureMessage": NSNull(),
            "expertRoutingDetail": NSNull(),
            "expertRoutingConfidence": NSNull(),
            "expertRoutingModelName": NSNull(),
            "chatProcessingFoldGroupId": NSNull(),
            "chatTurnID": NSNull(),
            "chatCodexTurnID": NSNull(),
            "completedGoalDurationMilliseconds": NSNull(),
            "blockIDs": [],
            "blocks": errorBlocks
        ]
    }

    private static func messageBlock(
        id: String,
        messageID: String,
        type: String,
        text: String,
        status: String
    ) -> [String: Any] {
        [
            "id": id,
            "messageId": messageID,
            "sourceBlockId": NSNull(),
            "type": type,
            "status": status,
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

    private static func progressSupportBlock(
        from item: MSPAgentTimelineItem,
        completed: Bool
    ) -> AssistantSupportBlock {
        AssistantSupportBlock(
            id: item.id,
            kind: .chatProgress,
            text: item.body,
            durationMilliseconds: completed ? (item.durationMilliseconds ?? 100) : nil,
            startedAtMilliseconds: item.startedAtMilliseconds ?? item.turnStartedAtMilliseconds,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            status: completed ? "success" : "streaming",
            chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" },
            chatProcessingChromeRole: "owner"
        )
    }

    private static func pendingThinkingSupportBlock(
        turnStartedAtMilliseconds: Int
    ) -> AssistantSupportBlock {
        let activityID = "msp-thinking-\(turnStartedAtMilliseconds)"
        return AssistantSupportBlock(
            id: syntheticUUID(
                namespace: "8001",
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            ),
            kind: .chatProcessing,
            durationMilliseconds: nil,
            startedAtMilliseconds: turnStartedAtMilliseconds,
            chatTurnStartedAtMilliseconds: turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: nil,
            activityItems: [
                AssistantSupportActivityItem(
                    id: activityID,
                    sourceBlockID: activityID,
                    type: "progress",
                    server: "codex",
                    text: "正在思考",
                    status: "processing",
                    completed: false,
                    durationMilliseconds: nil,
                    startedAtMilliseconds: turnStartedAtMilliseconds,
                    completedAtMilliseconds: nil
                )
            ],
            status: "processing",
            workedForItem: AssistantSupportWorkedForItem(
                status: .working,
                startedAtMilliseconds: turnStartedAtMilliseconds,
                completedAtMilliseconds: nil
            ),
            chatProcessingGroupID: "turn-\(turnStartedAtMilliseconds)"
        )
    }

    private static func syntheticUUID(
        namespace: String,
        turnStartedAtMilliseconds: Int
    ) -> UUID {
        let normalizedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespaceGroup = normalizedNamespace.isEmpty ? "8000" : normalizedNamespace
        let maskedMilliseconds = UInt64(max(0, turnStartedAtMilliseconds)) & 0xFFFFFFFFFFFF
        let tail = String(format: "%012llX", maskedMilliseconds)
        return UUID(uuidString: "00000000-0000-4000-\(namespaceGroup)-\(tail)") ?? UUID()
    }

    private static func toolSupportBlock(
        _ item: MSPAgentTimelineItem,
        completed: Bool
    ) -> AssistantSupportBlock {
        let command = commandText(from: item)
        let normalizedStatus = normalizedStatus(item.status)
        let status = normalizedStatus.isEmpty
            ? (completed ? "success" : "processing")
            : normalizedStatus
        let isCompleted = status != "processing" && status != "streaming" && status != "pending"
        let startedAt = item.startedAtMilliseconds ?? item.turnStartedAtMilliseconds
        if isApplyPatchTool(item) {
            return applyPatchToolSupportBlock(
                item: item,
                input: command,
                status: status,
                isCompleted: isCompleted,
                startedAt: startedAt
            )
        }
        let output = shellOutput(from: item)
        let exitCode: Any
        if let itemExitCode = item.exitCode {
            exitCode = itemExitCode
        } else if isCompleted {
            exitCode = 0
        } else {
            exitCode = NSNull()
        }
        let wallTimeSeconds: Any
        if let durationMilliseconds = item.durationMilliseconds {
            wallTimeSeconds = Double(durationMilliseconds) / 1000.0
        } else {
            wallTimeSeconds = NSNull()
        }
        let activityID = item.callID ?? "activity-\(item.id.uuidString)"
        let startedAtMilliseconds = startedAt ?? 0
        let startedAtDate = date(millisecondsSince1970: startedAtMilliseconds)
        let completedAtDate = item.completedAtMilliseconds.map(date(millisecondsSince1970:))
            ?? item.durationMilliseconds.map { startedAtDate.addingTimeInterval(Double($0) / 1000.0) }
            ?? startedAtDate
        let call = ExampleChatToolCall(
            id: activityID,
            name: .shell,
            arguments: [
                "cmd": .string(command),
                "cwd": .string(item.cwd ?? "/")
            ]
        )

        guard let startedPresentation = ExampleChatStreamingToolPresentationHelper.startedPresentation(
            in: [],
            activeBlockID: nil,
            activeStartedAt: startedAtDate,
            text: item.body.isEmpty
                ? ExampleChatShellTranscriptDisplaySupport.shellStartedStatusText(for: call)
                : item.body,
            detailText: item.detail,
            previewItems: [],
            chatToolCall: call,
            chatToolName: .shell,
            chatToolBatchID: item.batchID,
            processingStartedAtMilliseconds: startedAt,
            at: startedAtDate
        ), var supportBlock = startedPresentation.blocks.last else {
            return fallbackToolSupportBlock(
                item: item,
                activityID: activityID,
                command: command,
                output: output,
                exitCode: exitCode as? Int,
                wallTimeSeconds: wallTimeSeconds as? Double,
                status: status,
                isCompleted: isCompleted,
                startedAt: startedAt
            )
        }

        if isCompleted {
            let result = ExampleChatToolResult(
                callID: activityID,
                name: .shell,
                ok: status != "failed" && ((exitCode as? Int) ?? 0) == 0,
                content: .string(output),
                internalContent: ExampleChatShellTranscriptDisplaySupport.internalContent(
                    command: command,
                    cwd: item.cwd ?? "/",
                    exitCode: exitCode as? Int,
                    wallTimeSeconds: wallTimeSeconds as? Double,
                    output: output,
                    rawOutput: output
                ),
                errorMessage: status == "failed" ? (item.detail ?? output) : nil
            )
            let completedText = item.body.isEmpty || item.body == "正在执行工作区命令"
                ? ExampleChatShellTranscriptDisplaySupport.shellCompletedStatusText(
                    for: result,
                    existing: supportBlock.activityItems.first?.shellExecution
                )
                : item.body
            if let finalizedPresentation = ExampleChatStreamingToolPresentationHelper.finalizedPresentation(
                in: startedPresentation.blocks,
                activeBlockID: startedPresentation.activeBlockID,
                targetBlockID: startedPresentation.activeBlockID,
                activeStartedAt: startedPresentation.activeStartedAt,
                explicitStartedAt: startedAtDate,
                text: completedText,
                detailText: item.detail,
                previewItems: [],
                chatToolName: .shell,
                chatToolBatchID: item.batchID,
                result: result,
                at: completedAtDate
            ), let finalizedBlock = finalizedPresentation.blocks.last {
                supportBlock = finalizedBlock
            }
        }

        let activityItem = AssistantSupportActivityItem(
            id: activityID,
            sourceBlockID: "activity-\(item.id.uuidString)",
            type: "chatToolCall",
            server: "workspace",
            tool: "workspace.shell",
            arguments: .object([
                "cmd": .string(command),
                "cwd": .string(item.cwd ?? "/")
            ]),
            error: status == "failed" ? (item.detail ?? output) : nil,
            text: supportBlock.activityItems.last?.text ?? supportBlock.text,
            subtitleText: command.isEmpty ? nil : command,
            detailText: item.detail,
            status: supportBlock.activityItems.last?.status ?? supportBlock.status,
            completed: isCompleted,
            durationMilliseconds: supportBlock.activityItems.last?.durationMilliseconds ?? supportBlock.durationMilliseconds,
            startedAtMilliseconds: supportBlock.activityItems.last?.startedAtMilliseconds ?? supportBlock.startedAtMilliseconds,
            completedAtMilliseconds: item.completedAtMilliseconds,
            chatToolName: "workspace.shell",
            chatToolBatchID: item.batchID,
            shellExecution: supportBlock.activityItems.last?.shellExecution,
            commandExecution: supportBlock.activityItems.last?.commandExecution
        )
        return AssistantSupportBlock(
            id: item.id,
            kind: .chatToolCall,
            text: supportBlock.text,
            detailText: supportBlock.detailText,
            durationMilliseconds: supportBlock.durationMilliseconds,
            startedAtMilliseconds: supportBlock.startedAtMilliseconds ?? startedAt,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            previewItems: supportBlock.previewItems,
            activityItems: [activityItem],
            chatToolName: "workspace.shell",
            chatToolBatchID: item.batchID,
            status: supportBlock.status,
            workedForItem: supportBlock.workedForItem,
            chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" },
            chatProcessingChromeRole: "owner"
        )
    }

    private static func isApplyPatchTool(_ item: MSPAgentTimelineItem) -> Bool {
        let normalizedName = item.toolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedName == "apply_patch" || normalizedName == "readex.apply_patch"
    }

    private static func applyPatchToolSupportBlock(
        item: MSPAgentTimelineItem,
        input: String,
        status: String,
        isCompleted: Bool,
        startedAt: Int?
    ) -> AssistantSupportBlock {
        let activityID = item.callID ?? "activity-\(item.id.uuidString)"
        let arguments: ExampleChatJSONValue? = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : .object(["input": .string(input)])
        let activityItem = AssistantSupportActivityItem(
            id: activityID,
            sourceBlockID: "activity-\(item.id.uuidString)",
            type: "chatToolCall",
            server: "codex",
            tool: "apply_patch",
            arguments: arguments,
            error: status == "failed" ? item.detail : nil,
            text: item.body,
            detailText: item.detail,
            status: status,
            completed: isCompleted,
            durationMilliseconds: item.durationMilliseconds,
            startedAtMilliseconds: startedAt,
            completedAtMilliseconds: item.completedAtMilliseconds,
            previewItems: item.previewItems,
            chatToolName: "apply_patch",
            chatToolBatchID: item.batchID
        )
        return AssistantSupportBlock(
            id: item.id,
            kind: .chatToolCall,
            text: item.body,
            detailText: item.detail,
            durationMilliseconds: item.durationMilliseconds,
            startedAtMilliseconds: startedAt,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            previewItems: item.previewItems,
            activityItems: [activityItem],
            chatToolName: "apply_patch",
            chatToolBatchID: item.batchID,
            status: status,
            chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" },
            chatProcessingChromeRole: "owner"
        )
    }

    private static func fallbackToolSupportBlock(
        item: MSPAgentTimelineItem,
        activityID: String,
        command: String,
        output: String,
        exitCode: Int?,
        wallTimeSeconds: Double?,
        status: String,
        isCompleted: Bool,
        startedAt: Int?
    ) -> AssistantSupportBlock {
        let action = ExampleChatWorkspaceShellTranscriptDisplaySupport.shellCommandAction(for: command)
        let shellExecution = AssistantSupportShellExecution(
            command: command,
            cwd: item.cwd ?? "/",
            kind: action.type,
            target: action.path,
            query: action.query,
            exitCode: exitCode,
            wallTimeSeconds: wallTimeSeconds,
            output: isCompleted ? output : nil,
            rawOutput: isCompleted ? output : nil
        )
        let commandExecution = AssistantSupportCommandExecution(
            id: activityID,
            callID: activityID,
            cwd: item.cwd ?? "/",
            command: command,
            commandActions: [ExampleChatShellTranscriptDisplaySupport.shellCommandAction(for: command)],
            aggregatedOutput: isCompleted ? output : nil,
            exitCode: exitCode,
            status: status,
            wallTimeSeconds: wallTimeSeconds
        )
        let activityItem = AssistantSupportActivityItem(
            id: activityID,
            sourceBlockID: "activity-\(item.id.uuidString)",
            type: "chatToolCall",
            server: "workspace",
            tool: "workspace.shell",
            arguments: .object([
                "cmd": .string(command),
                "cwd": .string(item.cwd ?? "/")
            ]),
            error: status == "failed" ? (item.detail ?? output) : nil,
            text: item.body,
            subtitleText: command.isEmpty ? nil : command,
            detailText: item.detail,
            status: status,
            completed: isCompleted,
            durationMilliseconds: item.durationMilliseconds,
            startedAtMilliseconds: startedAt,
            completedAtMilliseconds: item.completedAtMilliseconds,
            chatToolName: "workspace.shell",
            chatToolBatchID: item.batchID,
            shellExecution: shellExecution,
            commandExecution: commandExecution
        )
        return AssistantSupportBlock(
            id: item.id,
            kind: .chatToolCall,
            text: item.body,
            detailText: item.detail,
            durationMilliseconds: item.durationMilliseconds,
            startedAtMilliseconds: startedAt,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            activityItems: [activityItem],
            chatToolName: "workspace.shell",
            chatToolBatchID: item.batchID,
            status: status,
            chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" },
            chatProcessingChromeRole: "owner"
        )
    }

    private static func errorMessageBlock(
        id: String,
        messageID: String,
        text: String
    ) -> [String: Any] {
        messageBlock(
            id: id,
            messageID: messageID,
            type: "main_text",
            text: text,
            status: "failed"
        )
    }

    private static func commandText(from item: MSPAgentTimelineItem) -> String {
        if let command = item.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return command
        }
        guard let detail = item.detail else {
            return ""
        }
        if let line = detail.split(separator: "\n").compactMap(detailCommandText).first {
            return line
        }
        return ""
    }

    private static func detailCommandText(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["cmd:", "命令:"] where trimmed.hasPrefix(prefix) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let command = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        return nil
    }

    private static func shellOutput(from item: MSPAgentTimelineItem) -> String {
        let stdout = item.stdout ?? ""
        let stderr = item.stderr ?? ""
        if stdout.isEmpty {
            return stderr
        }
        if stderr.isEmpty {
            return stdout
        }
        if stdout.hasSuffix("\n") {
            return stdout + stderr
        }
        return stdout + "\n" + stderr
    }

    private static func commandActionPayload(for command: String) -> [String: Any] {
        ExampleChatWorkspaceShellTranscriptDisplaySupport
            .shellCommandAction(for: command)
            .payload
    }

    private static func normalizedStatus(_ status: String?) -> String {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inprogress", "running", "processing", "streaming", "pending":
            return "processing"
        case "completed", "complete", "success", "succeeded":
            return "success"
        case "failed", "failure", "error":
            return "failed"
        default:
            return ""
        }
    }

    private static func anyOrNull<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func date(millisecondsSince1970 milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
    }

}
