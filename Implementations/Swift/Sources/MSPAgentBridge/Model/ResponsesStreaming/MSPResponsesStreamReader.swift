import Foundation

struct MSPPendingStreamDeltaBuffer {
    var text: String
    var itemID: String?
    var outputIndex: Int?
}

extension MSPResponsesStreamingModelClient {
    func readEventStream(
        bytes: AsyncThrowingStream<UInt8, Error>,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        var lineBuffer = Data()
        var currentEventName: String?
        var dataLines: [String] = []
        var responseID: String?
        var fullText = ""
        var partialCalls: [String: MSPResponsesFunctionCallAccumulator] = [:]
        var outputIndexKeys: [Int: String] = [:]
        var announcedFunctionCallKeys = Set<String>()
        var nativeOutputItemsByIndex: [Int: MSPAgentJSONValue] = [:]
        var completedNativeOutputItems: [MSPAgentJSONValue] = []
        var outputItemPhasesByIndex: [Int: MSPAgentModelStreamDelta.Phase] = [:]
        var outputItemPhasesByID: [String: MSPAgentModelStreamDelta.Phase] = [:]
        var pendingDeltasByKey: [String: MSPPendingStreamDeltaBuffer] = [:]
        var assistantMessageParts: [String] = []
        var finalAnswerParts: [String] = []
        var tokenUsage: MSPAgentTokenUsage?
        var sawCompleted = false

        func normalizedItemID(_ itemID: String?) -> String? {
            guard let itemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !itemID.isEmpty else {
                return nil
            }
            return itemID
        }

        func streamDeltaKey(itemID: String?, outputIndex: Int?) -> String {
            if let itemID = normalizedItemID(itemID) {
                return "id:\(itemID)"
            }
            if let outputIndex {
                return "output:\(outputIndex)"
            }
            return "unknown"
        }

        func emitStreamDelta(
            _ text: String,
            phase: MSPAgentModelStreamDelta.Phase,
            itemID: String?,
            outputIndex: Int?
        ) async {
            guard !text.isEmpty else {
                return
            }
            await onDelta(
                MSPAgentModelStreamDelta(
                    text: text,
                    phase: phase,
                    itemID: normalizedItemID(itemID),
                    outputIndex: outputIndex
                )
            )
        }

        func flushPendingStreamDelta(
            itemID: String?,
            outputIndex: Int?,
            phase: MSPAgentModelStreamDelta.Phase
        ) async {
            var keys = [streamDeltaKey(itemID: itemID, outputIndex: outputIndex)]
            if let outputIndex {
                keys.append(streamDeltaKey(itemID: nil, outputIndex: outputIndex))
            }
            if let itemID = normalizedItemID(itemID) {
                keys.append(streamDeltaKey(itemID: itemID, outputIndex: nil))
            }

            for key in Array(Set(keys)) {
                guard let pending = pendingDeltasByKey.removeValue(forKey: key) else {
                    continue
                }
                await emitStreamDelta(
                    pending.text,
                    phase: phase,
                    itemID: pending.itemID ?? itemID,
                    outputIndex: pending.outputIndex ?? outputIndex
                )
            }
        }

        func phaseForStreamDelta(itemID: String?, outputIndex: Int?) -> MSPAgentModelStreamDelta.Phase? {
            if let itemID = normalizedItemID(itemID),
               let phase = outputItemPhasesByID[itemID] {
                return phase
            }
            if let outputIndex,
               let phase = outputItemPhasesByIndex[outputIndex] {
                return phase
            }
            return nil
        }

        func recordOutputItemPhase(_ item: [String: Any], outputIndex: Int?) async {
            guard Self.stringValue(at: ["type"], in: item) == "message",
                  Self.stringValue(at: ["role"], in: item) == "assistant",
                  let phase = Self.visibleDeltaPhase(from: Self.stringValue(at: ["phase"], in: item)) else {
                return
            }

            let itemID = normalizedItemID(Self.stringValue(at: ["id"], in: item))
            if let outputIndex {
                outputItemPhasesByIndex[outputIndex] = phase
            }
            if let itemID {
                outputItemPhasesByID[itemID] = phase
            }
            await flushPendingStreamDelta(itemID: itemID, outputIndex: outputIndex, phase: phase)
        }

        func bufferUnresolvedStreamDelta(_ text: String, itemID: String?, outputIndex: Int?) {
            let key = streamDeltaKey(itemID: itemID, outputIndex: outputIndex)
            var pending = pendingDeltasByKey[key] ?? MSPPendingStreamDeltaBuffer(
                text: "",
                itemID: normalizedItemID(itemID),
                outputIndex: outputIndex
            )
            pending.text += text
            pending.itemID = pending.itemID ?? normalizedItemID(itemID)
            pending.outputIndex = pending.outputIndex ?? outputIndex
            pendingDeltasByKey[key] = pending
        }

        func flushUnresolvedStreamDeltasAsUnknown() async {
            let pending = pendingDeltasByKey
                .values
                .sorted { left, right in
                    switch (left.outputIndex, right.outputIndex) {
                    case let (left?, right?) where left != right:
                        return left < right
                    default:
                        return (left.itemID ?? "") < (right.itemID ?? "")
                    }
                }
            pendingDeltasByKey.removeAll(keepingCapacity: false)
            for delta in pending {
                await emitStreamDelta(
                    delta.text,
                    phase: .unknown,
                    itemID: delta.itemID,
                    outputIndex: delta.outputIndex
                )
            }
        }

        func flushPendingEvent() async throws {
            guard !dataLines.isEmpty else {
                return
            }
            let dataString = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            guard dataString != "[DONE]" else {
                return
            }
            guard let data = dataString.data(using: .utf8) else {
                return
            }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any] else {
                if let error = Self.responseErrorMessage(from: object) {
                    throw MSPAgentModelClientError.apiError(error)
                }
                throw MSPAgentModelClientError.invalidStreamPayload(String(dataString.prefix(220)))
            }

            let eventName = Self.stringValue(at: ["type"], in: json) ?? currentEventName ?? ""
            if let message = Self.contextWindowExceededMessage(from: json) {
                throw MSPAgentModelClientError.contextWindowExceeded(message)
            }
            if Self.isResponsesStreamErrorEvent(eventName: eventName, json: json) {
                throw MSPAgentModelClientError.apiError(
                    Self.streamErrorMessage(from: json, dataString: dataString)
                )
            }
            responseID = Self.stringValue(at: ["response", "id"], in: json)
                ?? Self.stringValue(at: ["response_id"], in: json)
                ?? Self.stringValue(at: ["id"], in: json)
                ?? responseID

            let delta = Self.extractResponsesDelta(from: json)
            if !delta.isEmpty {
                let itemID = Self.stringValue(at: ["item_id"], in: json)
                    ?? Self.stringValue(at: ["item", "id"], in: json)
                let outputIndex = Self.intValue(at: ["output_index"], in: json)
                let eventPhase = Self.visibleDeltaPhase(
                    from: Self.stringValue(at: ["phase"], in: json)
                        ?? Self.stringValue(at: ["item", "phase"], in: json)
                )
                if let eventPhase {
                    if let outputIndex {
                        outputItemPhasesByIndex[outputIndex] = eventPhase
                    }
                    if let itemID = normalizedItemID(itemID) {
                        outputItemPhasesByID[itemID] = eventPhase
                    }
                }
                fullText += delta
                if let phase = eventPhase ?? phaseForStreamDelta(itemID: itemID, outputIndex: outputIndex) {
                    await emitStreamDelta(delta, phase: phase, itemID: itemID, outputIndex: outputIndex)
                } else {
                    bufferUnresolvedStreamDelta(delta, itemID: itemID, outputIndex: outputIndex)
                }
            } else if eventName == "response.completed",
                      fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let response = json["response"] as? [String: Any] {
                fullText = Self.extractResponsesText(from: response)
            }

            if eventName == "response.completed" {
                sawCompleted = true
                if let response = json["response"] as? [String: Any] {
                    tokenUsage = Self.tokenUsage(from: response)
                        ?? Self.tokenUsage(from: json)
                        ?? tokenUsage
                } else {
                    tokenUsage = Self.tokenUsage(from: json) ?? tokenUsage
                }
            }

            if (eventName == "response.output_item.added" || eventName == "response.output_item.done"),
               let item = json["item"] as? [String: Any] {
                await recordOutputItemPhase(item, outputIndex: Self.intValue(at: ["output_index"], in: json))
            }

            if eventName == "response.output_item.done",
               let item = json["item"] as? [String: Any],
               let outputIndex = Self.intValue(at: ["output_index"], in: json),
               let nativeItem = try? MSPAgentJSONValue(jsonObject: item) {
                nativeOutputItemsByIndex[outputIndex] = nativeItem
                let visible = Self.visibleMessageParts(from: [nativeItem])
                assistantMessageParts.append(contentsOf: visible.assistantMessages)
                finalAnswerParts.append(contentsOf: visible.finalAnswers)
                for message in visible.assistantMessages {
                    await onAssistantMessage(message)
                }
            } else if eventName == "response.completed",
                      let response = json["response"] as? [String: Any],
                      let outputItems = response["output"] as? [Any] {
                for (index, value) in outputItems.enumerated() {
                    guard let item = value as? [String: Any] else {
                        continue
                    }
                    await recordOutputItemPhase(item, outputIndex: index)
                }
                completedNativeOutputItems = outputItems.compactMap { try? MSPAgentJSONValue(jsonObject: $0) }
                let visible = Self.visibleMessageParts(from: completedNativeOutputItems)
                assistantMessageParts.append(contentsOf: visible.assistantMessages)
                finalAnswerParts.append(contentsOf: visible.finalAnswers)
            }

            mergeFunctionCallEvent(
                json,
                eventName: eventName,
                partialCalls: &partialCalls,
                outputIndexKeys: &outputIndexKeys
            )
            for (key, partial) in partialCalls where !announcedFunctionCallKeys.contains(key) {
                let rawName = partial.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rawName.isEmpty else {
                    continue
                }
                announcedFunctionCallKeys.insert(key)
                await onToolCallPreparing(MSPAgentToolName(apiName: rawName))
            }
            currentEventName = nil
        }

        func processLine(_ rawLine: String) async throws {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(":") {
                return
            }
            if line.hasPrefix("event:") {
                currentEventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                return
            }
            if line.hasPrefix("data:") {
                let rawPayload = line.dropFirst("data:".count)
                let payload = rawPayload.first == " " ? String(rawPayload.dropFirst()) : String(rawPayload)
                dataLines.append(payload)
                if Self.shouldParseImmediately(dataLines) {
                    try await flushPendingEvent()
                }
                return
            }
            if trimmed.isEmpty {
                try await flushPendingEvent()
                return
            }
            if Self.isLikelyStandaloneEvent(line) {
                dataLines = [line]
                try await flushPendingEvent()
            }
        }

        for try await byte in bytes {
            if byte == 10 {
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                try await processLine(line)
            } else {
                lineBuffer.append(byte)
            }
        }
        if !lineBuffer.isEmpty {
            let finalLine = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)
            try await processLine(finalLine)
        }
        try await flushPendingEvent()
        await flushUnresolvedStreamDeltasAsUnknown()

        let toolCalls = try toolCalls(from: partialCalls)
        let nativeOutputItems = completedNativeOutputItems.isEmpty
            ? nativeOutputItemsByIndex.keys.sorted().compactMap { nativeOutputItemsByIndex[$0] }
            : completedNativeOutputItems
        let visible = Self.visibleMessageParts(from: nativeOutputItems)
        let resolvedAssistantMessages = visible.assistantMessages.isEmpty ? assistantMessageParts : visible.assistantMessages
        let resolvedFinalAnswers = visible.finalAnswers.isEmpty ? finalAnswerParts : visible.finalAnswers
        let assistantMessage = Self.joinedVisibleMessageParts(resolvedAssistantMessages)
            ?? (toolCalls.isEmpty ? nil : Self.nonEmpty(fullText))
        let finalAnswer = Self.joinedVisibleMessageParts(resolvedFinalAnswers)
            ?? (toolCalls.isEmpty ? Self.nonEmpty(fullText) : nil)

        return MSPAgentModelTurnOutput(
            assistantMessage: assistantMessage,
            toolCalls: toolCalls,
            finalAnswer: finalAnswer,
            responseID: responseID,
            nativeOutputItems: nativeOutputItems,
            tokenUsage: tokenUsage,
            sawCompleted: sawCompleted
        )
    }
}
