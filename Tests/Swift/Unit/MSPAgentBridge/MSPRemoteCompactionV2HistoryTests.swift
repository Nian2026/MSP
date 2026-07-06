@testable import MSPAgentBridge
import XCTest

extension MSPCompactionHistoryRewriterTests {
    func testRemoteCompactHistoryFiltersServerOutputLikeCodexRemoteV1() {
        let user = Self.message(role: "user", text: "real user")
        let assistant = Self.message(role: "assistant", text: "assistant", contentType: "output_text")
        let agent = Self.agentMessage(text: "agent")
        let compaction = Self.compactionOutput(encryptedContent: "summary")
        let contextCompaction = Self.contextCompaction(id: "cc_1")

        let result = MSPCompactionHistoryRewriter.remoteCompactedHistory(
            serverOutput: [
                Self.message(role: "developer", text: "stale instructions"),
                Self.message(role: "system", text: "system context"),
                Self.message(role: "user", text: "<environment_context>\ncontext\n</environment_context>"),
                user,
                assistant,
                agent,
                Self.item(type: "function_call"),
                Self.functionCallOutput(callID: "call_1", output: "tool output"),
                Self.item(type: "tool_search_output"),
                MSPCompactionRequestBuilder.compactionTriggerItem(),
                compaction,
                contextCompaction
            ]
        )

        XCTAssertEqual(result, [
            user,
            assistant,
            agent,
            compaction,
            contextCompaction
        ])
    }

    func testRemoteCompactHistoryInsertsInitialContextIntoFilteredServerOutput() {
        let initialContext = [
            Self.message(role: "developer", text: "fresh initial context")
        ]
        let output = Self.compactionOutput(encryptedContent: "summary")

        let result = MSPCompactionHistoryRewriter.remoteCompactedHistory(
            serverOutput: [
                Self.message(role: "developer", text: "stale server instructions"),
                output
            ],
            initialContext: initialContext
        )

        XCTAssertEqual(result, initialContext + [output])
    }

    func testRemoteCompactPayloadUsesCodexResponsesCompactShape() throws {
        let builder = MSPCompactionRequestBuilder()
        let input = [Self.message(role: "user", text: "please compact")]
        let envelope = MSPAgentRequestEnvelope(
            payload: [
                "model": .string("gpt-test"),
                "instructions": .string("base instructions"),
                "tools": .array([Self.item(type: "function")]),
                "parallel_tool_calls": .bool(true),
                "reasoning": .object(["effort": .string("medium")]),
                "prompt_cache_key": .string("cache-key"),
                "text": .object(["verbosity": .string("low")]),
                "stream": .bool(true),
                "store": .bool(false),
                "include": .array([.string("unused")]),
                "tool_choice": .string("auto"),
                "metadata": .object(["request_kind": .string("compaction")])
            ],
            input: input
        )

        let payload = try builder.remoteCompactPayload(
            from: envelope,
            serviceTier: "priority"
        )

        XCTAssertEqual(payload.endpoint, "/responses/compact")
        XCTAssertEqual(payload.timeoutIdleMultiplier, 4)
        XCTAssertEqual(payload.body["model"], .string("gpt-test"))
        XCTAssertEqual(payload.body["input"], .array(input))
        XCTAssertEqual(payload.body["instructions"], .string("base instructions"))
        XCTAssertEqual(payload.body["tools"], .array([Self.item(type: "function")]))
        XCTAssertEqual(payload.body["parallel_tool_calls"], .bool(true))
        XCTAssertEqual(payload.body["reasoning"], .object(["effort": .string("medium")]))
        XCTAssertEqual(payload.body["service_tier"], .string("priority"))
        XCTAssertEqual(payload.body["prompt_cache_key"], .string("cache-key"))
        XCTAssertEqual(payload.body["text"], .object(["verbosity": .string("low")]))
        XCTAssertNil(payload.body["metadata"])
        XCTAssertNil(payload.body["stream"])
        XCTAssertNil(payload.body["store"])
        XCTAssertNil(payload.body["include"])
        XCTAssertNil(payload.body["tool_choice"])
    }

    func testRemoteCompactPayloadCanIncludeMetadataForOptInProviders() throws {
        let builder = MSPCompactionRequestBuilder()
        let envelope = MSPAgentRequestEnvelope(
            payload: [
                "model": .string("gpt-test"),
                "metadata": .object(["request_kind": .string("compaction")])
            ],
            input: [Self.message(role: "user", text: "please compact")]
        )

        let payload = try builder.remoteCompactPayload(
            from: envelope,
            includeMetadata: true
        )

        XCTAssertEqual(payload.body["metadata"], .object(["request_kind": .string("compaction")]))
    }

    func testRemoteCompactPayloadRequiresModel() {
        let builder = MSPCompactionRequestBuilder()
        let envelope = MSPAgentRequestEnvelope(
            payload: [:],
            input: [Self.message(role: "user", text: "please compact")]
        )

        XCTAssertThrowsError(try builder.remoteCompactPayload(from: envelope)) { error in
            XCTAssertEqual(error as? MSPRemoteCompactRequestBuildError, .missingModel)
        }
    }

    func testRemoteCompactInputRewritesOutputsToFitContextWindowLikeCodexRemoteV1() {
        let builder = MSPCompactionRequestBuilder()
        let input = [
            Self.message(role: "user", text: "user"),
            Self.functionCallOutput(callID: "call_1", output: "large function output"),
            Self.customToolCallOutput(callID: "call_2", name: "custom", output: "large custom output"),
            Self.toolSearchOutput(
                callID: "call_3",
                status: "completed",
                execution: "done",
                tools: [Self.item(type: "tool_result")]
            )
        ]

        let result = builder.remoteCompactInputByRewritingOutputsToFitContextWindow(
            input,
            contextWindow: 10,
            estimatedTokenCount: Self.remoteRewriteEstimate
        )

        XCTAssertEqual(result.rewrittenOutputCount, 3)
        XCTAssertEqual(result.estimatedDeletedTokens, 147)
        XCTAssertEqual(result.input[0], input[0])
        XCTAssertEqual(
            result.input[1].objectValue?["output"],
            .string(MSPCompactionRequestBuilder.remoteCompactTruncatedOutputMessage)
        )
        XCTAssertEqual(result.input[1].objectValue?["call_id"], .string("call_1"))
        XCTAssertEqual(
            result.input[2].objectValue?["output"],
            .string(MSPCompactionRequestBuilder.remoteCompactTruncatedOutputMessage)
        )
        XCTAssertEqual(result.input[2].objectValue?["name"], .string("custom"))
        XCTAssertEqual(result.input[3].objectValue?["tools"], .array([]))
        XCTAssertEqual(result.input[3].objectValue?["status"], .string("completed"))
        XCTAssertEqual(result.input[3].objectValue?["execution"], .string("done"))
    }

    func testRemoteCompactInputRewriteStopsAtNewestNonRewritableItem() {
        let builder = MSPCompactionRequestBuilder()
        let input = [
            Self.functionCallOutput(callID: "call_1", output: "large function output"),
            Self.message(role: "assistant", text: "newest assistant", contentType: "output_text")
        ]

        let result = builder.remoteCompactInputByRewritingOutputsToFitContextWindow(
            input,
            contextWindow: 10,
            estimatedTokenCount: { _ in 50 }
        )

        XCTAssertEqual(result.rewrittenOutputCount, 0)
        XCTAssertEqual(result.estimatedDeletedTokens, 0)
        XCTAssertEqual(result.input, input)
    }

    func testLocalCompactHistoryRewriteKeepsFixedPromptSuffixFromBlockingToolOutputRewrite() {
        let builder = MSPCompactionRequestBuilder()
        let history = [
            Self.message(role: "user", text: "please inspect"),
            Self.functionCallOutput(callID: "call_1", output: "large function output")
        ]

        let result = builder.localCompactHistoryByRewritingOutputsToFitContextWindow(
            prefixItems: [
                Self.message(role: "developer", text: "base instructions")
            ],
            historyItems: history,
            suffixItems: [
                builder.localPromptItem(prompt: "summarize")
            ],
            contextWindow: 10,
            estimatedTokenCount: Self.remoteRewriteEstimate
        )

        XCTAssertEqual(result.rewrittenOutputCount, 1)
        XCTAssertEqual(result.estimatedDeletedTokens, 49)
        XCTAssertEqual(result.historyItems[0], history[0])
        XCTAssertEqual(
            result.historyItems[1].objectValue?["output"],
            .string(MSPCompactionRequestBuilder.remoteCompactTruncatedOutputMessage)
        )
    }

    func testRemoteV2InputAppendsRequestOnlyCompactionTrigger() {
        let builder = MSPCompactionRequestBuilder()
        let promptInput = [
            Self.message(role: "user", text: "user request")
        ]

        let input = builder.remoteV2Input(promptInput: promptInput)

        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input.first, promptInput.first)
        XCTAssertEqual(input.last, MSPCompactionRequestBuilder.compactionTriggerItem())
        XCTAssertTrue(MSPCompactionRequestBuilder.isCompactionTrigger(try XCTUnwrap(input.last)))
    }

    func testRemoteV2CollectsExactlyOneCompactionOutputAfterCompleted() throws {
        let compaction = Self.compactionOutput(encryptedContent: "encrypted")
        let usage = MSPAgentTokenUsage(inputTokens: 123, outputTokens: 7, totalTokens: 130)

        let output = try MSPCompactionRequestBuilder.collectRemoteV2Output(
            outputItems: [
                Self.message(role: "assistant", text: "ignored", contentType: "output_text"),
                compaction
            ],
            sawCompleted: true,
            tokenUsage: usage
        )

        XCTAssertEqual(output.compactionOutput, compaction)
        XCTAssertEqual(output.tokenUsage, usage)
    }

    func testRemoteV2RejectsZeroOrMultipleCompactionOutputs() throws {
        XCTAssertThrowsError(try MSPCompactionRequestBuilder.collectRemoteV2Output(
            outputItems: [
                Self.message(role: "assistant", text: "ignored", contentType: "output_text")
            ],
            sawCompleted: true
        )) { error in
            XCTAssertEqual(error as? MSPRemoteCompactionV2Error, .invalidCompactionOutputCount(
                compactionCount: 0,
                outputItemCount: 1
            ))
        }

        XCTAssertThrowsError(try MSPCompactionRequestBuilder.collectRemoteV2Output(
            outputItems: [
                Self.compactionOutput(encryptedContent: "first"),
                Self.compactionOutput(encryptedContent: "second")
            ],
            sawCompleted: true
        )) { error in
            XCTAssertEqual(error as? MSPRemoteCompactionV2Error, .invalidCompactionOutputCount(
                compactionCount: 2,
                outputItemCount: 2
            ))
        }
    }

    func testRemoteV2RejectsClosedStreamBeforeCompletedEvenWithCompactionOutput() throws {
        XCTAssertThrowsError(try MSPCompactionRequestBuilder.collectRemoteV2Output(
            outputItems: [
                Self.compactionOutput(encryptedContent: "encrypted")
            ],
            sawCompleted: false
        )) { error in
            XCTAssertEqual(error as? MSPRemoteCompactionV2Error, .streamClosedBeforeCompleted)
        }
    }

    func testRemoteV2CompactedHistoryFiltersToInstalledRetentionShape() {
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                Self.message(role: "developer", text: "dev"),
                Self.message(role: "system", text: "sys"),
                Self.message(role: "user", text: "user"),
                Self.message(role: "assistant", text: "commentary", contentType: "output_text"),
                Self.functionCallOutput(callID: "call_1", output: "ignored"),
                Self.compactionOutput(encryptedContent: "old")
            ],
            compactionOutput: output
        )

        XCTAssertEqual(result.replacementHistory, [
            Self.message(role: "user", text: "user"),
            output
        ])
    }

    func testRemoteV2CompactedHistoryDiscardsContextualMessagesBeforeTruncating() {
        let old = Self.message(role: "user", text: "old")
        let new = Self.message(role: "user", text: "new")
        let hugeDeveloper = String(repeating: "d", count: 200)
        let hugeContext = "<environment_context>\n\(String(repeating: "c", count: 200))\n</environment_context>"
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                old,
                Self.message(role: "developer", text: hugeDeveloper),
                Self.message(role: "user", text: hugeContext),
                new
            ],
            compactionOutput: output,
            retainedMessageTokenBudget: 2
        )

        XCTAssertEqual(result.replacementHistory, [old, new, output])
    }

    func testRemoteV2CompactedHistoryCountsRetainedInputImages() {
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                Self.message(
                    role: "user",
                    content: [
                        Self.content(type: "input_text", text: "user"),
                        Self.imageContent("data:image/png;base64,abc"),
                        Self.imageContent("data:image/png;base64,def")
                    ]
                )
            ],
            compactionOutput: output
        )

        XCTAssertEqual(result.retainedImageCount, 2)
        XCTAssertEqual(result.replacementHistory.count, 2)
    }

    func testRemoteV2RetainedHistoryKeepsNewestMessagesFirst() {
        let middle = Self.message(role: "user", text: "middle1234")
        let new = Self.message(role: "user", text: "new")
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                Self.message(role: "user", text: "old-old"),
                middle,
                new
            ],
            compactionOutput: output,
            retainedMessageTokenBudget: 3
        )

        XCTAssertEqual(result.replacementHistory, [
            Self.message(role: "user", text: "midd…1 tokens truncated…1234"),
            new,
            output
        ])
    }

    func testRemoteV2RetainedHistoryPreservesImagesAndTruncatesLaterTextParts() {
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                Self.message(
                    role: "user",
                    content: [
                        Self.content(type: "input_text", text: "abcdef"),
                        Self.imageContent("data:image/png;base64,abc"),
                        Self.content(type: "output_text", text: "uvwxyz")
                    ]
                )
            ],
            compactionOutput: output,
            retainedMessageTokenBudget: 3
        )

        XCTAssertEqual(result.replacementHistory, [
            Self.message(
                role: "user",
                content: [
                    Self.content(type: "input_text", text: "abcdef"),
                    Self.imageContent("data:image/png;base64,abc"),
                    Self.content(type: "output_text", text: "uv…1 tokens truncated…yz")
                ]
            ),
            output
        ])
        XCTAssertEqual(result.retainedImageCount, 1)
    }

    func testRemoteV2RetainedHistoryChargesImageOnlyMessages() {
        let imageOnly = Self.message(
            role: "user",
            content: [Self.imageContent("data:image/png;base64,abc")]
        )
        let newest = Self.message(role: "user", text: "new")
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                Self.message(role: "user", text: "old"),
                imageOnly,
                newest
            ],
            compactionOutput: output,
            retainedMessageTokenBudget: 2
        )

        XCTAssertEqual(result.replacementHistory, [imageOnly, newest, output])
        XCTAssertEqual(result.retainedImageCount, 1)
    }

    func testRemoteV2RetainedHistoryDropsImageOnlyMessagesAfterBudgetIsSpent() {
        let newest = Self.message(role: "user", text: "new")
        let output = Self.compactionOutput(encryptedContent: "new")

        let result = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: [
                Self.message(
                    role: "user",
                    content: [Self.imageContent("data:image/png;base64,abc")]
                ),
                newest
            ],
            compactionOutput: output,
            retainedMessageTokenBudget: 1
        )

        XCTAssertEqual(result.replacementHistory, [newest, output])
        XCTAssertEqual(result.retainedImageCount, 0)
    }

    private static func remoteRewriteEstimate(_ items: [MSPAgentJSONValue]) -> Int? {
        items.reduce(0) { total, item in
            total + remoteRewriteWeight(item)
        }
    }

    private static func remoteRewriteWeight(_ item: MSPAgentJSONValue) -> Int {
        guard let object = item.objectValue,
              let type = object["type"]?.stringValue else {
            return 0
        }
        switch type {
        case "function_call_output", "custom_tool_call_output":
            return object["output"] == .string(MSPCompactionRequestBuilder.remoteCompactTruncatedOutputMessage)
                ? 1
                : 50
        case "tool_search_output":
            return object["tools"]?.arrayValue?.isEmpty == true ? 1 : 50
        default:
            return 0
        }
    }
}
