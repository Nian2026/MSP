import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


extension MSPAgentConversationAutoCompactionRequestTests {
    func testPreTurnBodyAfterPrefixCompactsWhenPreviousServerInputAlreadyExceedsThreshold() async throws {
        let compactSummary = "上一轮服务端 input 已经超过压缩阈值，旧上下文已压缩。"
        let incomingUserMessage = "第二轮：继续下一批"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_server_input_over_threshold",
                messageID: "msg_server_input_over_threshold",
                text: "第一轮完成。",
                inputTokens: 252_000,
                outputTokens: 86,
                totalTokens: 252_086
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            )
        )

        _ = try await conversation.send("第一轮：产生接近窗口上限的上下文")
        _ = try await conversation.send(incomingUserMessage)

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            3,
            "A previous server input above the 90% compact threshold must trigger pre-turn compaction before sending the next user message."
        )

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮：产生接近窗口上限的上下文"))
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains(incomingUserMessage))
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: followupInput).contains("\(Self.codexSummaryPrefix)\n\(compactSummary)"))
        XCTAssertTrue(Self.messageTexts(from: followupInput).contains(incomingUserMessage))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
    }

    func testReplaceTranscriptItemsClearsStaleBodyAfterPrefixCompactionUsage() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_stale_prefill",
                messageID: "msg_stale_prefill",
                text: "第一轮完成。",
                inputTokens: 10,
                outputTokens: 10,
                totalTokens: 20
            ),
            Self.finalAnswerStreamWithUsage(
                id: "resp_new_prefill",
                messageID: "msg_new_prefill",
                text: "第二轮完成。",
                inputTokens: 200,
                outputTokens: 244_700,
                totalTokens: 244_900
            ),
            Self.secondTurnFinalAnswerStream(),
            Self.thirdTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            )
        )

        _ = try await conversation.send("第一轮：制造旧 prefill baseline")
        await conversation.replaceTranscriptItems([
            Self.transcriptMessage(
                id: nil,
                role: "user",
                phase: nil,
                contentType: "input_text",
                text: "恢复后的小历史。"
            )
        ])
        _ = try await conversation.send("第二轮：不能用旧 usage 触发压缩")
        _ = try await conversation.send("第三轮：不能沿用旧 prefill baseline 触发压缩")

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            3,
            "Replacing transcript history must clear stale usage and prefill baseline so body-after-prefix auto compaction samples the new window."
        )
        guard requestCount >= 3 else { return }

        let body = try await harness.capturedBody(at: 2)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:恢复后的小历史。",
            "message:user:第二轮：不能用旧 usage 触发压缩",
            "message:assistant:final_answer:第二轮完成。",
            "message:user:第三轮：不能沿用旧 prefill baseline 触发压缩"
        ])
        XCTAssertFalse(Self.messageTexts(from: input).contains("第一轮：制造旧 prefill baseline"))
        XCTAssertFalse(Self.messageTexts(from: input).contains(Self.codexSummarizationPrompt))
    }

    func testResetTranscriptClearsStaleAutoCompactionUsage() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_over_limit",
                messageID: "msg_over_limit",
                text: "第一轮完成。",
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.secondTurnFinalAnswerStream(),
            Self.thirdTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(enabled: true)
        )

        _ = try await conversation.send("第一轮：制造旧 usage")
        await conversation.resetTranscript()
        _ = try await conversation.send("第二轮：空历史不能用旧 usage 触发压缩")

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            2,
            "Resetting transcript history must clear stale context usage so pre-turn auto compaction does not run on an empty new history."
        )
        guard requestCount >= 2 else { return }

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:第二轮：空历史不能用旧 usage 触发压缩"
        ])
        XCTAssertFalse(Self.messageTexts(from: input).contains("第一轮：制造旧 usage"))
        XCTAssertFalse(Self.messageTexts(from: input).contains(Self.codexSummarizationPrompt))
    }

    func testPreTurnAutoBodyAfterPrefixIgnoresStartingWindowPrefixUntilBodyGrows() async throws {
        let compactSummary = "前缀窗口后的正文增长已经压缩。"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_prefix",
                messageID: "msg_prefix",
                text: "第一轮完成。",
                inputTokens: 10,
                outputTokens: 10,
                totalTokens: 20
            ),
            Self.finalAnswerStreamWithUsage(
                id: "resp_growth",
                messageID: "msg_growth",
                text: "第二轮完成。",
                inputTokens: 100,
                outputTokens: 244_800,
                totalTokens: 244_900
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.thirdTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            )
        )

        _ = try await conversation.send("第一轮：建立窗口前缀")
        _ = try await conversation.send("第二轮：正文开始增长")

        var requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            2,
            "BodyAfterPrefix should not compact just because total usage already exceeds the scoped body budget."
        )

        _ = try await conversation.send("第三轮：触发正文增长后的压缩")

        requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 4)

        let compactBody = try await harness.capturedBody(at: 2)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：建立窗口前缀",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：正文开始增长",
            "message:assistant:final_answer:第二轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains("第三轮：触发正文增长后的压缩"))

        let followupBody = try await harness.capturedBody(at: 3)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: followupInput), [
            "message:developer",
            "message:user:第一轮：建立窗口前缀",
            "message:user:第二轮：正文开始增长",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "message:user:第三轮：触发正文增长后的压缩"
        ])
    }

    func testPreTurnAutoBodyAfterPrefixStillCompactsAtFullContextWindow() async throws {
        let compactSummary = "总上下文窗口已满，即使正文预算未满也完成压缩。"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_small_window",
                messageID: "msg_small_window",
                text: "第一轮完成。",
                inputTokens: 10,
                outputTokens: 10,
                totalTokens: 20
            ),
            Self.finalAnswerStreamWithUsage(
                id: "resp_full_window",
                messageID: "msg_full_window",
                text: "第二轮完成。",
                inputTokens: 271_990,
                outputTokens: 10,
                totalTokens: 272_000
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.thirdTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            )
        )

        _ = try await conversation.send("第一轮：窗口接近上限但正文很小")
        _ = try await conversation.send("第二轮：总窗口触顶")

        var requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 2)

        _ = try await conversation.send("第三轮：总窗口触顶后继续")

        requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 4)

        let compactBody = try await harness.capturedBody(at: 2)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：窗口接近上限但正文很小",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：总窗口触顶",
            "message:assistant:final_answer:第二轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains("第三轮：总窗口触顶后继续"))

        let followupBody = try await harness.capturedBody(at: 3)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: followupInput), [
            "message:developer",
            "message:user:第一轮：窗口接近上限但正文很小",
            "message:user:第二轮：总窗口触顶",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "message:user:第三轮：总窗口触顶后继续"
        ])
    }

    func testPreTurnAutoBodyAfterPrefixServerObservedPrefillOverridesEstimatedAndStaysFixed() async throws {
        let compactSummary = "压缩后先估算前缀，再用服务端输入 token 校准。"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_before_compact",
                messageID: "msg_before_compact",
                text: "第一轮完成。",
                inputTokens: 10,
                outputTokens: 244_800,
                totalTokens: 244_810
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.finalAnswerStreamWithUsage(
                id: "resp_server_prefill",
                messageID: "msg_server_prefill",
                text: "压缩后第一轮完成。",
                inputTokens: 100_000,
                outputTokens: 160_000,
                totalTokens: 260_000
            ),
            Self.finalAnswerStreamWithUsage(
                id: "resp_later_server_usage",
                messageID: "msg_later_server_usage",
                text: "压缩后第二轮完成。",
                inputTokens: 80,
                outputTokens: 244_820,
                totalTokens: 244_900
            ),
            Self.compactSummaryStream(text: "如果 server-observed baseline 被覆盖，这个流会被错误地当成压缩摘要。"),
            Self.fourthTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            )
        )

        _ = try await conversation.send("第一轮：触发第一次正文预算压缩")
        _ = try await conversation.send("第二轮：压缩后记录第一次服务端输入")

        var requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            3,
            "second turn should compact once, then sample the first server-observed input in the new window."
        )

        _ = try await conversation.send("第三轮：如果还用 estimated baseline 就会错误压缩")

        requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            4,
            "first server-observed input should replace the post-compaction estimated baseline."
        )

        _ = try await conversation.send("第四轮：如果后续 server input 覆盖 baseline 就会错误压缩")

        requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            5,
            "later server usage must not replace the first server-observed prefill baseline."
        )

        let fourthBody = try await harness.capturedBody(at: 4)
        let fourthInput = try XCTUnwrap(fourthBody["input"] as? [[String: Any]])
        XCTAssertFalse(Self.messageTexts(from: fourthInput).contains(Self.codexSummarizationPrompt))
    }
}
