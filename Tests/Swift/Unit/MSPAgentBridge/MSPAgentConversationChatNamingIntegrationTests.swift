import XCTest
import MSPCore
@testable import MSPAgentBridge

final class MSPAgentConversationChatNamingIntegrationTests: XCTestCase {
    func testLegacyOneArgumentConversationFactoryRemainsReferenceable() {
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in MSPChatNamingMainTurnClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )
        let makeConversation:
            (MSPAgentConversationConfiguration) -> MSPAgentConversation =
            runtime.makeConversation(configuration:)

        let conversation = makeConversation(
            MSPAgentConversationConfiguration(
                model: "main-model",
                compactionPolicy: .disabled
            )
        )

        XCTAssertFalse(conversation.chatID.isEmpty)
        XCTAssertEqual(conversation.threadID, conversation.chatID)
    }

    func testSendStartsChatNamingInParallelWithoutJoiningMainTurn() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingChatTitleGenerator(
            suggestion: MSPChatTitleSuggestion(
                title: "Generated title",
                searchDescription: "Search description"
            )
        )
        let updated = expectation(description: "Chat title updated")
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store,
            onEvent: { event in
                if case .titleUpdated = event {
                    updated.fulfill()
                }
            }
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in MSPChatNamingMainTurnClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "main-model",
                tools: [],
                toolChoice: "none",
                compactionPolicy: .disabled
            ),
            chatID: "chat-integration",
            chatNamingCoordinator: coordinator
        )

        let send = Task {
            try await conversation.send(
                "Visible request",
                chatNamingInput: MSPChatNamingInput(
                    text: "wrapped\n## My request for Codex: Real request",
                    pastedTextExcerpts: ["Pasted context"]
                )
            )
        }
        await generator.waitUntilStarted()

        // The main turn completes while the independent naming request is
        // deliberately still blocked.
        let result = try await send.value
        XCTAssertEqual(result.finalAnswer, "main answer")
        XCTAssertEqual(conversation.chatID, "chat-integration")
        let metadataWhileNaming = await store.snapshot(for: "chat-integration")
        XCTAssertTrue(metadataWhileNaming.isUntitled)

        await generator.release()
        await fulfillment(of: [updated], timeout: 2)

        let metadata = await store.snapshot(for: "chat-integration")
        XCTAssertEqual(metadata.title, "Generated title")
        XCTAssertEqual(metadata.searchDescription, "Search description")
        let requests = await generator.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.prompt, "Real request\n\nPasted context")
    }

    func testConversationWithoutCoordinatorPerformsNoNamingWork() async throws {
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in MSPChatNamingMainTurnClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "main-model",
                tools: [],
                toolChoice: "none",
                compactionPolicy: .disabled
            ),
            chatID: "chat-no-naming"
        )

        let result = try await conversation.send("No extra model request")

        XCTAssertEqual(result.finalAnswer, "main answer")
        XCTAssertEqual(conversation.chatID, "chat-no-naming")
    }

    func testOnlyTheFirstSendSchedulesInitialChatNaming() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPChatTitleRequestRecorder(
            suggestion: MSPChatTitleSuggestion(title: "First request title")
        )
        let updated = expectation(description: "First title updated")
        let unexpectedSkip = expectation(
            description: "Later sends must not retry initial naming"
        )
        unexpectedSkip.isInverted = true
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store,
            onEvent: { event in
                switch event {
                case .titleUpdated:
                    updated.fulfill()
                case .titleGenerationSkipped:
                    unexpectedSkip.fulfill()
                default:
                    break
                }
            }
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in MSPChatNamingMainTurnClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "main-model",
                tools: [],
                toolChoice: "none",
                compactionPolicy: .disabled
            ),
            chatID: "chat-first-send-only",
            chatNamingCoordinator: coordinator
        )

        _ = try await conversation.send("First request")
        await fulfillment(of: [updated], timeout: 2)
        _ = try await conversation.send("Second request")
        await fulfillment(of: [unexpectedSkip], timeout: 0.2)

        let requests = await generator.snapshot()
        XCTAssertEqual(requests.map(\.prompt), ["First request"])
    }
}

private final class MSPChatNamingMainTurnClient:
    MSPAgentModelTurnClient,
    @unchecked Sendable
{
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        MSPAgentModelTurnOutput(finalAnswer: "main answer")
    }
}
