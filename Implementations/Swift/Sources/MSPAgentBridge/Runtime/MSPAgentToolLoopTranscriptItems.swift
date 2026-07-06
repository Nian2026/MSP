import Foundation

extension MSPAgentToolLoop {
    static func streamedAssistantTranscriptItems(
        assistantMessage: String,
        finalAnswer: String
    ) -> [MSPAgentJSONValue] {
        [
            streamedAssistantTranscriptItem(
                text: assistantMessage,
                phase: "assistant_message"
            ),
            streamedAssistantTranscriptItem(
                text: finalAnswer,
                phase: "final_answer"
            )
        ].compactMap { $0 }
    }

    private static func streamedAssistantTranscriptItem(
        text: String,
        phase: String
    ) -> MSPAgentJSONValue? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return .object([
            "type": .string("message"),
            "role": .string("assistant"),
            "phase": .string(phase),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }
}
