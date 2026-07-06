import Foundation

extension MSPResponsesStreamingModelClient: MSPAgentRemoteCompactionClient {
    var supportsRemoteCompaction: Bool {
        configuration.supportsRemoteCompaction
    }

    var supportsRequestMetadata: Bool {
        configuration.supportsRequestMetadata
    }

    func compactConversation(
        payload: MSPRemoteCompactPayload
    ) async throws -> [MSPAgentJSONValue] {
        var body = payload.body
        if !configuration.supportsRequestMetadata {
            body.removeValue(forKey: "metadata")
        }
        var request = try makeURLRequest(
            url: compactEndpointURL(),
            accept: "application/json"
        )
        request.timeoutInterval *= Double(max(1, payload.timeoutIdleMultiplier))
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body.mapValues(\.jsonObject),
            options: []
        )

        let stream = try await transport(request)
        try await validate(response: stream.response, bytes: stream.bytes)
        let data = try await collectResponseData(stream.bytes)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let output = Self.compactOutputArray(from: object) else {
            let message = Self.responseErrorMessage(from: object)
                ?? String((String(data: data, encoding: .utf8) ?? "").prefix(220))
            throw MSPAgentModelClientError.invalidStreamPayload(message)
        }
        return try output.map(MSPAgentJSONValue.init(jsonObject:))
    }

    private func collectResponseData(
        _ bytes: AsyncThrowingStream<UInt8, Error>
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private static func compactOutputArray(from object: Any) -> [Any]? {
        if let output = object as? [Any] {
            return output
        }
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary["output"] as? [Any]
    }
}
