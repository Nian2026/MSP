import Foundation

/// A lightweight Responses API generator for Chat metadata.
///
/// The generator owns a separate model request and never enters an
/// ``MSPAgentConversation`` turn, so title generation cannot append messages or
/// tool calls to the canonical Chat transcript. Developers can reuse their main
/// model configuration or pass a cheaper model configuration dedicated to Chat
/// naming.
public struct MSPResponsesChatTitleGenerator: Sendable,
    MSPChatTitleGenerating,
    MSPChatSearchDescriptionGenerating
{
    public typealias HTTPTransport = MSPResponsesStreamingModelClient.HTTPTransport

    public let modelConfiguration: MSPAgentModelConfiguration
    public let timeoutInterval: TimeInterval

    private let transport: HTTPTransport

    public init(
        modelConfiguration: MSPAgentModelConfiguration,
        timeoutInterval: TimeInterval = 30,
        transport: @escaping HTTPTransport = MSPResponsesChatTitleGenerator.urlSessionTransport
    ) {
        self.modelConfiguration = modelConfiguration
        self.timeoutInterval = timeoutInterval
        self.transport = transport
    }

    /// Convenience initializer for hosts that keep the coordinator and model
    /// generator on the same model selection and naming timeout.
    public init(
        modelConfiguration: MSPAgentModelConfiguration,
        namingConfiguration: MSPChatNamingConfiguration,
        transport: @escaping HTTPTransport = MSPResponsesChatTitleGenerator.urlSessionTransport
    ) {
        var effectiveModelConfiguration = modelConfiguration
        if let selectedModel = namingConfiguration.model?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedModel.isEmpty {
            effectiveModelConfiguration.model = selectedModel
        }
        self.init(
            modelConfiguration: effectiveModelConfiguration,
            timeoutInterval: TimeInterval(namingConfiguration.timeoutNanoseconds)
                / 1_000_000_000,
            transport: transport
        )
    }

    /// The default transport keeps the streaming producer tied to the request
    /// consumer. Cancelling or timing out a naming request therefore cancels
    /// the underlying URLSession byte task as well.
    public static let urlSessionTransport: HTTPTransport = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        return MSPResponsesHTTPStream(
            response: response,
            bytes: AsyncThrowingStream { continuation in
                let producer = Task {
                    do {
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            continuation.yield(byte)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    producer.cancel()
                }
            }
        )
    }

    public func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        try Self.validateRequest(
            prompt: request.prompt,
            instructions: request.instructions,
            maximums: [
                ("title", request.titleMaximumCharacters),
                ("search description", request.descriptionMaximumCharacters)
            ]
        )

        let text = try await performStructuredRequest(
            modelOverride: request.model,
            instructions: nil,
            prompt: Self.titleUserPrompt(
                instructions: request.instructions,
                prompt: request.prompt
            ),
            format: Self.titleFormat(
                titleMaximumCharacters: request.titleMaximumCharacters
            )
        )
        return try Self.parseTitleSuggestion(
            text,
            titleMaximumCharacters: request.titleMaximumCharacters,
            descriptionMaximumCharacters: request.descriptionMaximumCharacters
        )
    }

    public func generateSearchDescription(
        request: MSPChatSearchDescriptionGenerationRequest
    ) async throws -> String? {
        try Self.validateRequest(
            prompt: request.prompt,
            instructions: request.instructions,
            permitsEmptyPrompt: true,
            maximums: [("search description", request.descriptionMaximumCharacters)]
        )

        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MSPResponsesChatTitleGeneratorError.invalidRequest("Chat title must not be empty.")
        }

        let text = try await performStructuredRequest(
            modelOverride: request.model,
            instructions: request.instructions,
            prompt: Self.searchDescriptionPrompt(title: title, chatPrompt: request.prompt),
            format: Self.searchDescriptionFormat()
        )
        return try Self.parseSearchDescription(
            text,
            maximumCharacters: request.descriptionMaximumCharacters
        )
    }
}

public enum MSPResponsesChatTitleGeneratorError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case incompleteResponse
    case unexpectedToolCall
    case invalidStructuredOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .invalidRequest(message):
            return message
        case .incompleteResponse:
            return "The model did not complete the Chat metadata response."
        case .unexpectedToolCall:
            return "The Chat metadata model unexpectedly requested a tool."
        case let .invalidStructuredOutput(message):
            return "The model returned invalid Chat metadata: \(message)"
        }
    }
}

private extension MSPResponsesChatTitleGenerator {
    func performStructuredRequest(
        modelOverride: String?,
        instructions: String?,
        prompt: String,
        format: MSPAgentJSONValue
    ) async throws -> String {
        try Task.checkCancellation()

        let nanoseconds = try timeoutNanoseconds()
        return try await withChatMetadataTimeout(nanoseconds: nanoseconds) {
            try await performModelRequest(
                modelOverride: modelOverride,
                instructions: instructions,
                prompt: prompt,
                format: format
            )
        }
    }

    func performModelRequest(
        modelOverride: String?,
        instructions: String?,
        prompt: String,
        format: MSPAgentJSONValue
    ) async throws -> String {
        let model = Self.resolvedModel(
            override: modelOverride,
            configured: modelConfiguration.model
        )
        guard !model.isEmpty else {
            throw MSPResponsesChatTitleGeneratorError.invalidConfiguration(
                "Chat metadata generation requires a non-empty model identifier."
            )
        }

        var effectiveConfiguration = modelConfiguration
        effectiveConfiguration.model = model

        let requestTimeout = timeoutInterval
        let underlyingTransport = transport
        let timeoutAwareTransport: HTTPTransport = { request in
            var request = request
            request.timeoutInterval = requestTimeout
            return try await underlyingTransport(request)
        }
        let client = MSPResponsesStreamingModelClient(
            configuration: effectiveConfiguration,
            transport: timeoutAwareTransport
        )
        let output = try await client.nextTurn(
            request: Self.envelope(
                instructions: instructions,
                prompt: prompt,
                format: format
            ),
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )

        try Task.checkCancellation()
        guard output.toolCalls.isEmpty else {
            throw MSPResponsesChatTitleGeneratorError.unexpectedToolCall
        }
        guard output.sawCompleted else {
            throw MSPResponsesChatTitleGeneratorError.incompleteResponse
        }
        guard let text = output.finalAnswer?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "the structured response was empty."
            )
        }
        return text
    }

    func timeoutNanoseconds() throws -> UInt64 {
        guard timeoutInterval.isFinite, timeoutInterval > 0 else {
            throw MSPResponsesChatTitleGeneratorError.invalidConfiguration(
                "Chat metadata generation timeout must be greater than zero."
            )
        }
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        guard timeoutInterval <= maximumSeconds else {
            throw MSPResponsesChatTitleGeneratorError.invalidConfiguration(
                "Chat metadata generation timeout is too large."
            )
        }
        return max(1, UInt64(timeoutInterval * 1_000_000_000))
    }

    static func validateRequest(
        prompt: String,
        instructions: String,
        permitsEmptyPrompt: Bool = false,
        maximums: [(String, Int)]
    ) throws {
        guard permitsEmptyPrompt
            || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MSPResponsesChatTitleGeneratorError.invalidRequest(
                "Chat metadata generation prompt must not be empty."
            )
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MSPResponsesChatTitleGeneratorError.invalidRequest(
                "Chat metadata generation instructions must not be empty."
            )
        }
        for (label, maximum) in maximums where maximum <= 0 {
            throw MSPResponsesChatTitleGeneratorError.invalidRequest(
                "Maximum \(label) length must be greater than zero."
            )
        }
    }

    static func resolvedModel(override: String?, configured: String) -> String {
        let override = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return override
        }
        return configured.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func envelope(
        instructions: String?,
        prompt: String,
        format: MSPAgentJSONValue
    ) -> MSPAgentRequestEnvelope {
        var payload: [String: MSPAgentJSONValue] = [
            "tools": .array([]),
            "tool_choice": .string("none"),
            "parallel_tool_calls": .bool(false),
            "reasoning": .object(["effort": .string("low")]),
            "store": .bool(false),
            "stream": .bool(true),
            "text": .object([
                "verbosity": .string("low"),
                "format": format
            ])
        ]
        if let instructions {
            payload["instructions"] = .string(instructions)
        }
        return MSPAgentRequestEnvelope(
            payload: payload,
            input: [
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(prompt)
                        ])
                    ])
                ])
            ]
        )
    }

    static func titleUserPrompt(
        instructions: String,
        prompt: String
    ) -> String {
        instructions + "\n" + prompt
    }

    static func titleFormat(
        titleMaximumCharacters: Int
    ) -> MSPAgentJSONValue {
        jsonSchemaFormat(
            name: "msp_chat_title",
            properties: [
                "title": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(Double(max(1, titleMaximumCharacters)))
                ]),
                "description": .object([
                    "type": .string("string"),
                    "minLength": .number(1)
                ])
            ],
            required: ["title", "description"]
        )
    }

    static func searchDescriptionFormat() -> MSPAgentJSONValue {
        jsonSchemaFormat(
            name: "msp_chat_search_description",
            properties: [
                "description": .object([
                    "type": .string("string"),
                    "minLength": .number(1)
                ])
            ],
            required: ["description"]
        )
    }

    static func jsonSchemaFormat(
        name: String,
        properties: [String: MSPAgentJSONValue],
        required: [String]
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("json_schema"),
            "name": .string(name),
            "strict": .bool(true),
            "schema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(MSPAgentJSONValue.string)),
                "additionalProperties": .bool(false)
            ])
        ])
    }

    static func searchDescriptionPrompt(title: String, chatPrompt: String) -> String {
        """
        Current title: \(title)

        Persisted user context (most recent user purpose first):
        \(chatPrompt)
        """
    }

    static func parseTitleSuggestion(
        _ text: String,
        titleMaximumCharacters: Int,
        descriptionMaximumCharacters: Int
    ) throws -> MSPChatTitleSuggestion {
        let object = try parseExactObject(
            text,
            expectedKeys: ["title", "description"]
        )
        guard let title = object["title"]?.stringValue else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "title must be a string."
            )
        }
        guard let normalizedTitle = MSPChatNamingTextNormalizer.title(
            title,
            maximumCharacters: titleMaximumCharacters
        ) else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "title must not be empty."
            )
        }
        let searchDescription = try requiredString(
            object["description"],
            label: "description",
            maximumCharacters: descriptionMaximumCharacters
        )
        return MSPChatTitleSuggestion(
            title: normalizedTitle,
            searchDescription: searchDescription
        )
    }

    static func parseSearchDescription(
        _ text: String,
        maximumCharacters: Int
    ) throws -> String? {
        let object = try parseExactObject(
            text,
            expectedKeys: ["description"]
        )
        return try requiredString(
            object["description"],
            label: "description",
            maximumCharacters: maximumCharacters
        )
    }

    static func parseExactObject(
        _ text: String,
        expectedKeys: Set<String>
    ) throws -> [String: MSPAgentJSONValue] {
        let value: MSPAgentJSONValue
        do {
            value = try JSONDecoder().decode(
                MSPAgentJSONValue.self,
                from: Data(text.utf8)
            )
        } catch {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "the response was not a JSON object matching the requested schema."
            )
        }
        guard let object = value.objectValue else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "the top-level value must be an object."
            )
        }
        guard Set(object.keys) == expectedKeys else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "the response fields did not exactly match the requested schema."
            )
        }
        return object
    }

    static func requiredString(
        _ value: MSPAgentJSONValue?,
        label: String,
        maximumCharacters: Int
    ) throws -> String {
        guard let value else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "\(label) was missing."
            )
        }
        guard case let .string(string) = value else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "\(label) must be a string."
            )
        }
        guard let normalized = MSPChatNamingTextNormalizer.description(
            string,
            maximumCharacters: maximumCharacters
        ) else {
            throw MSPResponsesChatTitleGeneratorError.invalidStructuredOutput(
                "\(label) must not be empty."
            )
        }
        return normalized
    }

}

private actor MSPChatMetadataTimeoutResolver<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard !isResolved else {
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

private func withChatMetadataTimeout<Value: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let resolver = MSPChatMetadataTimeoutResolver<Value>()
    let operationTask = Task {
        do {
            await resolver.resolve(.success(try await operation()))
        } catch {
            await resolver.resolve(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            await resolver.resolve(.failure(MSPChatNamingError.generationTimedOut))
        } catch {
            // Another branch completed or the caller canceled the operation.
        }
    }

    defer {
        operationTask.cancel()
        timeoutTask.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await resolver.install(continuation)
            }
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        Task {
            await resolver.resolve(.failure(CancellationError()))
        }
    }
}
