import Foundation

public enum MSPTurnSteerChatMapping {
    public static let turnSteeredTimelineType = "turn_steered"

    public static func modelVisibleItems(
        for input: MSPTurnSteerInput
    ) -> [MSPAgentJSONValue] {
        input.additionalContextItems + [
            userMessageItem(for: input)
        ]
    }

    public static func userMessageItem(
        for input: MSPTurnSteerInput
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array(input.content.map { content in
                .object([
                    "type": .string("input_text"),
                    "text": .string(content.text)
                ])
            })
        ])
    }

    public static func timelinePayload(
        for event: MSPTurnSteerAppliedEvent
    ) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "turn_id": .string(event.turnID),
            "sequence": .number(Double(event.sequenceNumber)),
            "content": .string(event.contentText),
            "boundary": .string(event.boundary.rawValue),
            "model_input_item_count": .number(Double(event.modelInputItemCount))
        ]
        if let clientUserMessageID = event.clientUserMessageID {
            payload["client_user_message_id"] = .string(clientUserMessageID)
        }
        return payload
    }

    public static func referenceContextEvent(
        for event: MSPTurnSteerAppliedEvent
    ) -> MSPAgentJSONValue {
        .object([
            "kind": .string(turnSteeredTimelineType),
            "id": .string("\(event.turnID)#\(event.sequenceNumber)"),
            "turn_id": .string(event.turnID),
            "sequence": .number(Double(event.sequenceNumber)),
            "boundary": .string(event.boundary.rawValue)
        ])
    }
}
