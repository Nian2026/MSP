import Foundation

public struct MSPResponsesHTTPStream {
    public var response: URLResponse
    public var bytes: AsyncThrowingStream<UInt8, Error>

    public init(response: URLResponse, bytes: AsyncThrowingStream<UInt8, Error>) {
        self.response = response
        self.bytes = bytes
    }
}

extension MSPResponsesStreamingModelClient {
    public static let urlSessionTransport: HTTPTransport = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        return MSPResponsesHTTPStream(
            response: response,
            bytes: AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await byte in bytes {
                            continuation.yield(byte)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        )
    }

    func makeURLRequest(
        url overrideURL: URL? = nil,
        accept: String = "text/event-stream"
    ) throws -> URLRequest {
        guard let endpointURL = overrideURL ?? endpointURL() else {
            throw MSPAgentModelClientError.invalidBaseURL
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        for (name, value) in configuration.additionalHTTPHeaders
        where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func endpointURL() -> URL? {
        let absolute = configuration.baseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !absolute.isEmpty else {
            return nil
        }
        if absolute.hasSuffix("/responses") || absolute.hasSuffix("/responses/") {
            return configuration.baseURL
        }
        return configuration.baseURL.appendingPathComponent("responses")
    }

    func compactEndpointURL() -> URL? {
        endpointURL()?.appendingPathComponent("compact")
    }

    func validate(
        response: URLResponse,
        bytes: AsyncThrowingStream<UInt8, Error>
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MSPAgentModelClientError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4096 {
                    break
                }
            }
            let message = Self.httpTransportErrorMessage(from: data)
            if let object = try? JSONSerialization.jsonObject(with: data),
               let json = object as? [String: Any],
               let contextMessage = Self.contextWindowExceededMessage(from: json) {
                throw MSPAgentModelClientError.contextWindowExceeded(contextMessage)
            }
            if MSPAgentModelClientError.isLikelyContextWindowExceededMessage(message) {
                throw MSPAgentModelClientError.contextWindowExceeded(message)
            }
            throw MSPAgentModelClientError.httpStatus(httpResponse.statusCode, message)
        }
    }

    private static func httpTransportErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = httpTransportResponseErrorMessage(from: object) else {
            return String((String(data: data, encoding: .utf8) ?? "").prefix(220))
        }
        return message
    }

    private static func httpTransportResponseErrorMessage(from object: Any?) -> String? {
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        if let message = httpTransportStringValue(at: ["error", "message"], in: dictionary) {
            return message
        }
        if let message = httpTransportStringValue(at: ["message"], in: dictionary),
           !(dictionary["type"] as? String == "response.completed") {
            return message
        }
        if let nested = dictionary["error"] {
            return httpTransportResponseErrorMessage(from: nested)
        }
        return nil
    }

    private static func httpTransportStringValue(at path: [String], in dictionary: [String: Any]) -> String? {
        var current: Any? = dictionary
        for key in path {
            guard let object = current as? [String: Any] else {
                return nil
            }
            current = object[key]
        }
        guard let string = current as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
