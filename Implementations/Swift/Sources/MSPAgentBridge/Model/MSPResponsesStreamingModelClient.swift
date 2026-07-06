import Foundation

public final class MSPResponsesStreamingModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    public typealias HTTPTransport = @Sendable (URLRequest) async throws -> MSPResponsesHTTPStream

    let configuration: MSPAgentModelConfiguration
    let transport: HTTPTransport

    public init(
        configuration: MSPAgentModelConfiguration,
        transport: @escaping HTTPTransport = MSPResponsesStreamingModelClient.urlSessionTransport
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        var payload = request.payload.mapValues(\.jsonObject)
        payload["input"] = request.input.map(\.jsonObject)
        payload["stream"] = true
        payload["model"] = configuration.model
        payload.removeValue(forKey: "native_input_items")
        if !configuration.supportsRequestMetadata {
            payload.removeValue(forKey: "metadata")
        }

        var urlRequest = try makeURLRequest()
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let stream = try await transport(urlRequest)
        try await validate(response: stream.response, bytes: stream.bytes)

        return try await readEventStream(
            bytes: stream.bytes,
            onDelta: onDelta,
            onAssistantMessage: onAssistantMessage,
            onToolCallPreparing: onToolCallPreparing
        )
    }
}
