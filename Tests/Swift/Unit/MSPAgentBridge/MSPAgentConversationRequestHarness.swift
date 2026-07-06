import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


private actor CapturedRequests {
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) -> Int {
        let index = requests.count
        requests.append(request)
        return index
    }

    func count() -> Int {
        requests.count
    }

    func body(at index: Int) throws -> [String: Any] {
        guard requests.indices.contains(index) else {
            XCTFail("missing captured request at index \(index); captured \(requests.count) request(s)")
            return [:]
        }
        let request = requests[index]
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func path(at index: Int) -> String {
        guard requests.indices.contains(index) else {
            XCTFail("missing captured request at index \(index); captured \(requests.count) request(s)")
            return ""
        }
        return requests[index].url?.path ?? ""
    }
}

actor DynamicDeveloperContextCounter {
    private var value = 0

    func next() -> String {
        value += 1
        return "dynamic tree version \(value)"
    }
}
final class RequestCaptureHarness: @unchecked Sendable {
    typealias CommandRunner = @Sendable (String) async -> MSPCommandResult

    private let streams: [String]
    private let commandRunner: CommandRunner
    private let execCommandBridge: MSPExecCommandBridge
    private let applyPatchExecutor: (any MSPApplyPatchExecuting)?
    private let response: HTTPURLResponse
    private let capturedRequests = CapturedRequests()

    init(
        streams: [String],
        commandRunner: @escaping CommandRunner = { cmd in
            XCTAssertEqual(cmd, "pwd")
            return .success(stdout: "/\n")
        },
        execCommandBridge: MSPExecCommandBridge? = nil,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil
    ) throws {
        self.streams = streams
        self.commandRunner = commandRunner
        self.execCommandBridge = execCommandBridge ?? MSPExecCommandBridge(runCommand: commandRunner)
        self.applyPatchExecutor = applyPatchExecutor
        let endpoint = try XCTUnwrap(URL(string: "https://example.test/v1/responses"))
        self.response = try XCTUnwrap(
            HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )
        )
    }

    func makeConversation(
        toolCallLimit: MSPAgentToolCallLimit = .unlimited,
        model: String = "test-model",
        providerName: String = "OpenAI",
        baseURL: URL = URL(string: "https://example.test/v1")!,
        tools: [MSPAgentModelToolDefinition] = MSPAgentRequestBuilder.defaultToolDefinitions,
        compactionPolicy: MSPCompactionPolicy = .disabled,
        planProgressCapability: MSPPlanProgressCapability = .disabled,
        compactionHooks: any MSPCompactionLifecycleHookRuntime = MSPNoopCompactionLifecycleHookRuntime(),
        compactionPersistenceAdapter: any MSPCompactionPersistenceAdapter = MSPNoopCompactionPersistenceAdapter()
    ) -> MSPAgentConversation {
        let client = MSPResponsesStreamingModelClient(
            configuration: MSPAgentModelConfiguration(
                baseURL: baseURL,
                apiKey: "test-key",
                model: model,
                providerName: providerName,
                supportsRequestMetadata: true
            ),
            transport: { [streams, response, capturedRequests] request in
                let index = await capturedRequests.append(request)
                guard streams.indices.contains(index) else {
                    XCTFail("missing response stream fixture for request index \(index); configured \(streams.count) stream(s)")
                    return MSPResponsesHTTPStream(
                        response: response,
                        bytes: Self.byteStream("")
                    )
                }
                return MSPResponsesHTTPStream(
                    response: response,
                    bytes: Self.byteStream(streams[index])
                )
            }
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            toolCallLimit: toolCallLimit
        )
        let configuration = MSPAgentConversationConfiguration(
            model: model,
            environmentNotes: [
                "Execution surface: unit test.",
                "Workspace root visible to you: /"
            ],
            tools: tools,
            compactionPolicy: compactionPolicy,
            planProgressCapability: planProgressCapability
        )
        return runtime.makeConversation(
            configuration: configuration,
            compactionHooks: compactionHooks,
            compactionPersistenceAdapter: compactionPersistenceAdapter
        )
    }

    func makeConversation(
        maximumToolCalls: Int,
        model: String = "test-model"
    ) -> MSPAgentConversation {
        makeConversation(
            toolCallLimit: .maximum(maximumToolCalls),
            model: model
        )
    }

    func capturedBody(at index: Int) async throws -> [String: Any] {
        try await capturedRequests.body(at: index)
    }

    func capturedPath(at index: Int) async -> String {
        await capturedRequests.path(at: index)
    }

    func requestCount() async -> Int {
        await capturedRequests.count()
    }

    private static func byteStream(_ text: String) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in text.utf8 {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}
