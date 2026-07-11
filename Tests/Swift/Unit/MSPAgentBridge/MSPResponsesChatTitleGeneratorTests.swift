import Foundation
import MSPAgentBridge
import XCTest

final class MSPResponsesChatTitleGeneratorTests: XCTestCase {
    func testNamingConfigurationConvenienceInitializerUsesDedicatedModelAndTimeout() {
        let namingConfiguration = MSPChatNamingConfiguration(
            model: "cheap-title-model",
            timeoutNanoseconds: 2_500_000_000
        )

        let generator = MSPResponsesChatTitleGenerator(
            modelConfiguration: Self.modelConfiguration(model: "main-chat-model"),
            namingConfiguration: namingConfiguration
        )

        XCTAssertEqual(generator.modelConfiguration.model, "cheap-title-model")
        XCTAssertEqual(generator.timeoutInterval, 2.5, accuracy: 0.001)
    }

    func testTitleGenerationUsesSelectedModelAndToolFreeStructuredRequest() async throws {
        let recorder = ChatNamingRequestRecorder()
        let generator = try Self.generator(
            timeoutInterval: 12.5,
            recorder: recorder,
            structuredText: #"{"title":"查自动标题","description":"MSP Codex 自动标题机制"}"#,
            configuredModel: "configured-model"
        )

        let suggestion = try await generator.generateTitle(
            request: Self.titleRequest(model: "developer-selected-title-model")
        )

        XCTAssertEqual(suggestion.title, "查自动标题")
        XCTAssertEqual(suggestion.searchDescription, "MSP Codex 自动标题机制")

        let firstRequest = await recorder.first()
        let captured = try XCTUnwrap(firstRequest)
        XCTAssertEqual(captured.url?.absoluteString, "https://example.test/v1/responses")
        XCTAssertEqual(captured.timeoutInterval, 12.5, accuracy: 0.001)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-MSP-Test"), "chat-naming")

        let body = try Self.jsonBody(of: captured)
        XCTAssertEqual(body["model"] as? String, "developer-selected-title-model")
        XCTAssertNil(body["instructions"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["tool_choice"] as? String, "none")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual((body["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(
            (body["reasoning"] as? [String: Any])?["effort"] as? String,
            "low"
        )

        let text = try XCTUnwrap(body["text"] as? [String: Any])
        XCTAssertEqual(text["verbosity"] as? String, "low")
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "msp_chat_title")
        XCTAssertEqual(format["strict"] as? Bool, true)

        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            Set(try XCTUnwrap(schema["required"] as? [String])),
            Set(["title", "description"])
        )
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let titleProperty = try XCTUnwrap(properties["title"] as? [String: Any])
        let descriptionProperty = try XCTUnwrap(
            properties["description"] as? [String: Any]
        )
        XCTAssertEqual(titleProperty["type"] as? String, "string")
        XCTAssertEqual(descriptionProperty["type"] as? String, "string")
        XCTAssertEqual(titleProperty["minLength"] as? Int, 1)
        XCTAssertEqual(titleProperty["maxLength"] as? Int, 36)
        XCTAssertEqual(descriptionProperty["minLength"] as? Int, 1)
        XCTAssertNil(descriptionProperty["maxLength"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(
            content[0]["text"] as? String,
            "Generate Chat metadata.\n请调查 Codex 自动标题"
        )
    }

    func testTitleOutputIsNormalizedAndBoundedByCharacterLimits() async throws {
        let generator = try Self.generator(
            structuredText: #"{"title":"  \"Title: Fix   sync\nrace!!!\"  ","description":" one   two\nthree four "}"#
        )
        let suggestion = try await generator.generateTitle(
            request: MSPChatTitleGenerationRequest(
                chatID: "chat-normalize",
                prompt: "Fix the sync race",
                instructions: "Generate Chat metadata.",
                model: nil,
                titleMaximumCharacters: 12,
                descriptionMaximumCharacters: 12,
                source: .developerRequested
            )
        )

        XCTAssertEqual(suggestion.title, "Title: Fix…")
        XCTAssertLessThanOrEqual(suggestion.title.count, 12)
        XCTAssertEqual(suggestion.searchDescription, "one two thre")
        XCTAssertEqual(suggestion.searchDescription?.count, 12)
    }

    func testStrictParserRejectsFieldsOutsideSchema() async throws {
        let generator = try Self.generator(
            structuredText: #"{"title":"Fix sync","description":"Search sync","extra":true}"#
        )

        do {
            _ = try await generator.generateTitle(request: Self.titleRequest())
            XCTFail("Expected strict structured-output validation to fail.")
        } catch let error as MSPResponsesChatTitleGeneratorError {
            guard case .invalidStructuredOutput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSearchDescriptionRefreshUsesConfiguredModelAndDedicatedSchema() async throws {
        let recorder = ChatNamingRequestRecorder()
        let generator = try Self.generator(
            recorder: recorder,
            structuredText: #"{"description":" Codex   自动标题\n搜索摘要 "}"#,
            configuredModel: "description-model"
        )

        let description = try await generator.generateSearchDescription(
            request: MSPChatSearchDescriptionGenerationRequest(
                chatID: "chat-description",
                title: "查 Codex 自动标题",
                prompt: "",
                instructions: "Generate a structured search description.",
                model: nil,
                descriptionMaximumCharacters: 100,
                source: .manualTitleChange
            )
        )

        XCTAssertEqual(description, "Codex 自动标题 搜索摘要")
        let firstRequest = await recorder.first()
        let captured = try XCTUnwrap(firstRequest)
        let body = try Self.jsonBody(of: captured)
        XCTAssertEqual(body["model"] as? String, "description-model")
        XCTAssertEqual(
            body["instructions"] as? String,
            "Generate a structured search description."
        )
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(prompt.contains("Current title: 查 Codex 自动标题"))

        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["name"] as? String, "msp_chat_search_description")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["description"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(properties.count, 1)
    }

    func testTimeoutCancelsGenerationWithCanonicalChatNamingError() async throws {
        let response = try Self.httpResponse()
        let generator = MSPResponsesChatTitleGenerator(
            modelConfiguration: Self.modelConfiguration(model: "slow-model"),
            timeoutInterval: 0.01,
            transport: { _ in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        continuation.resume(returning: MSPResponsesHTTPStream(
                            response: response,
                            bytes: Self.byteStream("")
                        ))
                    }
                }
            }
        )
        let startedAt = Date()

        do {
            _ = try await generator.generateTitle(request: Self.titleRequest())
            XCTFail("Expected title generation to time out.")
        } catch let error as MSPChatNamingError {
            XCTAssertEqual(error, .generationTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.15)
    }

    func testCallerCancellationPropagatesWithoutBecomingTimeout() async throws {
        let response = try Self.httpResponse()
        let generator = MSPResponsesChatTitleGenerator(
            modelConfiguration: Self.modelConfiguration(model: "slow-model"),
            timeoutInterval: 30,
            transport: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return MSPResponsesHTTPStream(
                    response: response,
                    bytes: Self.byteStream("")
                )
            }
        )
        let task = Task {
            try await generator.generateTitle(request: Self.titleRequest())
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected caller cancellation.")
        } catch is CancellationError {
            // Expected: cancellation remains distinguishable from timeout.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }
}

private extension MSPResponsesChatTitleGeneratorTests {
    static func generator(
        timeoutInterval: TimeInterval = 30,
        recorder: ChatNamingRequestRecorder? = nil,
        structuredText: String,
        configuredModel: String = "configured-model"
    ) throws -> MSPResponsesChatTitleGenerator {
        let response = try httpResponse()
        let stream = completedStream(text: structuredText)
        return MSPResponsesChatTitleGenerator(
            modelConfiguration: modelConfiguration(model: configuredModel),
            timeoutInterval: timeoutInterval,
            transport: { request in
                if let recorder {
                    await recorder.append(request)
                }
                return MSPResponsesHTTPStream(
                    response: response,
                    bytes: byteStream(stream)
                )
            }
        )
    }

    static func titleRequest(model: String? = nil) -> MSPChatTitleGenerationRequest {
        MSPChatTitleGenerationRequest(
            chatID: "chat-title",
            prompt: "请调查 Codex 自动标题",
            instructions: "Generate Chat metadata.",
            model: model,
            titleMaximumCharacters: 36,
            descriptionMaximumCharacters: 100,
            source: .initialUserInput
        )
    }

    static func modelConfiguration(model: String) -> MSPAgentModelConfiguration {
        MSPAgentModelConfiguration(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test-key",
            model: model,
            additionalHTTPHeaders: ["X-MSP-Test": "chat-naming"]
        )
    }

    static func jsonBody(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    static func httpResponse() throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: "https://example.test/v1/responses"))
        return try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )
        )
    }

    static func completedStream(text: String) -> String {
        let event: [String: Any] = [
            "type": "response.completed",
            "response": [
                "id": "response-chat-naming",
                "output": [[
                    "type": "message",
                    "id": "message-chat-naming",
                    "role": "assistant",
                    "phase": "final_answer",
                    "content": [[
                        "type": "output_text",
                        "text": text
                    ]]
                ]]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: event)
        let json = String(data: data, encoding: .utf8)!
        return "data: \(json)\n\ndata: [DONE]\n\n"
    }

    static func byteStream(_ text: String) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in text.utf8 {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}

private actor ChatNamingRequestRecorder {
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        requests.append(request)
    }

    func first() -> URLRequest? {
        requests.first
    }
}
