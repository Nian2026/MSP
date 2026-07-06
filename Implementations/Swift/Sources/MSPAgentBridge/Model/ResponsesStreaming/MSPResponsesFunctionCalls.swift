import Foundation

struct MSPResponsesFunctionCallAccumulator {
    var outputIndex: Int
    var itemID: String?
    var callID: String?
    var name: String?
    var kind: MSPAgentToolCallKind
    var arguments: String
    var input: String
}

extension MSPResponsesStreamingModelClient {
    func mergeFunctionCallEvent(
        _ json: [String: Any],
        eventName: String,
        partialCalls: inout [String: MSPResponsesFunctionCallAccumulator],
        outputIndexKeys: inout [Int: String]
    ) {
        switch eventName {
        case "response.output_item.added", "response.output_item.done":
            guard let item = json["item"] as? [String: Any] else {
                return
            }
            mergeToolCallItem(
                item,
                outputIndex: Self.intValue(at: ["output_index"], in: json),
                partialCalls: &partialCalls,
                outputIndexKeys: &outputIndexKeys
            )
        case "response.function_call_arguments.delta":
            let outputIndex = Self.intValue(at: ["output_index"], in: json)
            let key = functionCallKey(
                itemID: Self.stringValue(at: ["item_id"], in: json),
                outputIndex: outputIndex,
                outputIndexKeys: &outputIndexKeys
            )
            var partial = partialCalls[key] ?? MSPResponsesFunctionCallAccumulator(
                outputIndex: outputIndex ?? partialCalls.count,
                itemID: Self.stringValue(at: ["item_id"], in: json),
                callID: nil,
                name: nil,
                kind: .function,
                arguments: "",
                input: ""
            )
            partial.arguments += Self.stringValue(at: ["delta"], in: json) ?? ""
            partialCalls[key] = partial
        case "response.custom_tool_call_input.delta":
            let outputIndex = Self.intValue(at: ["output_index"], in: json)
            let itemID = Self.stringValue(at: ["item_id"], in: json)
                ?? Self.stringValue(at: ["call_id"], in: json)
            let key = functionCallKey(
                itemID: itemID,
                outputIndex: outputIndex,
                outputIndexKeys: &outputIndexKeys
            )
            var partial = partialCalls[key] ?? MSPResponsesFunctionCallAccumulator(
                outputIndex: outputIndex ?? partialCalls.count,
                itemID: itemID,
                callID: Self.stringValue(at: ["call_id"], in: json),
                name: nil,
                kind: .custom,
                arguments: "",
                input: ""
            )
            partial.kind = .custom
            partial.itemID = itemID ?? partial.itemID
            partial.callID = Self.stringValue(at: ["call_id"], in: json)
                ?? partial.callID
                ?? itemID
            partial.input += Self.stringValue(at: ["delta"], in: json) ?? ""
            partialCalls[key] = partial
        case "response.function_call_arguments.done":
            if let item = json["item"] as? [String: Any] {
                mergeToolCallItem(
                    item,
                    outputIndex: Self.intValue(at: ["output_index"], in: json),
                    partialCalls: &partialCalls,
                    outputIndexKeys: &outputIndexKeys
                )
            }
        case "response.completed":
            guard let response = json["response"] as? [String: Any],
                  let outputItems = response["output"] as? [Any] else {
                return
            }
            for (index, value) in outputItems.enumerated() {
                guard let item = value as? [String: Any] else {
                    continue
                }
                mergeToolCallItem(
                    item,
                    outputIndex: index,
                    partialCalls: &partialCalls,
                    outputIndexKeys: &outputIndexKeys
                )
            }
        default:
            return
        }
    }

    func mergeToolCallItem(
        _ item: [String: Any],
        outputIndex: Int?,
        partialCalls: inout [String: MSPResponsesFunctionCallAccumulator],
        outputIndexKeys: inout [Int: String]
    ) {
        let type = Self.stringValue(at: ["type"], in: item)
        guard type == "function_call" || type == "custom_tool_call" else {
            return
        }
        let kind: MSPAgentToolCallKind = type == "custom_tool_call" ? .custom : .function
        let resolvedOutputIndex = outputIndex ?? partialCalls.count
        let itemID = Self.stringValue(at: ["id"], in: item)
        let key = functionCallKey(
            itemID: itemID,
            outputIndex: resolvedOutputIndex,
            outputIndexKeys: &outputIndexKeys
        )
        var partial = partialCalls[key] ?? MSPResponsesFunctionCallAccumulator(
            outputIndex: resolvedOutputIndex,
            itemID: itemID,
            callID: nil,
            name: nil,
            kind: kind,
            arguments: "",
            input: ""
        )
        partial.kind = kind
        partial.itemID = itemID ?? partial.itemID
        partial.callID = Self.stringValue(at: ["call_id"], in: item)
            ?? Self.stringValue(at: ["callId"], in: item)
            ?? partial.callID
            ?? itemID
        partial.name = Self.stringValue(at: ["name"], in: item)
            ?? Self.stringValue(at: ["function", "name"], in: item)
            ?? partial.name
        if let arguments = functionArgumentsText(from: item),
           !arguments.isEmpty {
            partial.arguments = arguments
        }
        if kind == .custom,
           let input = customToolInputText(from: item),
           !input.isEmpty {
            partial.input = input
        }
        partialCalls[key] = partial
    }

    func functionCallKey(
        itemID: String?,
        outputIndex: Int?,
        outputIndexKeys: inout [Int: String]
    ) -> String {
        if let itemID,
           !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let outputIndex {
                outputIndexKeys[outputIndex] = itemID
            }
            return itemID
        }
        if let outputIndex {
            return outputIndexKeys[outputIndex] ?? "output:\(outputIndex)"
        }
        return "output:unknown"
    }

    func functionArgumentsText(from item: [String: Any]) -> String? {
        if let string = item["arguments"] as? String {
            return string
        }
        if let value = item["arguments"],
           JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let function = item["function"] as? [String: Any] {
            return functionArgumentsText(from: function)
        }
        return nil
    }

    func customToolInputText(from item: [String: Any]) -> String? {
        if let string = item["input"] as? String {
            return string
        }
        return nil
    }

    func toolCalls(
        from partialCalls: [String: MSPResponsesFunctionCallAccumulator]
    ) throws -> [MSPAgentToolCall] {
        try partialCalls.values
            .sorted { left, right in
                if left.outputIndex != right.outputIndex {
                    return left.outputIndex < right.outputIndex
                }
                return (left.callID ?? left.itemID ?? "") < (right.callID ?? right.itemID ?? "")
            }
            .map { partial in
                let rawName = partial.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rawName.isEmpty else {
                    throw MSPAgentModelClientError.unknownTool("unknown")
                }
                let arguments: [String: MSPAgentJSONValue]
                if partial.kind == .custom {
                    arguments = [:]
                } else {
                    do {
                        arguments = try toolArguments(from: partial.arguments)
                    } catch {
                        guard rawName == MSPUpdatePlanToolSchema.name else {
                            throw error
                        }
                        arguments = [:]
                    }
                }
                return MSPAgentToolCall(
                    id: partial.callID ?? partial.itemID ?? UUID().uuidString,
                    name: MSPAgentToolName(apiName: rawName),
                    kind: partial.kind,
                    rawArguments: partial.kind == .custom ? nil : partial.arguments,
                    arguments: arguments,
                    input: partial.kind == .custom ? partial.input : nil
                )
            }
    }

    func toolArguments(from text: String) throws -> [String: MSPAgentJSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw MSPAgentModelClientError.invalidToolArguments("Tool arguments are not valid UTF-8.")
        }
        let value = try JSONDecoder().decode(MSPAgentJSONValue.self, from: data)
        guard case let .object(arguments) = value else {
            throw MSPAgentModelClientError.invalidToolArguments("Tool arguments must be a JSON object.")
        }
        return arguments
    }
}
