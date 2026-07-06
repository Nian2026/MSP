import Foundation

struct ExampleChatTranscriptExpansionState: Equatable {
    var expandedExampleChatProcessingBlockIDs: [String] = []
    var collapsedExampleChatProcessingBlockIDs: [String] = []
    var expandedExampleChatToolActivityBlockIDs: [String] = []
    var collapsedExampleChatToolActivityBlockIDs: [String] = []
    var expandedExampleChatNestedDisclosureKeysBySourceBlockID: [String: [String]] = [:]
    var collapsedExampleChatNestedDisclosureKeysBySourceBlockID: [String: [String]] = [:]

    static let empty = ExampleChatTranscriptExpansionState()

    mutating func apply(_ change: ExampleChatTranscriptExpansionStateChange) {
        switch change.kind {
        case .processing:
            Self.set(
                change.sourceBlockID,
                expanded: change.expanded,
                expandedIDs: &expandedExampleChatProcessingBlockIDs,
                collapsedIDs: &collapsedExampleChatProcessingBlockIDs
            )
        case .toolActivity:
            Self.set(
                change.sourceBlockID,
                expanded: change.expanded,
                expandedIDs: &expandedExampleChatToolActivityBlockIDs,
                collapsedIDs: &collapsedExampleChatToolActivityBlockIDs
            )
        case .nestedDisclosure:
            guard let key = change.key else {
                return
            }
            Self.set(
                key,
                sourceBlockID: change.sourceBlockID,
                expanded: change.expanded,
                expandedKeysBySourceBlockID: &expandedExampleChatNestedDisclosureKeysBySourceBlockID,
                collapsedKeysBySourceBlockID: &collapsedExampleChatNestedDisclosureKeysBySourceBlockID
            )
        }
    }

    private static func set(
        _ id: String,
        expanded: Bool,
        expandedIDs: inout [String],
        collapsedIDs: inout [String]
    ) {
        let normalizedID = normalized(id)
        guard !normalizedID.isEmpty else {
            return
        }

        if expanded {
            collapsedIDs.removeAll { $0 == normalizedID }
            appendUnique(normalizedID, to: &expandedIDs)
        } else {
            expandedIDs.removeAll { $0 == normalizedID }
            appendUnique(normalizedID, to: &collapsedIDs)
        }
    }

    private static func set(
        _ key: String,
        sourceBlockID: String,
        expanded: Bool,
        expandedKeysBySourceBlockID: inout [String: [String]],
        collapsedKeysBySourceBlockID: inout [String: [String]]
    ) {
        let normalizedSourceBlockID = normalized(sourceBlockID)
        let normalizedKey = normalized(key)
        guard !normalizedSourceBlockID.isEmpty,
              !normalizedKey.isEmpty else {
            return
        }

        if expanded {
            remove(normalizedKey, for: normalizedSourceBlockID, from: &collapsedKeysBySourceBlockID)
            appendUnique(normalizedKey, for: normalizedSourceBlockID, to: &expandedKeysBySourceBlockID)
        } else {
            remove(normalizedKey, for: normalizedSourceBlockID, from: &expandedKeysBySourceBlockID)
            appendUnique(normalizedKey, for: normalizedSourceBlockID, to: &collapsedKeysBySourceBlockID)
        }
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else {
            return
        }
        values.append(value)
    }

    private static func appendUnique(
        _ value: String,
        for sourceBlockID: String,
        to valuesBySourceBlockID: inout [String: [String]]
    ) {
        var values = valuesBySourceBlockID[sourceBlockID] ?? []
        appendUnique(value, to: &values)
        valuesBySourceBlockID[sourceBlockID] = values
    }

    private static func remove(
        _ value: String,
        for sourceBlockID: String,
        from valuesBySourceBlockID: inout [String: [String]]
    ) {
        guard var values = valuesBySourceBlockID[sourceBlockID] else {
            return
        }
        values.removeAll { $0 == value }
        if values.isEmpty {
            valuesBySourceBlockID.removeValue(forKey: sourceBlockID)
        } else {
            valuesBySourceBlockID[sourceBlockID] = values
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ExampleChatTranscriptExpansionStateChange: Equatable {
    enum Kind: Equatable {
        case processing
        case toolActivity
        case nestedDisclosure
    }

    var kind: Kind
    var sourceBlockID: String
    var key: String?
    var expanded: Bool
}

enum ExampleChatTranscriptPayloadFactory {
    private static let contextCompactionRunningText = "正在自动压缩上下文"
    private static let contextCompactionCompletedText = "上下文已自动压缩"

    static func renderState(
        from items: [MSPAgentTimelineItem],
        isGenerating: Bool,
        expandToolActivityBlocks: Bool = false,
        expansionState: ExampleChatTranscriptExpansionState = .empty,
        fontScale: Double = 1,
        interfaceTheme: PhotoSorterInterfaceTheme = .light
    ) -> ExampleChatTranscriptRenderState {
        ExampleChatTranscriptRenderState(
            payload: payload(
                from: items,
                isGenerating: isGenerating,
                expandToolActivityBlocks: expandToolActivityBlocks,
                expansionState: expansionState,
                fontScale: fontScale,
                interfaceTheme: interfaceTheme
            ),
            imageCacheEntries: imageCacheEntries(from: items),
            presentation: presentation(
                isGenerating: isGenerating,
                fontScale: fontScale,
                interfaceTheme: interfaceTheme
            ),
            isGenerating: isGenerating
        )
    }

    static func streamingToolSupportBlockPayload(
        from item: MSPAgentTimelineItem
    ) -> [String: Any]? {
        guard item.kind == .toolCall || item.kind == .toolResult else {
            return nil
        }
        guard toolItemRendersAsWorkspaceCommand(item) else {
            return nil
        }
        let status = normalizedStatus(item.status)
        let completed = !(status.isEmpty || status == "processing")
        return ExampleChatTranscriptSupportBlockProjector.supportBlockPayload(
            toolSupportBlock(item, completed: completed)
        )
    }

    static func payload(
        from items: [MSPAgentTimelineItem],
        isGenerating: Bool = false,
        expandToolActivityBlocks: Bool = false,
        expansionState: ExampleChatTranscriptExpansionState = .empty,
        fontScale: Double = 1,
        interfaceTheme: PhotoSorterInterfaceTheme = .light
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
        let expandedToolActivityBlockIDs = merged(
            expandToolActivityBlocks
            ? toolActivityBlockIDs(from: messages)
            : autoExpandedToolActivityBlockIDs(from: messages),
            with: expansionState.expandedExampleChatToolActivityBlockIDs
        )
        let expandedNestedDisclosureKeysBySourceBlockID = merged(
            expandToolActivityBlocks
            ? nestedToolActivityDisclosureKeysBySourceBlockID(from: messages, expandsAllShellItems: true)
            : nestedToolActivityDisclosureKeysBySourceBlockID(from: messages, expandsAllShellItems: false),
            with: expansionState.expandedExampleChatNestedDisclosureKeysBySourceBlockID
        )

        return [
            "conversationTitle": "PhotoSorter",
            "theme": interfaceTheme.rawValue,
            "chatMarkdownRendererProfile": NSNull(),
            "style": style(fontScale: fontScale, interfaceTheme: interfaceTheme),
            "displayWindow": NSNull(),
            "expandedExampleChatProcessingBlockIDs": expansionState.expandedExampleChatProcessingBlockIDs,
            "collapsedExampleChatProcessingBlockIDs": expansionState.collapsedExampleChatProcessingBlockIDs,
            "expandedExampleChatToolActivityBlockIDs": expandedToolActivityBlockIDs,
            "collapsedExampleChatToolActivityBlockIDs": expansionState.collapsedExampleChatToolActivityBlockIDs,
            "expandedExampleChatNestedDisclosureKeysBySourceBlockID": expandedNestedDisclosureKeysBySourceBlockID,
            "collapsedExampleChatNestedDisclosureKeysBySourceBlockID": expansionState.collapsedExampleChatNestedDisclosureKeysBySourceBlockID,
            "messages": messages,
            "blockCatalog": [],
            "messageGroups": messageGroups
        ]
    }

    private static func merged(_ base: [String], with additions: [String]) -> [String] {
        uniqued(base + additions)
    }

    private static func merged(
        _ base: [String: [String]],
        with additions: [String: [String]]
    ) -> [String: [String]] {
        var output = base
        for (sourceBlockID, keys) in additions {
            output[sourceBlockID] = uniqued((output[sourceBlockID] ?? []) + keys)
        }
        return output
    }

    private static func toolActivityBlockIDs(from messages: [[String: Any]]) -> [String] {
        uniqued(messages.flatMap { message -> [String] in
            guard let supportBlocks = message["supportBlocks"] as? [[String: Any]] else {
                return []
            }
            return supportBlocks.enumerated().flatMap { index, block -> [String] in
                guard isToolCallSupportKind(block["kind"] as? String) else {
                    return []
                }
                return toolActivitySourceIDs(for: block, supportBlockIndex: index)
            }
        })
    }

    private static func autoExpandedToolActivityBlockIDs(from messages: [[String: Any]]) -> [String] {
        uniqued(messages.flatMap { message -> [String] in
            guard let supportBlocks = message["supportBlocks"] as? [[String: Any]] else {
                return []
            }
            return supportBlocks.enumerated().flatMap { index, block -> [String] in
                guard shouldAutoExpandToolActivityBlock(block) else {
                    return []
                }
                return toolActivitySourceIDs(for: block, supportBlockIndex: index)
            }
        })
    }

    private static func nestedToolActivityDisclosureKeysBySourceBlockID(
        from messages: [[String: Any]],
        expandsAllShellItems: Bool
    ) -> [String: [String]] {
        var keysBySourceBlockID: [String: [String]] = [:]
        for message in messages {
            guard let supportBlocks = message["supportBlocks"] as? [[String: Any]] else {
                continue
            }
            for (supportBlockIndex, block) in supportBlocks.enumerated() {
                guard isToolCallSupportKind(block["kind"] as? String),
                      let activityItems = block["items"] as? [[String: Any]] else {
                    continue
                }
                let keys = activityItems.enumerated().flatMap { index, activityItem -> [String] in
                    guard expandsAllShellItems || shouldAutoExpandToolActivityItem(activityItem) else {
                        return []
                    }
                    return [
                        toolDisclosureStableKey(for: activityItem, index: index, namespace: "activity"),
                        toolDisclosureStableKey(for: activityItem, index: index, namespace: "processing")
                    ]
                }
                if !keys.isEmpty {
                    for sourceBlockID in nestedDisclosureSourceIDs(
                        for: block,
                        supportBlocks: supportBlocks,
                        supportBlockIndex: supportBlockIndex
                    ) {
                        keysBySourceBlockID[sourceBlockID] = uniqued(
                            (keysBySourceBlockID[sourceBlockID] ?? []) + keys
                        )
                    }
                }
            }
        }
        return keysBySourceBlockID
    }

    private static func shouldAutoExpandToolActivityBlock(_ block: [String: Any]) -> Bool {
        guard isToolCallSupportKind(block["kind"] as? String),
              let activityItems = block["items"] as? [[String: Any]] else {
            return false
        }
        return activityItems.contains(where: shouldAutoExpandToolActivityItem)
    }

    private static func shouldAutoExpandToolActivityItem(_ item: [String: Any]) -> Bool {
        guard activityItemIsShellCommand(item) else {
            return false
        }
        if let shellExecution = item["shellExecution"] as? [String: Any] {
            if !diagnosticString(shellExecution["output"]).isEmpty
                || !diagnosticString(shellExecution["rawOutput"]).isEmpty
                || shellExecution["exitCode"] is NSNumber
                || shellExecution["exitCode"] is Int {
                return true
            }
        }
        if let commandExecution = item["commandExecution"] as? [String: Any] {
            if !diagnosticString(commandExecution["aggregatedOutput"]).isEmpty
                || commandExecution["exitCode"] is NSNumber
                || commandExecution["exitCode"] is Int {
                return true
            }
        }
        let status = normalizedStatus(item["status"] as? String)
        return status == "processing" || status == "failed"
    }

    private static func activityItemIsShellCommand(_ item: [String: Any]) -> Bool {
        if item["shellExecution"] is [String: Any]
            || item["commandExecution"] is [String: Any] {
            return true
        }
        let tool = diagnosticString(item["tool"])
        let legacyToolName = diagnosticString(item["readexToolName"])
        let chatToolName = diagnosticString(item["chatToolName"])
        return tool == "workspace.shell"
            || tool == "readex.shell"
            || chatToolName == "workspace.shell"
            || chatToolName == "readex.shell"
            || legacyToolName == "workspace.shell"
            || legacyToolName == "readex.shell"
    }

    private static func isToolCallSupportKind(_ kind: String?) -> Bool {
        kind == "chat_tool_call" || kind == "readex_tool_call"
    }

    private static func isProcessingSupportKind(_ kind: String?) -> Bool {
        kind == "chat_processing" || kind == "readex_processing"
    }

    private static func disclosureSourceID(from block: [String: Any]) -> String? {
        [
            block["sourceBlockId"],
            block["sourceBlockID"],
            block["id"]
        ]
        .map(diagnosticString)
        .first { !$0.isEmpty }
    }

    private static func toolActivitySourceIDs(
        for block: [String: Any],
        supportBlockIndex: Int
    ) -> [String] {
        var ids: [String] = []
        if let sourceID = disclosureSourceID(from: block) {
            ids.append(sourceID)
        }
        ids.append("chat_tool_call:\(supportBlockIndex)")
        ids.append("chat_tool_activity:\(supportBlockIndex)")
        ids.append("readex_tool_call:\(supportBlockIndex)")
        ids.append("readex_tool_activity:\(supportBlockIndex)")
        if let items = block["items"] as? [[String: Any]] {
            for item in items {
                ids.append(contentsOf: activityItemStableIDs(from: item))
            }
        }
        return uniqued(ids)
    }

    private static func nestedDisclosureSourceIDs(
        for block: [String: Any],
        supportBlocks: [[String: Any]],
        supportBlockIndex: Int
    ) -> [String] {
        var ids = toolActivitySourceIDs(for: block, supportBlockIndex: supportBlockIndex)
        ids.append(contentsOf: processingSourceIDs(
            supportBlocks: supportBlocks,
            supportBlockIndex: supportBlockIndex
        ))
        return uniqued(ids)
    }

    private static func processingSourceIDs(
        supportBlocks: [[String: Any]],
        supportBlockIndex: Int
    ) -> [String] {
        guard supportBlocks.indices.contains(supportBlockIndex) else {
            return []
        }
        var startIndex = supportBlockIndex
        while startIndex > 0,
              supportBlockKindIsExampleChatActivity(supportBlocks[startIndex - 1]["kind"] as? String) {
            startIndex -= 1
        }
        var endIndex = supportBlockIndex
        while endIndex + 1 < supportBlocks.count,
              supportBlockKindIsExampleChatActivity(supportBlocks[endIndex + 1]["kind"] as? String) {
            endIndex += 1
        }

        let run = Array(supportBlocks[startIndex...endIndex])
        let processingAnchorOffset = run.firstIndex { isProcessingSupportKind($0["kind"] as? String) }
        let firstActivityOffset = run.firstIndex { supportBlockKindIsExampleChatActivity($0["kind"] as? String) }
        let sourceIndex = startIndex + (processingAnchorOffset ?? firstActivityOffset ?? 0)
        let sourceBlock = supportBlocks[sourceIndex]
        var ids: [String] = []
        for runtimeID in runtimeSupportBlockIDs(
            kind: sourceBlock["kind"] as? String,
            index: sourceIndex
        ) {
            ids.append(runtimeID)
        }
        if let sourceID = disclosureSourceID(from: sourceBlock) {
            ids.append(sourceID)
        }
        if let items = sourceBlock["items"] as? [[String: Any]],
           let firstItem = items.first {
            ids.append(contentsOf: activityItemStableIDs(from: firstItem))
        }
        for index in startIndex...endIndex {
            let block = supportBlocks[index]
            if let groupID = diagnosticOptionalString(block["chatProcessingGroupId"])
                ?? diagnosticOptionalString(block["readexProcessingGroupId"])
                ?? diagnosticOptionalString(block["readexProcessingGroupID"]) {
                ids.append(groupID)
            }
            if let turnStartedAt = diagnosticOptionalString(block["chatTurnStartedAtMilliseconds"])
                ?? diagnosticOptionalString(block["readexTurnStartedAtMilliseconds"]) {
                ids.append("turn-\(turnStartedAt)")
                ids.append("turn:\(turnStartedAt)")
            }
        }
        return uniqued(ids)
    }

    private static func supportBlockKindIsExampleChatActivity(_ kind: String?) -> Bool {
        switch kind {
        case "chat_progress",
             "readex_progress",
             "chat_processing",
             "readex_processing",
             "chat_tool_call",
             "readex_tool_call",
             "chat_video_progress",
             "readex_video_progress",
             "search_results",
             "proposed_plan":
            return true
        default:
            return false
        }
    }

    private static func runtimeSupportBlockIDs(kind: String?, index: Int) -> [String] {
        guard let kind else {
            return []
        }
        switch kind {
        case "chat_progress":
            return ["chat_progress:\(index)", "readex_progress:\(index)"]
        case "readex_progress":
            return ["readex_progress:\(index)", "chat_progress:\(index)"]
        case "chat_processing":
            return ["chat_processing:\(index)", "readex_processing:\(index)"]
        case "readex_processing":
            return ["readex_processing:\(index)", "chat_processing:\(index)"]
        case "chat_tool_call":
            return ["chat_tool_call:\(index)", "readex_tool_call:\(index)"]
        case "readex_tool_call":
            return ["readex_tool_call:\(index)", "chat_tool_call:\(index)"]
        case "chat_video_progress":
            return ["chat_video_progress:\(index)", "readex_video_progress:\(index)"]
        case "readex_video_progress":
            return ["readex_video_progress:\(index)", "chat_video_progress:\(index)"]
        case "search_results":
            return ["search_results:\(index)"]
        case "proposed_plan":
            return ["proposed_plan:\(index)"]
        default:
            return []
        }
    }

    private static func activityItemStableIDs(from item: [String: Any]) -> [String] {
        uniqued([
            item["sourceBlockId"],
            item["sourceBlockID"],
            item["id"],
            item["callID"],
            item["callId"],
            item["toolCallID"],
            item["toolCallId"]
        ].map(diagnosticString))
    }

    private static func toolDisclosureStableKey(
        for item: [String: Any],
        index: Int,
        namespace: String
    ) -> String {
        let stableID = [
            item["sourceBlockId"],
            item["sourceBlockID"],
            item["id"],
            item["callID"],
            item["callId"],
            item["toolCallID"],
            item["toolCallId"]
        ]
        .map(diagnosticString)
        .first { !$0.isEmpty }
        if let stableID {
            return [namespace, stableID].joined(separator: "\u{1f}")
        }
        return [
            namespace,
            "\(index)",
            diagnosticString(item["text"])
        ].joined(separator: "\u{1f}")
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }

    static func presentation(
        isGenerating: Bool,
        fontScale: Double = 1,
        interfaceTheme: PhotoSorterInterfaceTheme = .light
    ) -> [String: Any] {
        var presentation = ExampleChatTranscriptThemePreset.presentation(
            isGenerating: isGenerating,
            interfaceTheme: interfaceTheme
        )
        setPixelValues(
            in: &presentation,
            values: [
                "bodyFontSize": PhotoSorterTypography.transcriptBodyFontSize,
                "roleFontSize": PhotoSorterTypography.transcriptRoleFontSize,
                "metaFontSize": PhotoSorterTypography.transcriptMetaFontSize,
                "supportFontSize": PhotoSorterTypography.transcriptSupportFontSize,
                "historyEditorFontSize": PhotoSorterTypography.transcriptHistoryEditorFontSize
            ]
        )
        let scale = PhotoSorterTypography.clampedScale(fontScale)
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
        presentation["style"] = style(fontScale: scale, interfaceTheme: interfaceTheme)
        return presentation
    }

    private static func style(
        fontScale: Double,
        interfaceTheme: PhotoSorterInterfaceTheme
    ) -> [String: Any] {
        var style = ExampleChatTranscriptThemePreset.style(interfaceTheme: interfaceTheme)
        setPixelValues(
            in: &style,
            values: [
                "chatThinkingIndicatorFontSize": PhotoSorterTypography.transcriptThinkingIndicatorFontSize,
                "chatToolActivityFontSize": PhotoSorterTypography.transcriptToolActivityFontSize
            ]
        )
        scalePixelValues(
            in: &style,
            keys: [
                "chatThinkingIndicatorFontSize",
                "chatToolActivityFontSize"
            ],
            by: PhotoSorterTypography.clampedScale(fontScale)
        )
        return style
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
        guard scale.isFinite, scale > 0 else {
            return
        }
        for key in keys {
            guard let value = doubleValue(object[key]) else {
                continue
            }
            object[key] = value * scale
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
            let assistant = assistantMessage(
                from: assistantGroup,
                index: messages.count,
                isGenerating: isGenerating,
                activeTurnStartedAt: nil
            )
            if assistantMessageHasVisibleContent(assistant) {
                messages.append(assistant)
            }
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
                    status: "success",
                    textSelections: item.sourceTextSelections
                ))
            case .system:
                continue
            case .assistantProgress, .assistantFinal, .stoppedMarker, .error:
                lastItemWasUser = false
                assistantGroup.append(item)
            case .toolCall, .toolResult:
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

    private static func assistantMessageHasVisibleContent(_ message: [String: Any]) -> Bool {
        if let content = message["content"] as? String,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let supportBlocks = message["supportBlocks"] as? [[String: Any]],
           !supportBlocks.isEmpty {
            return true
        }
        return normalizedStatus(message["status"] as? String) == "failed"
    }

    private static func assistantMessage(
        from items: [MSPAgentTimelineItem],
        index: Int,
        isGenerating: Bool,
        activeTurnStartedAt: Int?
    ) -> [String: Any] {
        let projectedItems = mergedToolLifecycleItems(items)
        let messageID = assistantMessageID(
            from: projectedItems,
            fallbackIndex: index,
            activeTurnStartedAt: activeTurnStartedAt
        )
        var supportBlocks: [AssistantSupportBlock] = []
        var errorBlocks: [[String: Any]] = []
        var finalParts: [String] = []
        let turnStartedAt = activeTurnStartedAt ?? firstTurnStartedAt(in: projectedItems)
        let appendsPendingThinkingBlock = shouldAppendPendingThinkingBlock(
            to: projectedItems,
            isGenerating: isGenerating,
            turnStartedAtMilliseconds: turnStartedAt
        )

        for (itemIndex, item) in projectedItems.enumerated() {
            switch item.kind {
            case .assistantProgress:
                if isContextCompactionStatusItem(item) {
                    supportBlocks.append(contextCompactionStatusSupportBlock(from: item))
                } else {
                    supportBlocks.append(progressSupportBlock(
                        from: item,
                        completed: processingItemIsCompleted(
                            in: projectedItems,
                            at: itemIndex,
                            isGenerating: isGenerating,
                            hasPendingThinkingBlock: appendsPendingThinkingBlock
                        )
                    ))
                }
            case .toolCall:
                let completed = processingItemIsCompleted(
                    in: projectedItems,
                    at: itemIndex,
                    isGenerating: isGenerating,
                    hasPendingThinkingBlock: appendsPendingThinkingBlock
                )
                guard toolItemRendersAsWorkspaceCommand(item) else {
                    supportBlocks.append(contentsOf: imageSupportBlocks(from: item, completed: completed))
                    continue
                }
                supportBlocks.append(toolSupportBlock(item, completed: completed))
                supportBlocks.append(contentsOf: imageSupportBlocks(from: item, completed: completed))
            case .toolResult:
                if toolItemRendersAsWorkspaceCommand(item) {
                    supportBlocks.append(toolSupportBlock(item, completed: true))
                }
                supportBlocks.append(contentsOf: imageSupportBlocks(from: item, completed: true))
            case .assistantFinal:
                finalParts.append(item.body)
            case .stoppedMarker:
                supportBlocks.append(stoppedMarkerSupportBlock(from: item))
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
                text: projectedItems.map(\.body).joined(separator: "\n\n"),
                status: "success"
            ))
        }

        let hasFinalText = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let status = assistantMessageStatus(
            supportBlocks: supportBlocks,
            errorBlocks: errorBlocks,
            isGenerating: isGenerating,
            hasFinalText: hasFinalText
        )
        return legacyAssistantMessage(
            id: messageID,
            content: finalText,
            supportBlocks: supportBlocks,
            errorBlocks: errorBlocks,
            status: status,
            isStreaming: assistantMessageIsStreaming(status)
        )
    }

    private static func assistantMessageID(
        from items: [MSPAgentTimelineItem],
        fallbackIndex: Int,
        activeTurnStartedAt: Int?
    ) -> String {
        let identityItems = items.filter(assistantMessageItemContributesToIdentity)
        let candidateItems = identityItems.isEmpty ? items : identityItems
        if let turnStartedAt = activeTurnStartedAt ?? firstTurnStartedAt(in: candidateItems) {
            return "assistant-turn-\(turnStartedAt)"
        }
        if let callID = candidateItems.lazy.compactMap({ item -> String? in
            let callID = normalizedIdentifier(item.callID)
            return callID.isEmpty ? nil : callID
        }).first {
            return "assistant-call-\(callID)"
        }
        if let firstItemID = candidateItems.first?.id.uuidString {
            return "assistant-item-\(firstItemID)"
        }
        return "assistant-group-\(fallbackIndex)"
    }

    private static func assistantMessageItemContributesToIdentity(
        _ item: MSPAgentTimelineItem
    ) -> Bool {
        switch item.kind {
        case .assistantProgress, .assistantFinal, .stoppedMarker, .error:
            return true
        case .toolCall, .toolResult:
            return toolItemRendersAsWorkspaceCommand(item)
        case .system, .user:
            return false
        }
    }

    private static func mergedToolLifecycleItems(
        _ items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        var output: [MSPAgentTimelineItem] = []
        for item in items {
            guard item.kind == .toolResult,
                  let toolCallIndex = output.lastIndex(where: { toolLifecycleItemsMatch($0, item) }) else {
                output.append(item)
                continue
            }
            output[toolCallIndex] = mergedToolLifecycleItem(
                output[toolCallIndex],
                withResult: item
            )
        }
        return output
    }

    private static func toolLifecycleItemsMatch(
        _ toolCall: MSPAgentTimelineItem,
        _ toolResult: MSPAgentTimelineItem
    ) -> Bool {
        guard toolCall.kind == .toolCall else {
            return false
        }
        let toolCallID = normalizedIdentifier(toolCall.callID)
        let toolResultID = normalizedIdentifier(toolResult.callID)
        let toolResultParentID = normalizedIdentifier(toolResult.parentCallID)
        if !toolCallID.isEmpty && toolCallID == toolResultParentID {
            return true
        }
        if toolResultIsWriteStdinContinuation(toolResult),
           let callSessionID = toolCall.execSessionID,
           let resultSessionID = toolResult.execSessionID,
           callSessionID == resultSessionID {
            return true
        }
        if !toolCallID.isEmpty && toolCallID == toolResultID {
            return true
        }

        let toolCallCommand = normalizedIdentifier(commandText(from: toolCall))
        let toolResultCommand = normalizedIdentifier(commandText(from: toolResult))
        guard !toolCallCommand.isEmpty,
              toolCallCommand == toolResultCommand else {
            return false
        }
        if let callTurn = toolCall.turnStartedAtMilliseconds,
           let resultTurn = toolResult.turnStartedAtMilliseconds {
            return callTurn == resultTurn
        }
        return true
    }

    private static func mergedToolLifecycleItem(
        _ toolCall: MSPAgentTimelineItem,
        withResult toolResult: MSPAgentTimelineItem
    ) -> MSPAgentTimelineItem {
        var merged = toolCall
        let isSessionContinuation = toolResultIsSessionContinuation(
            toolResult,
            parent: toolCall
        )
        merged.kind = .toolCall
        if !toolResult.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.body = toolResult.body
        }
        merged.detail = toolResult.detail ?? toolCall.detail
        merged.callID = isSessionContinuation || normalizedIdentifier(toolResult.callID).isEmpty
            ? toolCall.callID
            : toolResult.callID
        merged.batchID = toolResult.batchID ?? toolCall.batchID
        merged.toolName = isSessionContinuation
            ? (toolCall.toolName ?? "exec_command")
            : (toolResult.toolName ?? toolCall.toolName)
        merged.command = normalizedIdentifier(toolResult.command).isEmpty
            ? toolCall.command
            : toolResult.command
        merged.cwd = toolResult.cwd ?? toolCall.cwd
        merged.stdout = mergedToolOutput(
            existing: toolCall.stdout,
            update: toolResult.stdout,
            appending: isSessionContinuation
        )
        merged.stderr = mergedToolOutput(
            existing: toolCall.stderr,
            update: toolResult.stderr,
            appending: isSessionContinuation
        )
        merged.exitCode = toolResult.exitCode ?? toolCall.exitCode
        merged.execSessionID = toolResult.execSessionID ?? toolCall.execSessionID
        merged.parentCallID = toolCall.parentCallID
        merged.status = toolResult.status ?? toolCall.status
        merged.startedAtMilliseconds = toolCall.startedAtMilliseconds ?? toolResult.startedAtMilliseconds
        merged.completedAtMilliseconds = toolResult.completedAtMilliseconds ?? toolCall.completedAtMilliseconds
        merged.durationMilliseconds = toolResult.durationMilliseconds ?? toolCall.durationMilliseconds
        merged.turnStartedAtMilliseconds = toolCall.turnStartedAtMilliseconds ?? toolResult.turnStartedAtMilliseconds
        merged.turnDurationMilliseconds = toolResult.turnDurationMilliseconds ?? toolCall.turnDurationMilliseconds
        merged.images = mergedTimelineImages(toolCall.images, toolResult.images)
        return merged
    }

    private static func toolResultIsSessionContinuation(
        _ toolResult: MSPAgentTimelineItem,
        parent toolCall: MSPAgentTimelineItem
    ) -> Bool {
        let toolCallID = normalizedIdentifier(toolCall.callID)
        let parentID = normalizedIdentifier(toolResult.parentCallID)
        if !toolCallID.isEmpty && toolCallID == parentID {
            return true
        }
        if toolResultIsWriteStdinContinuation(toolResult),
           let callSessionID = toolCall.execSessionID,
           let resultSessionID = toolResult.execSessionID,
           callSessionID == resultSessionID {
            return true
        }
        return false
    }

    private static func toolResultIsWriteStdinContinuation(
        _ toolResult: MSPAgentTimelineItem
    ) -> Bool {
        normalizedIdentifier(toolResult.toolName) == "write_stdin"
            || !normalizedIdentifier(toolResult.parentCallID).isEmpty
    }

    private static func mergedToolOutput(
        existing: String?,
        update: String?,
        appending: Bool
    ) -> String? {
        guard appending else {
            return update ?? existing
        }
        guard let update, !update.isEmpty else {
            return existing
        }
        guard let existing, !existing.isEmpty else {
            return update
        }
        if existing.hasSuffix(update) {
            return existing
        }
        return existing + update
    }

    private static func mergedTimelineImages(
        _ left: [MSPAgentTimelineImage],
        _ right: [MSPAgentTimelineImage]
    ) -> [MSPAgentTimelineImage] {
        var output = left
        for image in right where !output.contains(where: { $0.id == image.id }) {
            output.append(image)
        }
        return output
    }

    private static func toolItemRendersAsWorkspaceCommand(_ item: MSPAgentTimelineItem) -> Bool {
        let toolName = normalizedIdentifier(item.toolName).lowercased()
        if toolName == "update_plan" {
            return false
        }
        if toolName == "exec_command" || toolName == "write_stdin" {
            return true
        }
        return !commandText(from: item).isEmpty
    }

    private static func normalizedIdentifier(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func assistantMessageStatus(
        supportBlocks: [AssistantSupportBlock],
        errorBlocks: [[String: Any]],
        isGenerating: Bool = false,
        hasFinalText: Bool = false
    ) -> String {
        if supportBlocks.contains(where: { normalizedStatus($0.status) == "failed" })
            || supportBlocks.flatMap(\.activityItems).contains(where: { normalizedStatus($0.status) == "failed" })
            || errorBlocks.contains(where: { normalizedStatus($0["status"] as? String) == "failed" }) {
            return "failed"
        }
        if supportBlocks.contains(where: { normalizedStatus($0.status) == "processing" || normalizedStatus($0.status) == "streaming" })
            || supportBlocks.flatMap(\.activityItems).contains(where: {
                let status = normalizedStatus($0.status)
                return status == "processing" || status == "streaming" || status == "pending"
            }) {
            return "streaming"
        }
        if isGenerating && hasFinalText {
            return "streaming"
        }
        return "success"
    }

    private static func assistantMessageIsStreaming(_ status: String) -> Bool {
        switch normalizedStatus(status) {
        case "pending", "processing", "streaming", "searching":
            return true
        default:
            return false
        }
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
            item.kind == .assistantFinal || item.kind == .stoppedMarker || item.kind == .error
        }) {
            return false
        }
        if items.contains(where: isContextCompactionStatusItem) {
            return false
        }
        let hasActiveProcessingTool = items.contains(where: { item in
            switch item.kind {
            case .toolCall, .toolResult:
                return normalizedStatus(item.status) == "processing"
            case .system, .user, .assistantProgress, .assistantFinal, .stoppedMarker, .error:
                return false
            }
        })
        if hasActiveProcessingTool {
            return items.last(where: { $0.kind != .system })?.kind == .assistantProgress
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
        status: String,
        textSelections: [PhotoSorterTextSelectionSnapshot] = []
    ) -> [String: Any] {
        let selectionBlocks = textSelections.enumerated().map { index, selection in
            textSelectionBlock(
                id: "\(id):selection-\(index)",
                messageID: id,
                selection: selection,
                status: status
            )
        }
        let mainTextBlock = messageBlock(
            id: "\(id):content",
            messageID: id,
            type: "main_text",
            text: text,
            status: status
        )
        return structuredMessage(
            id: id,
            role: role,
            status: status,
            blocks: selectionBlocks + [mainTextBlock]
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

    private static func textSelectionBlock(
        id: String,
        messageID: String,
        selection: PhotoSorterTextSelectionSnapshot,
        status: String
    ) -> [String: Any] {
        var block = messageBlock(
            id: id,
            messageID: messageID,
            type: "text_selection",
            text: "",
            status: status
        )
        block["textSelection"] = textSelectionPayload(selection)
        return block
    }

    private static func textSelectionPayload(_ selection: PhotoSorterTextSelectionSnapshot) -> [String: Any] {
        [
            "id": selection.id.uuidString,
            "selectedText": selection.selectedText,
            "sourceKind": selection.sourceKind,
            "sourceDisplayName": selection.sourceDisplayName,
            "sourceContextDisplayName": selection.sourceDisplayName,
            "sourceMessageID": selection.sourceMessageID.map { $0 as Any } ?? NSNull(),
            "sourceMessageRole": selection.sourceMessageRole.map { $0 as Any } ?? NSNull(),
            "selectedTextOccurrenceIndexInMessage": selection.selectedTextOccurrenceIndexInMessage.map { $0 as Any } ?? NSNull(),
            "renderedTextSegments": selection.renderedTextSegments,
            "highlightColor": [
                "red": 0.19,
                "green": 0.48,
                "blue": 0.96,
                "alpha": 0.22
            ]
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

    private static func contextCompactionStatusSupportBlock(
        from item: MSPAgentTimelineItem
    ) -> AssistantSupportBlock {
        let completed = contextCompactionStatusText(item.body) == contextCompactionCompletedText
        let eventMilliseconds = item.completedAtMilliseconds
            ?? item.startedAtMilliseconds
            ?? item.turnStartedAtMilliseconds
        return AssistantSupportBlock(
            id: item.id,
            kind: .chatProgress,
            text: completed ? contextCompactionCompletedText : contextCompactionRunningText,
            durationMilliseconds: nil,
            startedAtMilliseconds: item.startedAtMilliseconds ?? eventMilliseconds,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            status: completed ? "success" : "processing",
            progressUpdatedAtMilliseconds: eventMilliseconds
        )
    }

    private static func isContextCompactionStatusItem(_ item: MSPAgentTimelineItem) -> Bool {
        guard item.kind == .assistantProgress else {
            return false
        }
        return contextCompactionStatusText(item.body) != nil
    }

    private static func contextCompactionStatusText(_ text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == contextCompactionRunningText || normalized == contextCompactionCompletedText {
            return normalized
        }
        return nil
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

    private static func stoppedMarkerSupportBlock(
        from item: MSPAgentTimelineItem
    ) -> AssistantSupportBlock {
        AssistantSupportBlock(
            id: item.id,
            kind: .chatStoppedMarker,
            text: item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "已停止"
                : item.body,
            durationMilliseconds: item.durationMilliseconds,
            startedAtMilliseconds: item.startedAtMilliseconds ?? item.turnStartedAtMilliseconds,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            status: "stopped",
            chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" },
            chatProcessingChromeRole: "owner"
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
        let isStopped = status == "stopped"
        let isCompleted = isStopped
            || (status != "processing" && status != "streaming" && status != "pending")
        let startedAt = item.startedAtMilliseconds ?? item.turnStartedAtMilliseconds
        let rawOutput = shellOutput(from: item)
        let outputEnvelope = PhotoSorterShellOutputEnvelope.parse(rawOutput)
        let bodyEnvelope = PhotoSorterShellOutputEnvelope.parse(item.body)
        let terminalEnvelope = outputEnvelope ?? bodyEnvelope
        let output = terminalEnvelope?.output ?? rawOutput
        let bodyIsTerminalEnvelope = bodyEnvelope != nil
        let exitCode: Any
        if let itemExitCode = item.exitCode {
            exitCode = itemExitCode
        } else if let envelopeExitCode = terminalEnvelope?.exitCode {
            exitCode = envelopeExitCode
        } else if isStopped {
            exitCode = NSNull()
        } else if isCompleted {
            exitCode = 0
        } else {
            exitCode = NSNull()
        }
        let wallTimeSeconds: Any
        if let durationMilliseconds = item.durationMilliseconds {
            wallTimeSeconds = Double(durationMilliseconds) / 1000.0
        } else if let envelopeWallTimeSeconds = terminalEnvelope?.wallTimeSeconds {
            wallTimeSeconds = envelopeWallTimeSeconds
        } else {
            wallTimeSeconds = NSNull()
        }
        let durationMilliseconds = item.durationMilliseconds ?? terminalEnvelope?.durationMilliseconds
        let activityID = item.callID ?? "activity-\(item.id.uuidString)"
        let startedAtMilliseconds = startedAt ?? 0
        let startedAtDate = date(millisecondsSince1970: startedAtMilliseconds)
        let completedAtDate = item.completedAtMilliseconds.map(date(millisecondsSince1970:))
            ?? durationMilliseconds.map { startedAtDate.addingTimeInterval(Double($0) / 1000.0) }
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
            text: generatedShellStatusTextIsRequired(item.body, bodyIsTerminalEnvelope: bodyIsTerminalEnvelope)
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
                displayText: shellDisplayText(
                    from: item,
                    bodyIsTerminalEnvelope: bodyIsTerminalEnvelope,
                    status: status,
                    isCompleted: isCompleted,
                    call: call
                ),
                durationMilliseconds: durationMilliseconds,
                status: status,
                isCompleted: isCompleted,
                startedAt: startedAt
            )
        }

        if isCompleted && !isStopped {
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
            let completedText = generatedShellStatusTextIsRequired(
                item.body,
                bodyIsTerminalEnvelope: bodyIsTerminalEnvelope
            )
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

        let includesLiveOutput = isCompleted || !output.isEmpty
        let liveShellExecution = shellExecution(
            command: command,
            cwd: item.cwd ?? "/",
            output: output,
            exitCode: exitCode as? Int,
            wallTimeSeconds: wallTimeSeconds as? Double,
            includesOutput: includesLiveOutput
        )
        let liveCommandExecution = commandExecution(
            activityID: activityID,
            command: command,
            cwd: item.cwd ?? "/",
            output: output,
            exitCode: exitCode as? Int,
            status: status,
            wallTimeSeconds: wallTimeSeconds as? Double,
            includesOutput: includesLiveOutput
        )
        let activityStatus = isStopped
            ? "stopped"
            : (supportBlock.activityItems.last?.status ?? supportBlock.status)
        let activityDurationMilliseconds = isStopped
            ? durationMilliseconds
            : (supportBlock.activityItems.last?.durationMilliseconds ?? supportBlock.durationMilliseconds ?? durationMilliseconds)
        let activityCompletedAtMilliseconds = isCompleted ? item.completedAtMilliseconds : nil
        let blockStatus = isStopped ? "stopped" : supportBlock.status
        let blockDurationMilliseconds = isStopped ? durationMilliseconds : (supportBlock.durationMilliseconds ?? durationMilliseconds)
        let workedForItem = isStopped
            ? AssistantSupportWorkedForItem(
                status: .worked,
                startedAtMilliseconds: startedAtMilliseconds,
                completedAtMilliseconds: item.completedAtMilliseconds
            )
            : supportBlock.workedForItem

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
            status: activityStatus,
            completed: isCompleted,
            durationMilliseconds: activityDurationMilliseconds,
            startedAtMilliseconds: supportBlock.activityItems.last?.startedAtMilliseconds ?? supportBlock.startedAtMilliseconds,
            completedAtMilliseconds: activityCompletedAtMilliseconds,
            chatToolName: "workspace.shell",
            chatToolBatchID: item.batchID,
            shellExecution: liveShellExecution ?? supportBlock.activityItems.last?.shellExecution,
            commandExecution: liveCommandExecution ?? supportBlock.activityItems.last?.commandExecution
        )
        return AssistantSupportBlock(
            id: item.id,
            kind: .chatToolCall,
            text: supportBlock.text,
            detailText: supportBlock.detailText,
            durationMilliseconds: blockDurationMilliseconds,
            startedAtMilliseconds: supportBlock.startedAtMilliseconds ?? startedAt,
            chatTurnStartedAtMilliseconds: item.turnStartedAtMilliseconds,
            chatTurnDurationMilliseconds: item.turnDurationMilliseconds,
            previewItems: supportBlock.previewItems,
            activityItems: [activityItem],
            chatToolName: "workspace.shell",
            chatToolBatchID: item.batchID,
            status: blockStatus,
            workedForItem: workedForItem,
            chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" },
            chatProcessingChromeRole: "owner"
        )
    }

    private static func imageSupportBlocks(
        from item: MSPAgentTimelineItem,
        completed: Bool
    ) -> [AssistantSupportBlock] {
        guard completed, !item.images.isEmpty else {
            return []
        }
        return [
            AssistantSupportBlock(
                id: imageBlockID(for: item),
                kind: .image,
                imageStatus: .completed,
                images: item.images.map { image in
                    AssistantImageRecord(
                        id: image.id,
                        base64: nil,
                        mimeType: image.mimeType,
                        cacheKey: image.cacheKey
                    )
                },
                chatProcessingGroupID: item.turnStartedAtMilliseconds.map { "turn-\($0)" }
            )
        ]
    }

    private static func imageBlockID(for item: MSPAgentTimelineItem) -> UUID {
        let hex = item.id.uuidString.replacingOccurrences(of: "-", with: "")
        let tail = String(hex.suffix(12))
        return UUID(uuidString: "00000000-0000-4000-8102-\(tail)") ?? item.id
    }

    private static func imageCacheEntries(from items: [MSPAgentTimelineItem]) -> [ExampleChatTranscriptImageCacheEntry] {
        var seen = Set<String>()
        var entries: [ExampleChatTranscriptImageCacheEntry] = []
        for item in items {
            for image in item.images {
                let key = image.cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty,
                      !image.base64.isEmpty,
                      !seen.contains(key) else {
                    continue
                }
                seen.insert(key)
                entries.append(ExampleChatTranscriptImageCacheEntry(
                    key: key,
                    base64: image.base64,
                    mimeType: image.mimeType
                ))
            }
        }
        return entries
    }

    private static func shellExecution(
        command: String,
        cwd: String,
        output: String,
        exitCode: Int?,
        wallTimeSeconds: Double?,
        includesOutput: Bool
    ) -> AssistantSupportShellExecution? {
        guard !command.isEmpty else {
            return nil
        }
        let action = ExampleChatWorkspaceShellTranscriptDisplaySupport.shellCommandAction(for: command)
        return AssistantSupportShellExecution(
            command: command,
            cwd: cwd,
            kind: action.type,
            target: action.path,
            query: action.query,
            exitCode: exitCode,
            wallTimeSeconds: wallTimeSeconds,
            output: includesOutput ? output : nil,
            rawOutput: includesOutput ? output : nil
        )
    }

    private static func commandExecution(
        activityID: String,
        command: String,
        cwd: String,
        output: String,
        exitCode: Int?,
        status: String,
        wallTimeSeconds: Double?,
        includesOutput: Bool
    ) -> AssistantSupportCommandExecution? {
        guard !command.isEmpty else {
            return nil
        }
        return AssistantSupportCommandExecution(
            id: activityID,
            callID: activityID,
            cwd: cwd,
            command: command,
            commandActions: [ExampleChatShellTranscriptDisplaySupport.shellCommandAction(for: command)],
            aggregatedOutput: includesOutput ? output : nil,
            exitCode: exitCode,
            status: status,
            wallTimeSeconds: wallTimeSeconds
        )
    }

    private static func fallbackToolSupportBlock(
        item: MSPAgentTimelineItem,
        activityID: String,
        command: String,
        output: String,
        exitCode: Int?,
        wallTimeSeconds: Double?,
        displayText: String,
        durationMilliseconds: Int?,
        status: String,
        isCompleted: Bool,
        startedAt: Int?
    ) -> AssistantSupportBlock {
        let action = ExampleChatWorkspaceShellTranscriptDisplaySupport.shellCommandAction(for: command)
        let includesOutput = isCompleted || !output.isEmpty
        let shellExecution = AssistantSupportShellExecution(
            command: command,
            cwd: item.cwd ?? "/",
            kind: action.type,
            target: action.path,
            query: action.query,
            exitCode: exitCode,
            wallTimeSeconds: wallTimeSeconds,
            output: includesOutput ? output : nil,
            rawOutput: includesOutput ? output : nil
        )
        let commandExecution = AssistantSupportCommandExecution(
            id: activityID,
            callID: activityID,
            cwd: item.cwd ?? "/",
            command: command,
            commandActions: [ExampleChatShellTranscriptDisplaySupport.shellCommandAction(for: command)],
            aggregatedOutput: includesOutput ? output : nil,
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
            text: displayText,
            subtitleText: command.isEmpty ? nil : command,
            detailText: item.detail,
            status: status,
            completed: isCompleted,
            durationMilliseconds: durationMilliseconds,
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
            text: displayText,
            detailText: item.detail,
            durationMilliseconds: durationMilliseconds,
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

    private static func generatedShellStatusTextIsRequired(
        _ body: String,
        bodyIsTerminalEnvelope: Bool
    ) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed == "正在执行工作区命令"
            || bodyIsTerminalEnvelope
    }

    private static func shellDisplayText(
        from item: MSPAgentTimelineItem,
        bodyIsTerminalEnvelope: Bool,
        status: String,
        isCompleted: Bool,
        call: ExampleChatToolCall
    ) -> String {
        guard generatedShellStatusTextIsRequired(
            item.body,
            bodyIsTerminalEnvelope: bodyIsTerminalEnvelope
        ) else {
            return item.body
        }
        if isCompleted {
            let ok = status != "failed"
            let result = ExampleChatToolResult(
                callID: call.id,
                name: call.name,
                ok: ok,
                content: nil,
                internalContent: nil,
                errorMessage: nil
            )
            return ExampleChatShellTranscriptDisplaySupport.shellCompletedStatusText(
                for: result,
                existing: nil
            )
        }
        return ExampleChatShellTranscriptDisplaySupport.shellStartedStatusText(for: call)
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
        case "stopped", "cancelled", "canceled", "interrupted":
            return "stopped"
        default:
            return ""
        }
    }

    private static func anyOrNull<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func diagnosticString(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let bool as Bool:
            return "\(bool)"
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return "\(int)"
        case let double as Double:
            return "\(double)"
        default:
            return String(describing: value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func diagnosticOptionalString(_ value: Any?) -> String? {
        let normalized = diagnosticString(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func date(millisecondsSince1970 milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
    }

}
