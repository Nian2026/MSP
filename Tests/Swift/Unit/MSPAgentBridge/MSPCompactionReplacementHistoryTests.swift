@testable import MSPAgentBridge
import XCTest

extension MSPCompactionHistoryRewriterTests {
    func testLocalReplacementKeepsRealUsersAndAppendsSummary() throws {
        let existingSummary = "\(MSPCompactionHistoryRewriter.summaryPrefix)\nold summary"
        let result = MSPCompactionHistoryRewriter.localReplacementHistory(
            from: [
                Self.message(role: "developer", text: "developer instructions"),
                Self.message(role: "user", text: "# AGENTS.md instructions for project\n\n<INSTRUCTIONS>\ndo things\n</INSTRUCTIONS>"),
                Self.message(role: "user", text: "first user"),
                Self.message(role: "assistant", text: "assistant output", contentType: "output_text"),
                Self.message(role: "user", text: existingSummary),
                Self.functionCallOutput(callID: "call_1", output: "ignored"),
                Self.message(role: "user", text: "second user")
            ],
            assistantSummary: "new summary"
        )

        XCTAssertEqual(result.retainedUserMessageCount, 2)
        XCTAssertEqual(Self.messageTexts(from: result.replacementHistory), [
            "first user",
            "second user",
            "\(MSPCompactionHistoryRewriter.summaryPrefix)\nnew summary"
        ])
    }

    func testLocalReplacementUsesNewestMessagesWhenBudgetIsSmall() {
        let result = MSPCompactionHistoryRewriter.localReplacementHistory(
            from: [
                Self.message(role: "user", text: "older user message with several words"),
                Self.message(role: "user", text: "latest")
            ],
            assistantSummary: "summary",
            retainedUserMessageTokenBudget: 2
        )

        let texts = Self.messageTexts(from: result.replacementHistory)
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts[0].contains("latest"))
        XCTAssertEqual(texts[1], "\(MSPCompactionHistoryRewriter.summaryPrefix)\nsummary")
    }

    func testInitialContextIsInsertedBeforeLastRealUserMessage() {
        let initialContext = [
            Self.message(role: "developer", text: "fresh context")
        ]
        let summary = "\(MSPCompactionHistoryRewriter.summaryPrefix)\nsummary"
        let compactedHistory = [
            Self.message(role: "user", text: "older user"),
            Self.message(role: "user", text: summary),
            Self.message(role: "user", text: "latest user")
        ]

        let rewritten = MSPCompactionHistoryRewriter.insertingInitialContext(
            initialContext,
            into: compactedHistory
        )

        XCTAssertEqual(Self.signatures(from: rewritten), [
            "user:older user",
            "user:\(summary)",
            "developer:fresh context",
            "user:latest user"
        ])
    }

    func testRewriterOutputSurvivesPromptNormalizer() {
        let result = MSPCompactionHistoryRewriter.localReplacementHistory(
            from: [
                Self.message(role: "user", text: "first user"),
                Self.message(role: "assistant", text: "assistant output", contentType: "output_text")
            ],
            assistantSummary: "summary"
        )

        let normalized = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(
            result.replacementHistory
        )

        XCTAssertEqual(normalized, result.replacementHistory)
    }
}
