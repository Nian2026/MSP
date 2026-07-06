import Foundation

extension MSPAgentToolLoop {
    static func responseID(
        for output: MSPAgentModelTurnOutput,
        latestResponseID: String?
    ) -> String {
        let outputResponseID = output.responseID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let outputResponseID, !outputResponseID.isEmpty {
            return outputResponseID
        }
        return latestResponseID ?? ""
    }

    static func modelResponseCompletedProbeEvent(
        output: MSPAgentModelTurnOutput,
        latestResponseID: String?,
        requestEvidence: MSPAgentModelRequestEvidence?
    ) -> MSPAgentProbeEvent {
        var fields = [
            "response_id": responseID(for: output, latestResponseID: latestResponseID),
            "response_completed": "\(output.sawCompleted)",
            "source": "responses_stream",
            "output_item_count": "\(output.nativeOutputItems.count)",
            "tool_call_count": "\(output.toolCalls.count)",
            "has_final_answer": "\(output.finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)",
            "has_assistant_message": "\(output.assistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)"
        ]
        if let requestEvidence {
            fields.merge(requestEvidence.responseFields) { _, new in new }
        }
        return MSPAgentProbeEvent(
            name: "model_response_completed",
            fields: fields
        )
    }

    static func finalAnswerProvenanceProbeEvent(
        answer: String,
        output: MSPAgentModelTurnOutput,
        latestResponseID: String?,
        requestEvidence: MSPAgentModelRequestEvidence?,
        source: String = "provider_stream_final_answer"
    ) -> MSPAgentProbeEvent {
        var fields = [
            "response_id": responseID(for: output, latestResponseID: latestResponseID),
            "response_completed": "\(output.sawCompleted)",
            "source": source,
            "text_length": "\(answer.count)",
            "text_hash_algorithm": "sha256-utf8",
            "text_sha256": MSPAgentModelRequestEvidence.sha256Hex(answer),
            "output_item_count": "\(output.nativeOutputItems.count)",
            "tool_call_count": "\(output.toolCalls.count)"
        ]
        if let requestEvidence {
            fields.merge(requestEvidence.responseFields) { _, new in new }
        }
        return MSPAgentProbeEvent(
            name: "model_final_answer_provenance",
            fields: fields
        )
    }

}
