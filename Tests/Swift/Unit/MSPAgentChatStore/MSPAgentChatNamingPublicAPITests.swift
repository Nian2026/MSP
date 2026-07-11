import Foundation
import MSPAgentBridge
import MSPAgentChatStore
import XCTest

final class MSPAgentChatNamingPublicAPITests: XCTestCase {
    func testQuickStartUsesOnlyPublicBoundAPIs() async throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("chat")
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chat_public_naming_api"
        )
        let naming = try session.makeChatNamingIntegration(
            titleGenerator: PublicAPITitleGenerator(),
            automaticallyBackfillsHistoricalTitle: false
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in PublicAPIModelClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "main-model",
                compactionPolicy: .disabled
            ),
            chatNaming: naming
        )

        let generated = try await naming.generateTitleIfNeeded(
            input: MSPChatNamingInput(text: "Add ChatNaming")
        )
        let manual = try await naming.setManualTitle(
            "Developer title",
            searchDescription: .replace("Developer search description")
        )
        await naming.cancelPendingNaming()

        XCTAssertEqual(conversation.chatID, naming.chatID)
        XCTAssertEqual(generated.metadata.title, "Add ChatNaming")
        XCTAssertEqual(manual.title, "Developer title")
        XCTAssertEqual(
            manual.searchDescription,
            "Developer search description"
        )
    }
}

private struct PublicAPITitleGenerator: MSPChatTitleGenerating {
    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        MSPChatTitleSuggestion(
            title: "Add ChatNaming",
            searchDescription: "Public SDK integration"
        )
    }
}

private struct PublicAPIModelClient: MSPAgentModelTurnClient {
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        MSPAgentModelTurnOutput(finalAnswer: "ok")
    }
}
