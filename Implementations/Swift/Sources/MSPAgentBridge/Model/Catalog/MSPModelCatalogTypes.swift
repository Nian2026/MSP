import Foundation

public enum MSPModelCatalogClientVersion {
    /// Semantic client version sent to provider-owned Codex model catalogs.
    /// Hosts with their own release version can override this at manager creation.
    public static let current = "1.0.0"
}

public enum MSPModelCatalogRefreshPolicy: String, Codable, Hashable, Sendable {
    case online
    case offline
    case onlineIfUncached = "online_if_uncached"
}

public struct MSPModelCatalogRemoteRequest: Hashable, Sendable {
    public var baseURL: URL
    public var clientVersion: String
    public var bearerToken: String?
    public var additionalHeaders: [String: String]
    public var ifNoneMatch: String?
    public var includesClientVersionQuery: Bool
    public var timeoutInterval: TimeInterval

    public init(
        baseURL: URL,
        clientVersion: String = MSPModelCatalogClientVersion.current,
        bearerToken: String? = nil,
        additionalHeaders: [String: String] = [:],
        ifNoneMatch: String? = nil,
        includesClientVersionQuery: Bool = false,
        timeoutInterval: TimeInterval = 5
    ) {
        self.baseURL = baseURL
        self.clientVersion = clientVersion
        self.bearerToken = bearerToken
        self.additionalHeaders = additionalHeaders
        self.ifNoneMatch = ifNoneMatch
        self.includesClientVersionQuery = includesClientVersionQuery
        self.timeoutInterval = timeoutInterval
    }
}

public struct MSPModelCatalogRemoteResponse: Hashable, Sendable {
    public var models: [MSPModelCapabilities]
    public var etag: String?
    public var notModified: Bool
    public var receivedAt: Date

    public init(
        models: [MSPModelCapabilities],
        etag: String? = nil,
        notModified: Bool = false,
        receivedAt: Date = Date()
    ) {
        self.models = models
        self.etag = etag
        self.notModified = notModified
        self.receivedAt = receivedAt
    }
}

public protocol MSPModelCatalogRemoteFetching: Sendable {
    func fetchModels(
        request: MSPModelCatalogRemoteRequest
    ) async throws -> MSPModelCatalogRemoteResponse
}

public protocol MSPModelCatalogResolving: Sendable {
    func snapshot(
        refreshPolicy: MSPModelCatalogRefreshPolicy
    ) async -> MSPModelCatalogSnapshot

    func resolve(
        modelID: String,
        refreshPolicy: MSPModelCatalogRefreshPolicy
    ) async -> MSPResolvedModelProfile
}

public extension MSPModelCatalogResolving {
    func snapshot() async -> MSPModelCatalogSnapshot {
        await snapshot(refreshPolicy: .onlineIfUncached)
    }

    func resolve(modelID: String) async -> MSPResolvedModelProfile {
        await resolve(modelID: modelID, refreshPolicy: .onlineIfUncached)
    }
}

public struct MSPModelCatalogSnapshot: Codable, Hashable, Sendable {
    public var models: [MSPModelCapabilities]
    public var metadataSource: MSPModelMetadataSource
    public var revision: String?
    public var fetchedAt: Date?
    public var etag: String?
    public var providerID: String
    public var accountID: String?
    public var modelSources: [String: MSPModelMetadataSource]

    public init(
        models: [MSPModelCapabilities],
        metadataSource: MSPModelMetadataSource,
        revision: String? = nil,
        fetchedAt: Date? = nil,
        etag: String? = nil,
        providerID: String = "bundled",
        accountID: String? = nil,
        modelSources: [String: MSPModelMetadataSource] = [:]
    ) {
        self.models = models
        self.metadataSource = metadataSource
        self.revision = revision
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.providerID = providerID
        self.accountID = accountID
        if modelSources.isEmpty {
            var sources: [String: MSPModelMetadataSource] = [:]
            for model in models {
                sources[model.slug] = metadataSource
            }
            self.modelSources = sources
        } else {
            self.modelSources = modelSources
        }
    }

    public var visibleModels: [MSPModelCapabilities] {
        models
            .filter { $0.isVisible && $0.entryKind == .rich }
            .sorted(by: Self.catalogOrder)
    }

    public var defaultModelID: String? {
        visibleModels.first?.slug ?? models.sorted(by: Self.catalogOrder).first?.slug
    }

    public func resolvedProfile(
        for modelID: String,
        contextWindowOverride: Int? = nil,
        autoCompactTokenLimitOverride: Int? = nil
    ) -> MSPResolvedModelProfile {
        let capabilityModels = models.filter { $0.entryKind == .rich }
        if let matched = Self.longestPrefixMatch(modelID, candidates: capabilityModels)
            ?? Self.namespacedSuffixMatch(modelID, candidates: capabilityModels) {
            return MSPResolvedModelProfile(
                modelID: modelID,
                matchedModelID: matched.slug,
                capabilities: matched,
                metadataSource: modelSources[matched.slug] ?? metadataSource,
                metadataRevision: revision,
                usedFallbackMetadata: false,
                contextWindowOverride: contextWindowOverride,
                autoCompactTokenLimitOverride: autoCompactTokenLimitOverride
            )
        }
        return Self.fallbackProfile(
            for: modelID,
            revision: revision,
            contextWindowOverride: contextWindowOverride,
            autoCompactTokenLimitOverride: autoCompactTokenLimitOverride
        )
    }

    private static func fallbackProfile(
        for modelID: String,
        revision: String?,
        contextWindowOverride: Int?,
        autoCompactTokenLimitOverride: Int?
    ) -> MSPResolvedModelProfile {
        let fallback = MSPModelCapabilities(
            slug: modelID,
            displayName: modelID,
            visibility: "none",
            supportedInAPI: true,
            priority: 99,
            contextWindow: 272_000,
            maxContextWindow: 272_000,
            effectiveContextWindowPercent: 95
        )
        return MSPResolvedModelProfile(
            modelID: modelID,
            matchedModelID: modelID,
            capabilities: fallback,
            metadataSource: .fallback,
            metadataRevision: revision,
            usedFallbackMetadata: true,
            contextWindowOverride: contextWindowOverride,
            autoCompactTokenLimitOverride: autoCompactTokenLimitOverride
        )
    }

    private static func longestPrefixMatch(
        _ modelID: String,
        candidates: [MSPModelCapabilities]
    ) -> MSPModelCapabilities? {
        candidates
            .filter { modelID.hasPrefix($0.slug) }
            .max { lhs, rhs in lhs.slug.count < rhs.slug.count }
    }

    private static func namespacedSuffixMatch(
        _ modelID: String,
        candidates: [MSPModelCapabilities]
    ) -> MSPModelCapabilities? {
        let components = modelID.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              components[0].unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "_" || scalar == "-"
              }) else {
            return nil
        }
        return longestPrefixMatch(String(components[1]), candidates: candidates)
    }

    private static func catalogOrder(
        _ lhs: MSPModelCapabilities,
        _ rhs: MSPModelCapabilities
    ) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.slug < rhs.slug
    }
}
