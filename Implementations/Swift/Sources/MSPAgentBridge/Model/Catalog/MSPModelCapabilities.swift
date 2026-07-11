import Foundation

public enum MSPModelCatalogEntryKind: String, Codable, Hashable, Sendable {
    /// A provider-specific entry containing capability metadata.
    case rich
    /// A standard `/v1/models` entry containing little more than a model id.
    case basic
}

/// Provider-advertised model metadata used by request, UI, and compaction code.
///
/// Provenance: field names and defaults are compatible with the Apache-2.0
/// OpenAI Codex `ModelInfo` catalog format. The decoder also accepts standard
/// OpenAI `{data:[{id:...}]}` model entries without inventing capabilities.
public struct MSPModelCapabilities: Codable, Hashable, Sendable {
    public var slug: String
    public var displayName: String
    public var description: String?
    public var defaultReasoningEffort: MSPReasoningEffort?
    public var supportedReasoningEfforts: [MSPReasoningEffortPreset]
    public var visibility: String
    public var supportedInAPI: Bool
    public var priority: Int
    public var contextWindow: Int?
    public var maxContextWindow: Int?
    public var effectiveContextWindowPercent: Int
    public var explicitAutoCompactTokenLimit: Int?
    public var compHash: String?
    public var entryKind: MSPModelCatalogEntryKind

    public init(
        slug: String,
        displayName: String? = nil,
        description: String? = nil,
        defaultReasoningEffort: MSPReasoningEffort? = nil,
        supportedReasoningEfforts: [MSPReasoningEffortPreset] = [],
        visibility: String = "list",
        supportedInAPI: Bool = true,
        priority: Int = 99,
        contextWindow: Int? = nil,
        maxContextWindow: Int? = nil,
        effectiveContextWindowPercent: Int = 95,
        explicitAutoCompactTokenLimit: Int? = nil,
        compHash: String? = nil,
        entryKind: MSPModelCatalogEntryKind = .rich
    ) {
        self.slug = slug
        self.displayName = displayName ?? slug
        self.description = description
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.visibility = visibility
        self.supportedInAPI = supportedInAPI
        self.priority = priority
        self.contextWindow = contextWindow
        self.maxContextWindow = maxContextWindow
        self.effectiveContextWindowPercent = effectiveContextWindowPercent
        self.explicitAutoCompactTokenLimit = explicitAutoCompactTokenLimit
        self.compHash = compHash
        self.entryKind = entryKind
    }

    public var isVisible: Bool {
        visibility.caseInsensitiveCompare("list") == .orderedSame
    }

    public var resolvedContextWindow: Int? {
        contextWindow ?? maxContextWindow
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case id
        case displayName
        case displayNameSnake = "display_name"
        case name
        case description
        case defaultReasoningEffort
        case defaultReasoningEffortSnake = "default_reasoning_effort"
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningEfforts
        case supportedReasoningEffortsSnake = "supported_reasoning_efforts"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case visibility
        case supportedInAPI
        case supportedInAPISnake = "supported_in_api"
        case priority
        case contextWindow
        case contextWindowSnake = "context_window"
        case maxContextWindow
        case maxContextWindowSnake = "max_context_window"
        case effectiveContextWindowPercent
        case effectiveContextWindowPercentSnake = "effective_context_window_percent"
        case explicitAutoCompactTokenLimit
        case explicitAutoCompactTokenLimitSnake = "explicit_auto_compact_token_limit"
        case autoCompactTokenLimit = "auto_compact_token_limit"
        case compHash
        case compHashSnake = "comp_hash"
        case entryKind
        case entryKindSnake = "catalog_entry_kind"
        case object
        case created
        case ownedBy
        case ownedBySnake = "owned_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSlug = try container.decodeIfPresent(String.self, forKey: .slug)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        guard let decodedSlug, !decodedSlug.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.slug,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A model catalog entry requires a non-empty slug or id."
                )
            )
        }

        slug = decodedSlug
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .displayNameSnake)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? decodedSlug
        description = try container.decodeIfPresent(String.self, forKey: .description)
        defaultReasoningEffort = try container.decodeIfPresent(
            MSPReasoningEffort.self,
            forKey: .defaultReasoningEffort
        ) ?? container.decodeIfPresent(
            MSPReasoningEffort.self,
            forKey: .defaultReasoningEffortSnake
        ) ?? container.decodeIfPresent(
            MSPReasoningEffort.self,
            forKey: .defaultReasoningLevel
        )

        supportedReasoningEfforts = try Self.decodeReasoningPresets(from: container)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "list"
        supportedInAPI = try container.decodeIfPresent(Bool.self, forKey: .supportedInAPI)
            ?? container.decodeIfPresent(Bool.self, forKey: .supportedInAPISnake)
            ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 99
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
            ?? container.decodeIfPresent(Int.self, forKey: .contextWindowSnake)
        maxContextWindow = try container.decodeIfPresent(Int.self, forKey: .maxContextWindow)
            ?? container.decodeIfPresent(Int.self, forKey: .maxContextWindowSnake)
        effectiveContextWindowPercent = try container.decodeIfPresent(
            Int.self,
            forKey: .effectiveContextWindowPercent
        ) ?? container.decodeIfPresent(
            Int.self,
            forKey: .effectiveContextWindowPercentSnake
        ) ?? 95
        explicitAutoCompactTokenLimit = try container.decodeIfPresent(
            Int.self,
            forKey: .explicitAutoCompactTokenLimit
        ) ?? container.decodeIfPresent(
            Int.self,
            forKey: .explicitAutoCompactTokenLimitSnake
        ) ?? container.decodeIfPresent(
            Int.self,
            forKey: .autoCompactTokenLimit
        )
        compHash = try container.decodeIfPresent(String.self, forKey: .compHash)
            ?? container.decodeIfPresent(String.self, forKey: .compHashSnake)

        let explicitKind = try container.decodeIfPresent(
            MSPModelCatalogEntryKind.self,
            forKey: .entryKind
        ) ?? container.decodeIfPresent(
            MSPModelCatalogEntryKind.self,
            forKey: .entryKindSnake
        )
        entryKind = explicitKind ?? (Self.containsRichMetadata(container) ? .rich : .basic)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(displayName, forKey: .displayNameSnake)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningLevel)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningLevels)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(supportedInAPI, forKey: .supportedInAPISnake)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindowSnake)
        try container.encodeIfPresent(maxContextWindow, forKey: .maxContextWindowSnake)
        try container.encode(
            effectiveContextWindowPercent,
            forKey: .effectiveContextWindowPercentSnake
        )
        try container.encodeIfPresent(
            explicitAutoCompactTokenLimit,
            forKey: .autoCompactTokenLimit
        )
        try container.encodeIfPresent(compHash, forKey: .compHashSnake)
        try container.encode(entryKind, forKey: .entryKindSnake)
    }

    private static func decodeReasoningPresets(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [MSPReasoningEffortPreset] {
        let keys: [CodingKeys] = [
            .supportedReasoningEfforts,
            .supportedReasoningEffortsSnake,
            .supportedReasoningLevels
        ]
        for key in keys where container.contains(key) {
            if let presets = try? container.decode([MSPReasoningEffortPreset].self, forKey: key) {
                return presets
            }
            if let efforts = try? container.decode([MSPReasoningEffort].self, forKey: key) {
                return efforts.map {
                    MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
                }
            }
        }
        return []
    }

    private static func containsRichMetadata(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> Bool {
        let richKeys: [CodingKeys] = [
            .defaultReasoningEffort, .defaultReasoningEffortSnake, .defaultReasoningLevel,
            .supportedReasoningEfforts, .supportedReasoningEffortsSnake,
            .supportedReasoningLevels, .contextWindow, .contextWindowSnake, .maxContextWindow,
            .maxContextWindowSnake, .effectiveContextWindowPercent,
            .effectiveContextWindowPercentSnake, .explicitAutoCompactTokenLimit,
            .explicitAutoCompactTokenLimitSnake, .autoCompactTokenLimit,
            .compHash, .compHashSnake
        ]
        return richKeys.contains(where: container.contains)
    }

    /// Standard `/v1/models` entries are sparse. When such an entry names a
    /// bundled model, retain the known capability metadata instead of replacing
    /// it with empty defaults.
    func overlayingBasicMetadata(
        _ remote: MSPModelCapabilities
    ) -> MSPModelCapabilities {
        var merged = self
        merged.slug = remote.slug
        if remote.displayName != remote.slug {
            merged.displayName = remote.displayName
        }
        if let description = remote.description {
            merged.description = description
        }
        if let defaultReasoningEffort = remote.defaultReasoningEffort {
            merged.defaultReasoningEffort = defaultReasoningEffort
        }
        if !remote.supportedReasoningEfforts.isEmpty {
            merged.supportedReasoningEfforts = remote.supportedReasoningEfforts
        }
        merged.supportedInAPI = remote.supportedInAPI
        merged.entryKind = .rich
        return merged
    }
}
