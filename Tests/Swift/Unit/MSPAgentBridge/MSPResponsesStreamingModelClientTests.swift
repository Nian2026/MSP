import Foundation
import MSPAgentBridge
import XCTest

final class MSPResponsesStreamingModelClientTests: XCTestCase {
    func testRemoteCompactionSupportMatchesCodexOpenAIProviderGate() throws {
        let configuration = MSPAgentModelConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1")),
            apiKey: "test-key",
            model: "test-model"
        )

        XCTAssertTrue(configuration.supportsRemoteCompaction)
    }

    func testRemoteCompactionSupportMatchesCodexAzureProviderNameGate() throws {
        let configuration = MSPAgentModelConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/openai")),
            apiKey: "test-key",
            model: "test-model",
            providerName: "aZuRe"
        )

        XCTAssertTrue(configuration.supportsRemoteCompaction)
    }

    func testRemoteCompactionSupportMatchesCodexAzureBaseURLGate() throws {
        let configuration = MSPAgentModelConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://foo.openai.azure.com/openai")),
            apiKey: "test-key",
            model: "test-model",
            providerName: "Example"
        )

        XCTAssertTrue(configuration.supportsRemoteCompaction)
    }

    func testRemoteCompactionSupportRejectsGenericResponsesProvider() throws {
        let genericConfiguration = MSPAgentModelConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://example.test/v1")),
            apiKey: "test-key",
            model: "test-model",
            providerName: "Example"
        )
        let azureWebsiteProxyConfiguration = MSPAgentModelConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://myproxy.azurewebsites.net/openai")),
            apiKey: "test-key",
            model: "test-model",
            providerName: "Example"
        )

        XCTAssertFalse(genericConfiguration.supportsRemoteCompaction)
        XCTAssertFalse(azureWebsiteProxyConfiguration.supportsRemoteCompaction)
    }

    func testPendingTextDeltaUsesOutputItemPhaseWhenPhaseArrivesLater() async throws {
        let client = try Self.client(stream: """
        data: {"type":"response.output_text.delta","item_id":"msg_pending","output_index":0,"delta":"hello "}

        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_pending","role":"assistant","phase":"final_answer","content":[]}}

        data: {"type":"response.output_text.delta","item_id":"msg_pending","output_index":0,"delta":"world"}

        data: {"type":"response.completed","response":{"id":"resp_pending","output":[{"type":"message","id":"msg_pending","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"hello world"}]}]}}

        data: [DONE]

        """)
        let deltas = RecordedStreamingDeltas()

        let output = try await client.nextTurn(
            request: Self.emptyRequest,
            onDelta: { delta in await deltas.append(delta) },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        let recorded = await deltas.all()
        XCTAssertEqual(recorded.map(\.text), ["hello ", "world"])
        XCTAssertEqual(recorded.map(\.phase), [.finalAnswer, .finalAnswer])
        XCTAssertEqual(output.finalAnswer, "hello world")
        XCTAssertEqual(output.responseID, "resp_pending")
    }

    func testFunctionCallArgumentsDeltaMergesBeforeOutputItemDone() async throws {
        let client = try Self.client(stream: """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_delta","call_id":"call_delta","name":"exec_command"}}

        data: {"type":"response.function_call_arguments.delta","item_id":"fc_delta","output_index":0,"delta":"{\\"cmd\\":\\""}

        data: {"type":"response.function_call_arguments.delta","item_id":"fc_delta","output_index":0,"delta":"pwd\\"}"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_delta","call_id":"call_delta","name":"exec_command"}}

        data: {"type":"response.completed","response":{"id":"resp_call","output":[{"type":"function_call","id":"fc_delta","call_id":"call_delta","name":"exec_command"}]}}

        data: [DONE]

        """)
        let preparedTools = RecordedPreparedTools()

        let output = try await client.nextTurn(
            request: Self.emptyRequest,
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { toolName in await preparedTools.append(toolName) }
        )

        let prepared = await preparedTools.all()
        XCTAssertEqual(prepared, [.execCommand])
        XCTAssertEqual(output.toolCalls.count, 1)
        let call = try XCTUnwrap(output.toolCalls.first)
        XCTAssertEqual(call.id, "call_delta")
        XCTAssertEqual(call.name, .execCommand)
        XCTAssertEqual(call.arguments["cmd"]?.stringValue, "pwd")
        XCTAssertEqual(output.responseID, "resp_call")
    }

    func testCustomApplyPatchToolCallParsesRawInputFromOutputItemDone() async throws {
        let patch = """
        *** Begin Patch
        *** Add File: notes.txt
        +hello
        *** End Patch
        """
        let client = try Self.client(stream: """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"custom_tool_call","id":"ctc_patch","call_id":"call_patch","name":"apply_patch","input":\(Self.jsonStringLiteral(patch))}}

        data: {"type":"response.completed","response":{"id":"resp_patch","output":[{"type":"custom_tool_call","id":"ctc_patch","call_id":"call_patch","name":"apply_patch","input":\(Self.jsonStringLiteral(patch))}]}}

        data: [DONE]

        """)
        let preparedTools = RecordedPreparedTools()

        let output = try await client.nextTurn(
            request: Self.emptyRequest,
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { toolName in await preparedTools.append(toolName) }
        )

        let prepared = await preparedTools.all()
        XCTAssertEqual(prepared, [.applyPatch])
        let call = try XCTUnwrap(output.toolCalls.first)
        XCTAssertEqual(call.id, "call_patch")
        XCTAssertEqual(call.name, .applyPatch)
        XCTAssertEqual(call.kind, .custom)
        XCTAssertEqual(call.input, patch)
        XCTAssertEqual(call.arguments, [:])
        XCTAssertEqual(output.responseID, "resp_patch")
    }

    func testCustomApplyPatchInputDeltaMergesAndDoesNotEmitVisibleText() async throws {
        let first = "*** Begin Patch\n*** Add File: delta.txt\n"
        let second = "+hello\n*** End Patch"
        let client = try Self.client(stream: """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"custom_tool_call","id":"ctc_delta","call_id":"call_delta","name":"apply_patch","input":""}}

        data: {"type":"response.custom_tool_call_input.delta","item_id":"ctc_delta","call_id":"call_delta","output_index":0,"delta":\(Self.jsonStringLiteral(first))}

        data: {"type":"response.custom_tool_call_input.delta","item_id":"ctc_delta","call_id":"call_delta","output_index":0,"delta":\(Self.jsonStringLiteral(second))}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"custom_tool_call","id":"ctc_delta","call_id":"call_delta","name":"apply_patch"}}

        data: {"type":"response.completed","response":{"id":"resp_delta","output":[{"type":"custom_tool_call","id":"ctc_delta","call_id":"call_delta","name":"apply_patch"}]}}

        data: [DONE]

        """)
        let deltas = RecordedStreamingDeltas()

        let output = try await client.nextTurn(
            request: Self.emptyRequest,
            onDelta: { delta in await deltas.append(delta) },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        let recordedDeltas = await deltas.all()
        XCTAssertEqual(recordedDeltas, [])
        let call = try XCTUnwrap(output.toolCalls.first)
        XCTAssertEqual(call.kind, .custom)
        XCTAssertEqual(call.input, first + second)
    }

    func testRequestBodyEndpointHeadersAndNativeInputScrubStayStable() async throws {
        let requests = RecordedHTTPRequests()
        let response = try Self.httpResponse(statusCode: 200)
        let client = MSPResponsesStreamingModelClient(
            configuration: MSPAgentModelConfiguration(
                baseURL: URL(string: "https://example.test/v1")!,
                apiKey: "test-key",
                model: "test-model",
                additionalHTTPHeaders: [
                    "OpenAI-Beta": "responses=v1",
                    " ": "ignored-name",
                    "X-Blank": " "
                ],
                supportsRequestMetadata: true
            ),
            transport: { request in
                await requests.append(request)
                return MSPResponsesHTTPStream(
                    response: response,
                    bytes: Self.byteStream(Self.finalAnswerStream(text: "done"))
                )
            }
        )
        let request = MSPAgentRequestEnvelope(
            payload: [
                "metadata": .object(["client": .string("keep")]),
                "native_input_items": .array([.string("remove")])
            ],
            input: [
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string("hello")
                        ])
                    ])
                ])
            ]
        )

        _ = try await client.nextTurn(
            request: request,
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        let firstRequest = await requests.first()
        let recorded = try XCTUnwrap(firstRequest)
        XCTAssertEqual(recorded.url?.absoluteString, "https://example.test/v1/responses")
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=v1")
        XCTAssertNil(recorded.value(forHTTPHeaderField: "X-Blank"))

        let bodyData = try XCTUnwrap(recorded.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["native_input_items"])
        XCTAssertNotNil(body["input"] as? [[String: Any]])
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["client"] as? String, "keep")
    }

    func testRequestMetadataIsStrippedUnlessProviderOptsIn() async throws {
        let requests = RecordedHTTPRequests()
        let response = try Self.httpResponse(statusCode: 200)
        let client = MSPResponsesStreamingModelClient(
            configuration: MSPAgentModelConfiguration(
                baseURL: URL(string: "https://example.test/v1")!,
                apiKey: "test-key",
                model: "test-model"
            ),
            transport: { request in
                await requests.append(request)
                return MSPResponsesHTTPStream(
                    response: response,
                    bytes: Self.byteStream(Self.finalAnswerStream(text: "done"))
                )
            }
        )
        let request = MSPAgentRequestEnvelope(
            payload: [
                "metadata": .object(["request_kind": .string("compaction")])
            ],
            input: []
        )

        _ = try await client.nextTurn(
            request: request,
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        let maybeRecorded = await requests.first()
        let recorded = try XCTUnwrap(maybeRecorded)
        let bodyData = try XCTUnwrap(recorded.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertNil(body["metadata"])
    }

    func testHTTPErrorBodyUsesProviderErrorMessage() async throws {
        let client = try Self.client(
            stream: #"{"error":{"message":"rate limited"}}"#,
            statusCode: 429
        )

        do {
            _ = try await client.nextTurn(
                request: Self.emptyRequest,
                onDelta: { _ in },
                onAssistantMessage: { _ in },
                onToolCallPreparing: { _ in }
            )
            XCTFail("Expected HTTP status error")
        } catch let MSPAgentModelClientError.httpStatus(status, message) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(message, "rate limited")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPErrorBodyContextLengthExceededThrowsTypedError() async throws {
        let client = try Self.client(
            stream: #"{"error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}}"#,
            statusCode: 413
        )

        do {
            _ = try await client.nextTurn(
                request: Self.emptyRequest,
                onDelta: { _ in },
                onAssistantMessage: { _ in },
                onToolCallPreparing: { _ in }
            )
            XCTFail("Expected context window error")
        } catch let MSPAgentModelClientError.contextWindowExceeded(message) {
            XCTAssertEqual(message, "Your input exceeds the context window of this model.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResponseFailedContextLengthExceededThrowsTypedError() async throws {
        let client = try Self.client(stream: """
        data: {"type":"response.failed","response":{"id":"resp_context_limit","status":"failed","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}}}

        data: [DONE]

        """)

        do {
            _ = try await client.nextTurn(
                request: Self.emptyRequest,
                onDelta: { _ in },
                onAssistantMessage: { _ in },
                onToolCallPreparing: { _ in }
            )
            XCTFail("Expected context window error")
        } catch let MSPAgentModelClientError.contextWindowExceeded(message) {
            XCTAssertEqual(message, "Your input exceeds the context window of this model.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStandaloneJSONMultilineSSEAndTokenUsageAreParsed() async throws {
        let client = try Self.client(stream: """
        {"type":"response.output_text.delta","output_index":0,"phase":"final_answer","delta":"draft "}
        data: {"type":"response.completed",
        data: "response":{"id":"resp_multiline","output":[{"type":"message","id":"msg_multiline","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"done"}]}],"usage":{"inputTokens":10,"inputTokensDetails":{"cachedTokens":4},"completion_tokens":3,"totalTokens":13}}}

        data: [DONE]

        """)
        let deltas = RecordedStreamingDeltas()

        let output = try await client.nextTurn(
            request: Self.emptyRequest,
            onDelta: { delta in await deltas.append(delta) },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        let recorded = await deltas.all()
        XCTAssertEqual(recorded.map(\.text), ["draft "])
        XCTAssertEqual(recorded.map(\.phase), [.finalAnswer])
        XCTAssertEqual(output.finalAnswer, "done")
        XCTAssertEqual(output.responseID, "resp_multiline")
        XCTAssertEqual(output.tokenUsage?.inputTokens, 10)
        XCTAssertEqual(output.tokenUsage?.cachedInputTokens, 4)
        XCTAssertEqual(output.tokenUsage?.outputTokens, 3)
        XCTAssertEqual(output.tokenUsage?.totalTokens, 13)
    }

    func testCompletedResponseTextFallbackIsUsedWhenNoOutputItemsArrive() async throws {
        let client = try Self.client(stream: """
        data: {"type":"response.completed","response":{"id":"resp_fallback","output_text":["fallback ","answer"]}}

        data: [DONE]

        """)

        let output = try await client.nextTurn(
            request: Self.emptyRequest,
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        XCTAssertEqual(output.finalAnswer, "fallback answer")
        XCTAssertEqual(output.responseID, "resp_fallback")
    }

    private static var emptyRequest: MSPAgentRequestEnvelope {
        MSPAgentRequestEnvelope(payload: [:], input: [])
    }

    private static func client(
        stream: String,
        statusCode: Int = 200
    ) throws -> MSPResponsesStreamingModelClient {
        let response = try httpResponse(statusCode: statusCode)
        return MSPResponsesStreamingModelClient(
            configuration: MSPAgentModelConfiguration(
                baseURL: URL(string: "https://example.test/v1")!,
                apiKey: "test-key",
                model: "test-model"
            ),
            transport: { _ in
                MSPResponsesHTTPStream(
                    response: response,
                    bytes: Self.byteStream(stream)
                )
            }
        )
    }

    private static func httpResponse(statusCode: Int) throws -> HTTPURLResponse {
        let endpoint = try XCTUnwrap(URL(string: "https://example.test/v1/responses"))
        return try XCTUnwrap(
            HTTPURLResponse(
                url: endpoint,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )
        )
    }

    private static func finalAnswerStream(text: String) -> String {
        """
        data: {"type":"response.completed","response":{"id":"resp_done","output":[{"type":"message","id":"msg_done","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\(text)"}]}]}}

        data: [DONE]

        """
    }

    private static func byteStream(_ text: String) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in text.utf8 {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private static func jsonStringLiteral(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(data: data, encoding: .utf8)!
    }
}

private actor RecordedHTTPRequests {
    private var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        values.append(request)
    }

    func first() -> URLRequest? {
        values.first
    }
}

private actor RecordedStreamingDeltas {
    private var values: [MSPAgentModelStreamDelta] = []

    func append(_ delta: MSPAgentModelStreamDelta) {
        values.append(delta)
    }

    func all() -> [MSPAgentModelStreamDelta] {
        values
    }
}

private actor RecordedPreparedTools {
    private var values: [MSPAgentToolName] = []

    func append(_ name: MSPAgentToolName) {
        values.append(name)
    }

    func all() -> [MSPAgentToolName] {
        values
    }
}
