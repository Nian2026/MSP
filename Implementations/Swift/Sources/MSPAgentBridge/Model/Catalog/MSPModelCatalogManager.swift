import CryptoKit
import Foundation

public enum MSPModelCatalogManagerError: Error, Equatable, Sendable {
    case remoteEndpointUnavailable
    case notModifiedWithoutCachedCatalog
}

/// Dynamic model catalog with bundled fallback and provider/account-scoped cache.
///
/// Provenance: refresh, ETag, TTL, bundled overlay, and slug matching behavior
/// follows the Apache-2.0 OpenAI Codex ModelsManager design.
public actor MSPModelCatalogManager: MSPModelCatalogResolving {
    public static let bundledSnapshot = MSPModelCatalogSnapshot(
        models: MSPBundledModelCatalog.models,
        metadataSource: .bundled,
        revision: MSPBundledModelCatalog.revision,
        providerID: "bundled"
    )

    private let providerID: String
    private let accountID: String?
    private let credentialScopeID: String?
    private let clientVersion: String
    private let usesChatGPTAuthentication: Bool
    private let cacheTTL: TimeInterval
    private let cacheFileURL: URL?
    private let bundledModels: [MSPModelCapabilities]
    private let remoteFetcher: (any MSPModelCatalogRemoteFetching)?
    private let baseRemoteRequest: MSPModelCatalogRemoteRequest?

    private var activeSnapshot: MSPModelCatalogSnapshot
    private var lastRemoteModels: [MSPModelCapabilities]?
    private var lastRemoteRefreshFailureAt: Date?
    private var inFlightRemoteRefresh: InFlightRemoteRefresh?

    private struct InFlightRemoteRefresh {
        var id: UUID
        var task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<MSPModelCatalogSnapshot, Error>]
    }

    public init(
        providerID: String,
        accountID: String? = nil,
        credentialScopeID: String? = nil,
        clientVersion: String = MSPModelCatalogClientVersion.current,
        usesChatGPTAuthentication: Bool = false,
        cacheURL: URL? = nil,
        cacheTTL: TimeInterval = 300,
        bundledModels: [MSPModelCapabilities]? = nil,
        remoteFetcher: (any MSPModelCatalogRemoteFetching)? = nil,
        remoteRequest: MSPModelCatalogRemoteRequest? = nil
    ) {
        let resolvedBundledModels = bundledModels ?? MSPBundledModelCatalog.models
        self.providerID = providerID
        self.accountID = accountID
        self.credentialScopeID = credentialScopeID
        self.clientVersion = clientVersion
        self.usesChatGPTAuthentication = usesChatGPTAuthentication
        self.cacheTTL = cacheTTL
        self.bundledModels = resolvedBundledModels
        self.remoteFetcher = remoteFetcher
        baseRemoteRequest = remoteRequest
        cacheFileURL = Self.cacheFileURL(
            cacheURL: cacheURL,
            providerID: providerID,
            baseURL: remoteRequest?.baseURL,
            accountID: accountID,
            credentialScopeID: credentialScopeID,
            enabled: remoteFetcher != nil && remoteRequest != nil
        )
        activeSnapshot = MSPModelCatalogSnapshot(
            models: resolvedBundledModels,
            metadataSource: .bundled,
            revision: MSPBundledModelCatalog.revision,
            providerID: providerID,
            accountID: accountID
        )
    }

    public init(
        endpoint: MSPResponsesModelsEndpoint,
        cacheDirectory: URL? = nil,
        cacheTTL: TimeInterval = 300,
        bundledModels: [MSPModelCapabilities]? = nil
    ) {
        let configuration = endpoint.configuration
        self.init(
            providerID: configuration.providerID,
            accountID: configuration.accountID,
            credentialScopeID: configuration.credentialScopeID,
            clientVersion: configuration.clientVersion,
            usesChatGPTAuthentication: configuration.usesChatGPTAuthentication,
            cacheURL: cacheDirectory,
            cacheTTL: cacheTTL,
            bundledModels: bundledModels,
            remoteFetcher: endpoint,
            remoteRequest: configuration.request()
        )
    }

    public static func bundledOnly(
        bundledModels: [MSPModelCapabilities]? = nil
    ) -> MSPModelCatalogManager {
        MSPModelCatalogManager(
            providerID: "bundled",
            bundledModels: bundledModels,
            remoteFetcher: nil,
            remoteRequest: nil
        )
    }

    public static func responses(
        configuration: MSPAgentModelConfiguration,
        clientVersion: String = MSPModelCatalogClientVersion.current,
        cacheURL: URL? = nil
    ) -> MSPModelCatalogManager {
        let providerID = catalogProviderScope(for: configuration)
        let accountID = catalogAccountID(from: configuration.additionalHTTPHeaders)
        let usesChatGPTAuthentication = isChatGPTCatalogURL(configuration.baseURL)
        let credentialScopeID = credentialCacheScopeID(for: configuration)
        let endpoint = MSPResponsesModelsEndpoint(
            configuration: .init(
                baseURL: configuration.baseURL,
                clientVersion: clientVersion,
                bearerToken: configuration.apiKey.isEmpty ? nil : configuration.apiKey,
                additionalHeaders: configuration.additionalHTTPHeaders,
                providerID: providerID,
                accountID: accountID,
                credentialScopeID: credentialScopeID,
                usesChatGPTAuthentication: usesChatGPTAuthentication
            )
        )
        return MSPModelCatalogManager(endpoint: endpoint, cacheDirectory: cacheURL)
    }

    public func snapshot(
        refreshPolicy: MSPModelCatalogRefreshPolicy = .onlineIfUncached
    ) async -> MSPModelCatalogSnapshot {
        do {
            return try await refreshThrowing(refreshPolicy: refreshPolicy)
        } catch {
            return activeSnapshot
        }
    }

    public func resolve(
        modelID: String,
        refreshPolicy: MSPModelCatalogRefreshPolicy = .onlineIfUncached
    ) async -> MSPResolvedModelProfile {
        let catalog = await snapshot(refreshPolicy: refreshPolicy)
        return catalog.resolvedProfile(for: modelID)
    }

    public func refreshThrowing(
        refreshPolicy: MSPModelCatalogRefreshPolicy
    ) async throws -> MSPModelCatalogSnapshot {
        switch refreshPolicy {
        case .offline:
            if let cached = loadCache(requireFresh: true) {
                return applyCachedCatalog(cached)
            }
            return activeSnapshot
        case .onlineIfUncached:
            if let freshActiveSnapshot {
                return freshActiveSnapshot
            }
            if let cached = loadCache(requireFresh: true) {
                return applyCachedCatalog(cached)
            }
            if shouldBackOffRemoteRefresh {
                return activeSnapshot
            }
            return try await fetchRemoteCatalogRecordingFailure()
        case .online:
            return try await fetchRemoteCatalogRecordingFailure()
        }
    }

    private var freshActiveSnapshot: MSPModelCatalogSnapshot? {
        guard cacheTTL > 0,
              activeSnapshot.metadataSource == .remote
                  || activeSnapshot.metadataSource == .diskCache,
              let fetchedAt = activeSnapshot.fetchedAt,
              Date().timeIntervalSince(fetchedAt) <= cacheTTL else {
            return nil
        }
        return activeSnapshot
    }

    private var shouldBackOffRemoteRefresh: Bool {
        guard cacheTTL > 0, let lastRemoteRefreshFailureAt else {
            return false
        }
        return Date().timeIntervalSince(lastRemoteRefreshFailureAt) <= cacheTTL
    }

    private func fetchRemoteCatalogRecordingFailure() async throws -> MSPModelCatalogSnapshot {
        do {
            let snapshot = try await fetchRemoteCatalog()
            lastRemoteRefreshFailureAt = nil
            return snapshot
        } catch {
            if !Task.isCancelled, !Self.isCancellationLikeError(error) {
                lastRemoteRefreshFailureAt = Date()
            }
            throw error
        }
    }

    private func fetchRemoteCatalog() async throws -> MSPModelCatalogSnapshot {
        let refreshID: UUID
        if let inFlightRemoteRefresh {
            refreshID = inFlightRemoteRefresh.id
        } else {
            guard let remoteFetcher, var request = baseRemoteRequest else {
                throw MSPModelCatalogManagerError.remoteEndpointUnavailable
            }
            let cached = loadCache(requireFresh: false)
            request.ifNoneMatch = activeSnapshot.etag ?? cached?.etag
            let nextRefreshID = UUID()
            let task = Task { [weak self] in
                let result: Result<MSPModelCatalogRemoteResponse, Error>
                do {
                    result = .success(try await remoteFetcher.fetchModels(request: request))
                } catch {
                    result = .failure(error)
                }
                await self?.completeRemoteRefresh(
                    refreshID: nextRefreshID,
                    cached: cached,
                    result: result
                )
            }
            inFlightRemoteRefresh = InFlightRemoteRefresh(
                id: nextRefreshID,
                task: task,
                waiters: [:]
            )
            refreshID = nextRefreshID
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard var refresh = inFlightRemoteRefresh,
                      refresh.id == refreshID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !Task.isCancelled else {
                    if refresh.waiters.isEmpty {
                        inFlightRemoteRefresh = nil
                        refresh.task.cancel()
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                refresh.waiters[waiterID] = continuation
                inFlightRemoteRefresh = refresh
                if Task.isCancelled {
                    cancelRemoteRefreshWaiter(
                        refreshID: refreshID,
                        waiterID: waiterID
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelRemoteRefreshWaiter(
                    refreshID: refreshID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func completeRemoteRefresh(
        refreshID: UUID,
        cached: DiskCache?,
        result: Result<MSPModelCatalogRemoteResponse, Error>
    ) {
        guard let refresh = inFlightRemoteRefresh,
              refresh.id == refreshID else {
            return
        }
        inFlightRemoteRefresh = nil

        switch result {
        case .success(let response):
            do {
                let snapshot = try applyRemoteResponse(response, cached: cached)
                for waiter in refresh.waiters.values {
                    waiter.resume(returning: snapshot)
                }
            } catch {
                for waiter in refresh.waiters.values {
                    waiter.resume(throwing: error)
                }
            }
        case .failure(let error):
            for waiter in refresh.waiters.values {
                waiter.resume(throwing: error)
            }
        }
    }

    private func cancelRemoteRefreshWaiter(
        refreshID: UUID,
        waiterID: UUID
    ) {
        guard var refresh = inFlightRemoteRefresh,
              refresh.id == refreshID else {
            return
        }
        let waiter = refresh.waiters.removeValue(forKey: waiterID)
        if refresh.waiters.isEmpty {
            inFlightRemoteRefresh = nil
            refresh.task.cancel()
        } else {
            inFlightRemoteRefresh = refresh
        }
        waiter?.resume(throwing: CancellationError())
    }

    private func applyRemoteResponse(
        _ response: MSPModelCatalogRemoteResponse,
        cached: DiskCache?
    ) throws -> MSPModelCatalogSnapshot {
        if response.notModified {
            guard let models = lastRemoteModels ?? cached?.models else {
                throw MSPModelCatalogManagerError.notModifiedWithoutCachedCatalog
            }
            let renewed = DiskCache(
                scopeKey: cacheScopeKey,
                clientVersion: clientVersion,
                fetchedAt: response.receivedAt,
                etag: response.etag ?? cached?.etag,
                models: models
            )
            try? persistCache(renewed)
            return applyRemoteCatalog(
                models,
                source: .remote,
                fetchedAt: response.receivedAt,
                etag: renewed.etag
            )
        }

        let cache = DiskCache(
            scopeKey: cacheScopeKey,
            clientVersion: clientVersion,
            fetchedAt: response.receivedAt,
            etag: response.etag,
            models: response.models
        )
        try? persistCache(cache)
        return applyRemoteCatalog(
            response.models,
            source: .remote,
            fetchedAt: response.receivedAt,
            etag: response.etag
        )
    }

    private func applyCachedCatalog(_ cache: DiskCache) -> MSPModelCatalogSnapshot {
        applyRemoteCatalog(
            cache.models,
            source: .diskCache,
            fetchedAt: cache.fetchedAt,
            etag: cache.etag
        )
    }

    private func applyRemoteCatalog(
        _ remoteModels: [MSPModelCapabilities],
        source: MSPModelMetadataSource,
        fetchedAt: Date,
        etag: String?
    ) -> MSPModelCatalogSnapshot {
        lastRemoteModels = remoteModels
        let remoteIsAuthoritative = usesChatGPTAuthentication
            && !remoteModels.isEmpty
            && remoteModels.contains(where: \.isVisible)

        let models: [MSPModelCapabilities]
        var modelSources: [String: MSPModelMetadataSource]
        if remoteIsAuthoritative {
            models = remoteModels
            modelSources = [:]
            for model in remoteModels {
                modelSources[model.slug] = source
            }
        } else {
            var merged = bundledModels
            modelSources = [:]
            for model in bundledModels {
                modelSources[model.slug] = .bundled
            }
            for remote in remoteModels {
                if let index = merged.firstIndex(where: { $0.slug == remote.slug }) {
                    if remote.entryKind == .basic {
                        merged[index] = merged[index].overlayingBasicMetadata(remote)
                        modelSources[remote.slug] = .bundled
                    } else {
                        merged[index] = remote
                        modelSources[remote.slug] = source
                    }
                } else {
                    merged.append(remote)
                    modelSources[remote.slug] = source
                }
            }
            models = merged
        }

        let revision = etag ?? "\(source.rawValue):\(Int(fetchedAt.timeIntervalSince1970))"
        let snapshot = MSPModelCatalogSnapshot(
            models: models,
            metadataSource: source,
            revision: revision,
            fetchedAt: fetchedAt,
            etag: etag,
            providerID: providerID,
            accountID: accountID,
            modelSources: modelSources
        )
        activeSnapshot = snapshot
        return snapshot
    }

    private struct DiskCache: Codable, Sendable {
        var scopeKey: String
        var clientVersion: String
        var fetchedAt: Date
        var etag: String?
        var models: [MSPModelCapabilities]
    }

    private var cacheScopeKey: String {
        Self.stableScopeHash(
            providerID: providerID,
            baseURL: baseRemoteRequest?.baseURL,
            accountID: accountID,
            credentialScopeID: credentialScopeID
        )
    }

    private func loadCache(requireFresh: Bool) -> DiskCache? {
        guard let cacheFileURL,
              FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let cache = try? decoder.decode(DiskCache.self, from: data) else { return nil }
        guard cache.scopeKey == cacheScopeKey,
              cache.clientVersion == clientVersion else {
            return nil
        }
        if requireFresh {
            guard cacheTTL > 0,
                  Date().timeIntervalSince(cache.fetchedAt) <= cacheTTL else {
                return nil
            }
        }
        return cache
    }

    private func persistCache(_ cache: DiskCache) throws {
        guard let cacheFileURL else { return }
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(cache)
        try data.write(to: cacheFileURL, options: .atomic)
    }

    private static func cacheFileURL(
        cacheURL: URL?,
        providerID: String,
        baseURL: URL?,
        accountID: String?,
        credentialScopeID: String?,
        enabled: Bool
    ) -> URL? {
        guard enabled else { return nil }
        let scopeHash = stableScopeHash(
            providerID: providerID,
            baseURL: baseURL,
            accountID: accountID,
            credentialScopeID: credentialScopeID
        )
        if let cacheURL, cacheURL.pathExtension.lowercased() == "json" {
            return cacheURL
        }
        let root = cacheURL ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ModelShellProxy/ModelCatalog", isDirectory: true)
        return root?.appendingPathComponent("models-\(scopeHash).json")
    }

    /// Stable FNV-1a scope id. This is routing, not cryptographic identity.
    private static func stableScopeHash(
        providerID: String,
        baseURL: URL?,
        accountID: String?,
        credentialScopeID: String?
    ) -> String {
        let input = [
            providerID,
            baseURL?.absoluteString ?? "no-remote-url",
            accountID ?? "anonymous",
            credentialScopeID ?? "anonymous-credential"
        ].joined(separator: "\u{1f}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16, uppercase: false)
    }

    static func credentialCacheScopeID(
        for configuration: MSPAgentModelConfiguration
    ) -> String? {
        if isChatGPTCatalogURL(configuration.baseURL),
           catalogAccountID(from: configuration.additionalHTTPHeaders) != nil {
            return nil
        }
        return credentialCacheScopeID(
            for: configuration.apiKey,
            additionalHTTPHeaders: configuration.additionalHTTPHeaders
        )
    }

    static func credentialCacheScopeID(
        for apiKey: String,
        additionalHTTPHeaders: [String: String] = [:]
    ) -> String? {
        var effectiveHeaders = additionalHTTPHeaders.compactMap { name, value -> (String, String)? in
            let normalizedName = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty, !normalizedValue.isEmpty else {
                return nil
            }
            return (normalizedName, normalizedValue)
        }

        let overridesAuthorization = effectiveHeaders.contains { name, _ in
            name == "authorization"
        }
        let credential = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overridesAuthorization, !credential.isEmpty {
            effectiveHeaders.append(("authorization", "Bearer \(credential)"))
        }
        guard !effectiveHeaders.isEmpty else {
            return nil
        }

        effectiveHeaders.sort { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        var canonical = Data("msp-model-catalog-credential-scope-v2".utf8)
        for (name, value) in effectiveHeaders {
            appendCredentialScopeField(name, to: &canonical)
            appendCredentialScopeField(value, to: &canonical)
        }
        let digest = SHA256.hash(data: canonical)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func appendCredentialScopeField(_ value: String, to data: inout Data) {
        let field = Data(value.utf8)
        var byteCount = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &byteCount) { bytes in
            data.append(contentsOf: bytes)
        }
        data.append(field)
    }

    private static func isCancellationLikeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    private static func catalogProviderScope(
        for configuration: MSPAgentModelConfiguration
    ) -> String {
        let provider = configuration.providerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        )
        components?.query = nil
        components?.fragment = nil
        var path = components?.path ?? ""
        if path.hasSuffix("/responses") {
            path.removeLast("/responses".count)
        } else if path.hasSuffix("/responses/") {
            path.removeLast("/responses/".count)
        }
        let scheme = components?.scheme?.lowercased() ?? "unknown"
        let host = components?.host?.lowercased() ?? "local"
        let port = components?.port.map { ":\($0)" } ?? ""
        return "\(provider.isEmpty ? "provider" : provider)|\(scheme)://\(host)\(port)\(path)"
    }

    private static func catalogAccountID(
        from headers: [String: String]
    ) -> String? {
        let acceptedNames = [
            "chatgpt-account-id",
            "openai-account-id",
            "x-openai-account-id",
            "x-account-id"
        ]
        return headers.first { name, value in
            acceptedNames.contains(name.lowercased())
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isChatGPTCatalogURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return (host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"))
            && path.contains("/backend-api/codex")
    }
}
