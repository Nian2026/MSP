import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPAgentToolLoopProvenanceTests: XCTestCase {
    func testRuntimeEmitsModelResponseAndFinalAnswerProvenanceProbes() async throws {
        let events = MSPAgentToolLoopProvenanceEvents()
        let client = MSPAgentToolLoopProvenanceClient(output: MSPAgentModelTurnOutput(
            assistantMessage: "Ready.",
            finalAnswer: "Done.",
            responseID: "resp_probe",
            nativeOutputItems: [
                Self.message(role: "assistant", text: "Ready."),
                Self.message(role: "assistant", text: "Done.")
            ],
            sawCompleted: true
        ))
        let loop = MSPAgentToolLoop(modelClient: client)

        let result = try await loop.run(
            request: Self.envelope(input: [
                Self.message(role: "developer", text: "developer context"),
                Self.message(role: "user", text: "probe final answer")
            ]),
            initialTranscriptAppendItems: [],
            onEvent: { event in
                await events.append(event)
            },
            executeTool: { call in
                XCTFail("probe scenario should not execute tool \(call.name.rawValue)")
                return MSPAgentToolResult(
                    callID: call.id,
                    name: call.name,
                    ok: false,
                    content: nil,
                    errorMessage: "unexpected tool call"
                )
            }
        )

        XCTAssertEqual(result.finalAnswer, "Done.")
        let responseCompleted = await events.probes(named: "model_response_completed")
        let finalAnswerProvenance = await events.probes(named: "model_final_answer_provenance")
        XCTAssertEqual(responseCompleted.count, 1)
        XCTAssertEqual(finalAnswerProvenance.count, 1)

        let responseFields = try XCTUnwrap(responseCompleted.first?.fields)
        XCTAssertEqual(responseFields["response_id"], "resp_probe")
        XCTAssertEqual(responseFields["response_completed"], "true")
        XCTAssertEqual(responseFields["source"], "responses_stream")
        XCTAssertEqual(responseFields["output_item_count"], "2")
        XCTAssertEqual(responseFields["tool_call_count"], "0")
        XCTAssertEqual(responseFields["has_final_answer"], "true")
        XCTAssertEqual(responseFields["has_assistant_message"], "true")
        XCTAssertEqual(responseFields["model_request_model"], "gpt-5")
        XCTAssertEqual(responseFields["request_user_input_count"], "1")

        let provenanceFields = try XCTUnwrap(finalAnswerProvenance.first?.fields)
        XCTAssertEqual(provenanceFields["response_id"], "resp_probe")
        XCTAssertEqual(provenanceFields["response_completed"], "true")
        XCTAssertEqual(provenanceFields["source"], "provider_stream_final_answer")
        XCTAssertEqual(provenanceFields["text_length"], "5")
        XCTAssertEqual(provenanceFields["text_hash_algorithm"], "sha256-utf8")
        XCTAssertEqual(provenanceFields["text_sha256"]?.count, 64)
        XCTAssertEqual(provenanceFields["output_item_count"], "2")
        XCTAssertEqual(provenanceFields["tool_call_count"], "0")
        XCTAssertEqual(provenanceFields["model_request_model"], "gpt-5")
        XCTAssertEqual(provenanceFields["request_user_input_count"], "1")
    }

    private static func envelope(input: [MSPAgentJSONValue]) -> MSPAgentRequestEnvelope {
        MSPAgentRequestEnvelope(
            payload: [
                "model": .string("gpt-5"),
                "input": .array(input)
            ],
            input: input
        )
    }

    private static func message(role: String, text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .array([
                .object([
                    "type": .string(role == "user" ? "input_text" : "output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }
}

private final class MSPAgentToolLoopProvenanceClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let output: MSPAgentModelTurnOutput

    init(output: MSPAgentModelTurnOutput) {
        self.output = output
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        output
    }
}

private actor MSPAgentToolLoopProvenanceEvents {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func probes(named name: String) -> [MSPAgentProbeEvent] {
        events.compactMap { event in
            if case .probe(let probe) = event,
               probe.name == name {
                return probe
            }
            return nil
        }
    }
}
