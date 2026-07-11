import Foundation

public enum MSPResponsesModelsEndpointError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)
    case invalidPayload
}

/// Fetches the provider model catalog from `GET base/models`.
public final class MSPResponsesModelsEndpoint: MSPModelCatalogRemoteFetching, @unchecked Sendable {
    public struct Configuration: Hashable, Sendable {
        public var baseURL: URL
        public var clientVersion: String
        public var bearerToken: String?
        public var additionalHeaders: [String: String]
        public var providerID: String
        public var accountID: String?
        public var credentialScopeID: String?
        public var usesChatGPTAuthentication: Bool
        public var timeoutInterval: TimeInterval

        public init(
            baseURL: URL,
            clientVersion: String = MSPModelCatalogClientVersion.current,
            bearerToken: String? = nil,
            additionalHeaders: [String: String] = [:],
            providerID: String = "openai",
            accountID: String? = nil,
            credentialScopeID: String? = nil,
            usesChatGPTAuthentication: Bool = false,
            timeoutInterval: TimeInterval = 5
        ) {
            self.baseURL = baseURL
            self.clientVersion = clientVersion
            self.bearerToken = bearerToken
            self.additionalHeaders = additionalHeaders
            self.providerID = providerID
            self.accountID = accountID
            self.credentialScopeID = credentialScopeID
            self.usesChatGPTAuthentication = usesChatGPTAuthentication
            self.timeoutInterval = timeoutInterval
        }

        public func request(ifNoneMatch: String? = nil) -> MSPModelCatalogRemoteRequest {
            MSPModelCatalogRemoteRequest(
                baseURL: baseURL,
                clientVersion: clientVersion,
                bearerToken: bearerToken,
                additionalHeaders: additionalHeaders,
                ifNoneMatch: ifNoneMatch,
                includesClientVersionQuery: true,
                timeoutInterval: timeoutInterval
            )
        }
    }

    public let configuration: Configuration
    private let session: URLSession

    public init(
        configuration: Configuration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func fetchModels(
        request: MSPModelCatalogRemoteRequest
    ) async throws -> MSPModelCatalogRemoteResponse {
        let url = try Self.modelsURL(
            baseURL: request.baseURL,
            clientVersion: request.includesClientVersionQuery ? request.clientVersion : nil
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = request.timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken = request.bearerToken?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !bearerToken.isEmpty {
            urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in request.additionalHeaders {
            let headerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headerName.isEmpty, !headerValue.isEmpty {
                urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
            }
        }
        if let ifNoneMatch = request.ifNoneMatch, !ifNoneMatch.isEmpty {
            urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MSPResponsesModelsEndpointError.invalidResponse
        }
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        if httpResponse.statusCode == 304 {
            return MSPModelCatalogRemoteResponse(
                models: [],
                etag: etag ?? request.ifNoneMatch,
                notModified: true
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(4_096), encoding: .utf8) ?? ""
            throw MSPResponsesModelsEndpointError.httpStatus(httpResponse.statusCode, body)
        }

        let payload = try JSONDecoder().decode(ModelsPayload.self, from: data)
        guard let models = payload.models ?? payload.data else {
            throw MSPResponsesModelsEndpointError.invalidPayload
        }
        return MSPModelCatalogRemoteResponse(models: models, etag: etag)
    }

    public func fetchModels(ifNoneMatch: String? = nil) async throws
        -> MSPModelCatalogRemoteResponse
    {
        try await fetchModels(request: configuration.request(ifNoneMatch: ifNoneMatch))
    }

    private struct ModelsPayload: Decodable {
        var models: [MSPModelCapabilities]?
        var data: [MSPModelCapabilities]?
    }

    static func modelsURL(baseURL: URL, clientVersion: String?) throws -> URL {
        var catalogBaseURL = baseURL
        if catalogBaseURL.lastPathComponent.caseInsensitiveCompare("responses") == .orderedSame {
            catalogBaseURL.deleteLastPathComponent()
        }
        let endpointURL: URL
        if catalogBaseURL.lastPathComponent.caseInsensitiveCompare("models") == .orderedSame {
            endpointURL = catalogBaseURL
        } else {
            endpointURL = catalogBaseURL.appendingPathComponent("models")
        }
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw MSPResponsesModelsEndpointError.invalidURL
        }
        if let clientVersion {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "client_version" }
            queryItems.append(URLQueryItem(name: "client_version", value: clientVersion))
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MSPResponsesModelsEndpointError.invalidURL
        }
        return url
    }
}
