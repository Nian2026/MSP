import XCTest
@testable import MSPAgentBridge

final class MSPEffectiveContextWindowRuntimeTests: XCTestCase {
    func testFullWindowRecordUsesEffectiveRatherThanPhysicalWindow() throws {
        let profile = MSPModelCatalogManager.bundledSnapshot
            .resolvedProfile(for: "gpt-5.6-sol")

        let record = try XCTUnwrap(
            MSPAgentContextUsageAdapter.fullWindowRecord(profile: profile)
        )

        XCTAssertEqual(record.contextWindowTokens, 372_000)
        XCTAssertEqual(record.effectiveContextWindowTokens, 353_400)
        XCTAssertEqual(record.estimatedInputTokens, 353_400)
        XCTAssertEqual(record.currentTokens, 353_400)
        XCTAssertEqual(record.currentWindowFraction, 1.0)
    }

    func testRemoteCompactRewriteCanUseResolvedEffectiveWindow() throws {
        let profile = MSPModelCatalogManager.bundledSnapshot
            .resolvedProfile(for: "gpt-5.6-sol")
        let contextWindow = try XCTUnwrap(profile.effectiveContextWindowTokens)
        XCTAssertEqual(
            MSPAgentConversation.remoteCompactFitContextWindow(
                latestContextUsage: nil,
                resolvedModelProfile: profile
            ),
            353_400
        )
        let latestUsage = MSPAgentContextUsageRecord(
            modelID: "remote-model",
            modelDisplayName: "Remote Model",
            contextWindowTokens: 200_000,
            effectiveContextWindowTokens: 180_000,
            autoCompactTokenLimit: 170_000,
            estimatedInputTokens: 180_000,
            currentTokens: 180_000,
            serverInputTokens: 180_000,
            serverOutputTokens: nil,
            serverTotalTokens: nil
        )
        XCTAssertEqual(latestUsage.currentWindowFraction, 1.0)
        XCTAssertEqual(latestUsage.serverInputWindowFraction, 1.0)
        XCTAssertEqual(
            MSPAgentConversation.remoteCompactFitContextWindow(
                latestContextUsage: latestUsage,
                resolvedModelProfile: nil
            ),
            180_000
        )
        XCTAssertEqual(
            MSPAgentConversation.remoteCompactFitContextWindow(
                latestContextUsage: latestUsage,
                resolvedModelProfile: profile
            ),
            353_400
        )
        XCTAssertEqual(
            MSPAgentConversation.localCompactionRewriteContextWindow(
                latestContextUsage: latestUsage,
                resolvedModelProfile: profile
            ),
            353_400
        )
        let input: [MSPAgentJSONValue] = [
            .object([
                "type": .string("function_call_output"),
                "call_id": .string("call_1"),
                "output": .string("large output")
            ])
        ]

        let rewrite = MSPCompactionRequestBuilder()
            .remoteCompactInputByRewritingOutputsToFitContextWindow(
                input,
                contextWindow: contextWindow,
                estimatedTokenCount: { items in
                    items == input ? contextWindow + 1 : contextWindow - 1
                }
            )

        XCTAssertEqual(rewrite.rewrittenOutputCount, 1)
        XCTAssertEqual(
            rewrite.input[0].objectValue?["output"],
            .string(MSPCompactionRequestBuilder.remoteCompactTruncatedOutputMessage)
        )
    }
}
