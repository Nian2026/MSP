@testable import MSPAgentBridge
import XCTest

final class MSPAgentPromptTranscriptProjectionTests: XCTestCase {
    func testIncrementalAppendMatchesFullNormalizationForSelfContainedItems() throws {
        let baseItems = [
            Self.message(
                id: "local-message-id",
                role: "assistant",
                phase: "final_answer",
                text: "第一轮完成。"
            )
        ]
        let normalizedBaseItems = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(baseItems)
        let baseProjection = MSPAgentPromptTranscriptProjection(
            transcriptRevision: 1,
            items: normalizedBaseItems,
            estimatedTokenCount: MSPAgentConversation.approximateTokenCount(in: normalizedBaseItems)
        )
        let appendedItems = [
            Self.message(
                id: "msg_provider_kept",
                role: "assistant",
                phase: "assistant_message",
                text: "我来检查。"
            ),
            Self.functionCall(callID: "call_1"),
            Self.functionCallOutput(callID: "call_1", output: "ok")
        ]

        let incrementalProjection = try XCTUnwrap(
            MSPAgentPromptTranscriptNormalizer.incrementallyAppending(
                appendedItems,
                to: baseProjection,
                nextTranscriptRevision: 2
            )
        )
        let fullItems = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(
            baseItems + appendedItems
        )

        XCTAssertEqual(incrementalProjection.transcriptRevision, 2)
        XCTAssertEqual(incrementalProjection.items, fullItems)
        XCTAssertEqual(
            incrementalProjection.estimatedTokenCount,
            MSPAgentConversation.approximateTokenCount(in: fullItems)
        )
    }

    func testIncrementalAppendFallsBackForOutputMatchingEarlierFunctionCall() {
        let baseItems = [
            Self.functionCall(callID: "call_late")
        ]
        let normalizedBaseItems = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(baseItems)
        let baseProjection = MSPAgentPromptTranscriptProjection(
            transcriptRevision: 1,
            items: normalizedBaseItems,
            estimatedTokenCount: MSPAgentConversation.approximateTokenCount(in: normalizedBaseItems)
        )

        let incrementalProjection = MSPAgentPromptTranscriptNormalizer.incrementallyAppending(
            [Self.functionCallOutput(callID: "call_late", output: "late")],
            to: baseProjection,
            nextTranscriptRevision: 2
        )

        XCTAssertNil(incrementalProjection)
    }

    func testIncrementalAppendFallsBackForCustomOutputMatchingEarlierCustomToolCall() {
        let baseItems = [
            Self.customToolCall(callID: "call_patch")
        ]
        let normalizedBaseItems = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(baseItems)
        let baseProjection = MSPAgentPromptTranscriptProjection(
            transcriptRevision: 1,
            items: normalizedBaseItems,
            estimatedTokenCount: MSPAgentConversation.approximateTokenCount(in: normalizedBaseItems)
        )

        let incrementalProjection = MSPAgentPromptTranscriptNormalizer.incrementallyAppending(
            [Self.customToolCallOutput(callID: "call_patch", output: "done")],
            to: baseProjection,
            nextTranscriptRevision: 2
        )

        XCTAssertNil(incrementalProjection)
    }

    func testPromptProjectionTruncatesLargeToolOutputWithoutMutatingStoredItem() throws {
        let largeOutput = String(repeating: "0123456789abcdef\n", count: 2_000)
        let items = [
            Self.functionCall(callID: "call_large"),
            Self.functionCallOutput(callID: "call_large", output: largeOutput)
        ]

        let normalized = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(
            items,
            maxToolOutputTokens: 120
        )

        let projectedOutput = try XCTUnwrap(
            normalized[1].objectValue?["output"]?.stringValue
        )
        XCTAssertTrue(projectedOutput.contains("tool output was preserved in the durable transcript"))
        XCTAssertTrue(projectedOutput.contains("tokens truncated"))
        XCTAssertLessThan(projectedOutput.utf8.count, largeOutput.utf8.count)
        XCTAssertEqual(items[1].objectValue?["output"]?.stringValue, largeOutput)
    }

    func testPromptNormalizationRemovesOrphanFunctionAndCustomToolOutputs() {
        let normalized = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt([
            Self.functionCallOutput(callID: "call_missing", output: "orphan"),
            Self.customToolCallOutput(callID: "call_custom_missing", output: "orphan custom"),
            Self.functionCall(callID: "call_kept"),
            Self.functionCallOutput(callID: "call_kept", output: "ok"),
            Self.customToolCall(callID: "call_custom_kept"),
            Self.customToolCallOutput(callID: "call_custom_kept", output: "custom ok")
        ])
        let pairs = normalized.compactMap { item -> String? in
            guard let object = item.objectValue,
                  let type = object["type"]?.stringValue,
                  type == "function_call_output" || type == "custom_tool_call_output" else {
                return nil
            }
            return "\(type):\(object["call_id"]?.stringValue ?? "")"
        }

        XCTAssertEqual(pairs, [
            "function_call_output:call_kept",
            "custom_tool_call_output:call_custom_kept"
        ])
    }

    func testPromptNormalizationInsertsMatchingAbortedOutputsForMissingToolResults() {
        let normalized = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt([
            Self.functionCall(callID: "call_exec_missing"),
            Self.customToolCall(callID: "call_custom_missing")
        ])
        let pairs = normalized.compactMap { item -> String? in
            guard let object = item.objectValue,
                  let type = object["type"]?.stringValue,
                  type == "function_call_output" || type == "custom_tool_call_output" else {
                return nil
            }
            return [
                type,
                object["call_id"]?.stringValue ?? "",
                object["output"]?.stringValue ?? ""
            ].joined(separator: ":")
        }

        XCTAssertEqual(pairs, [
            "function_call_output:call_exec_missing:aborted",
            "custom_tool_call_output:call_custom_missing:aborted"
        ])
    }

    func testContextWindowExceededDetectionAcceptsProviderMessageText() {
        XCTAssertTrue(MSPAgentToolLoop.isLikelyContextWindowExceededError(
            MSPAgentModelClientError.apiError("Your input exceeds the context window of this model.")
        ))
        XCTAssertTrue(MSPAgentToolLoop.isLikelyContextWindowExceededError(
            MSPAgentModelClientError.apiError("context_length_exceeded")
        ))
    }

    func testTransientStreamErrorDetectionAcceptsHTTP2InternalErrorText() {
        XCTAssertTrue(MSPAgentToolLoop.isTransientModelStreamError(
            MSPAgentModelClientError.apiError(
                "stream error: stream ID 7; INTERNAL_ERROR; received from peer"
            )
        ))
    }

    private static func message(
        id: String,
        role: String,
        phase: String,
        text: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "id": .string(id),
            "role": .string(role),
            "phase": .string(phase),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private static func functionCall(callID: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call"),
            "id": .string("fc_\(callID)"),
            "call_id": .string(callID),
            "name": .string(MSPAgentToolName.execCommand.rawValue),
            "arguments": .string(#"{"cmd":"pwd"}"#)
        ])
    }

    private static func functionCallOutput(
        callID: String,
        output: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(output)
        ])
    }

    private static func customToolCall(callID: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("custom_tool_call"),
            "id": .string("ctc_\(callID)"),
            "call_id": .string(callID),
            "name": .string(MSPAgentToolName.applyPatch.rawValue),
            "input": .string("*** Begin Patch\n*** End Patch\n")
        ])
    }

    private static func customToolCallOutput(
        callID: String,
        output: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("custom_tool_call_output"),
            "call_id": .string(callID),
            "output": .string(output)
        ])
    }
}
