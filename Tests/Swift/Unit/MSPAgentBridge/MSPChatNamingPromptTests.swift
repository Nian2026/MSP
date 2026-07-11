import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPChatNamingPromptTests: XCTestCase {
    func testNamingDefaultsAndProviderNeutralPromptRules() {
        let limits = MSPChatNamingLimits.codexCompatible
        XCTAssertEqual(limits.titleMaximumCharacters, 36)
        XCTAssertEqual(limits.descriptionMaximumCharacters, 100)
        XCTAssertEqual(limits.inputMaximumCharacters, 2_000)
        XCTAssertEqual(limits.fallbackMaximumCharacters, 60)
        XCTAssertEqual(
            MSPChatNamingConfiguration.codexCompatibleTimeoutNanoseconds,
            30_000_000_000
        )
        XCTAssertEqual(
            MSPChatNamingConfiguration.codexReferenceModel,
            "gpt-5.4-mini"
        )

        let titleInstructions = MSPChatNamingPrompt.titleInstructions()
        XCTAssertTrue(titleInstructions.contains("structured description field"))
        XCTAssertTrue(titleInstructions.contains("responsibility terms"))
        XCTAssertTrue(titleInstructions.contains("Locate cacheKey generation"))
        XCTAssertTrue(titleInstructions.contains("do not invent details"))
        XCTAssertTrue(
            MSPChatNamingPrompt.searchDescriptionInstructions()
                .contains("Repeat 3 to 6 distinctive nouns")
        )
    }

    func testPreparedPromptCombinesPartsUsesLastRequestWrapperAndTruncates() {
        let prompt = MSPChatNamingPrompt.preparedPrompt(
            from: MSPChatNamingInput(parts: [
                .text("ignored prefix"),
                .pastedTextExcerpt("pasted excerpt"),
                .text(
                    "## My request for Codex: first request\n" +
                    "## My request for Codex: 最后的真实请求"
                )
            ]),
            maximumCharacters: 7
        )

        XCTAssertEqual(prompt, "最后的真实请求")
        XCTAssertEqual(prompt.count, 7)
    }

    func testFallbackBecomesPlainSingleLineAndFitsTotalLimit() {
        let fallback = MSPChatNamingPrompt.fallbackTitle(
            from: MSPChatNamingInput(
                text: "## My request for Codex:\n# **修复** [标题](https://example.com) "
                    + String(repeating: "很长", count: 50)
            ),
            maximumCharacters: 60
        )

        XCTAssertLessThanOrEqual(fallback.count, 60)
        XCTAssertTrue(fallback.hasSuffix("…"))
        XCTAssertFalse(fallback.contains("**"))
        XCTAssertFalse(fallback.contains("https://"))
        XCTAssertFalse(fallback.contains("\n"))
    }

    func testFallbackUsesTheAlreadyBoundedTwoThousandCharacterSeed() {
        let fallback = MSPChatNamingPrompt.fallbackTitle(
            from: MSPChatNamingInput(
                text: String(repeating: "`", count: 2_000) + "tail must not leak"
            )
        )

        XCTAssertEqual(fallback, "")
    }

    func testTitleNormalizerMatchesCodexBareTitlePrefixBoundaries() {
        XCTAssertEqual(
            MSPChatNamingTextNormalizer.title(
                "Title Fix sync",
                maximumCharacters: 36
            ),
            "Fix sync"
        )
        XCTAssertEqual(
            MSPChatNamingTextNormalizer.title(
                "Title: Fix sync",
                maximumCharacters: 36
            ),
            "Fix sync"
        )
        XCTAssertEqual(
            MSPChatNamingTextNormalizer.title(
                "\"Title: Fix sync\"",
                maximumCharacters: 36
            ),
            "Title: Fix sync"
        )
    }
}
