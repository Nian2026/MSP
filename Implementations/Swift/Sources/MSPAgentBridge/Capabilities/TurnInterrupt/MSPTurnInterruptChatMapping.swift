import Foundation

public enum MSPTurnInterruptChatMapping {
    public static let turnAbortedTimelineType = "turn_aborted"

    public static func interruptedMarkerInputItem() -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(MSPAgentInterruptedTurnMarker.text)
                ])
            ])
        ])
    }

    public static func abortedToolOutputItem(callID: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string("aborted")
        ])
    }

    public static func timelinePayload(
        for event: MSPTurnInterruptTurnAbortedEvent
    ) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "reason": .string(event.reason.rawValue)
        ]
        payload["turn_id"] = event.turnID.map(MSPAgentJSONValue.string) ?? .null
        if let duration = event.durationMilliseconds {
            payload["duration_ms"] = .number(Double(duration))
        }
        return payload
    }

    public static func referenceContextEvent(
        for event: MSPTurnInterruptTurnAbortedEvent
    ) -> MSPAgentJSONValue {
        .object([
            "kind": .string(turnAbortedTimelineType),
            "id": event.turnID.map(MSPAgentJSONValue.string) ?? .null,
            "reason": .string(event.reason.rawValue)
        ])
    }
}
