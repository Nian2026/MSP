import Foundation

public enum MSPReasoningEffortError: Error, Equatable, Sendable {
    case emptyValue
}

/// An open-ended reasoning effort value advertised by a model catalog.
///
/// Provenance: this open-string representation follows the Apache-2.0 OpenAI
/// Codex `ReasoningEffort` wire semantics while remaining native Swift code.
public struct MSPReasoningEffort: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw MSPReasoningEffortError.emptyValue
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Reasoning effort must not be empty."
            )
        }
        rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let none = MSPReasoningEffort(rawValue: "none")!
    public static let minimal = MSPReasoningEffort(rawValue: "minimal")!
    public static let low = MSPReasoningEffort(rawValue: "low")!
    public static let medium = MSPReasoningEffort(rawValue: "medium")!
    public static let high = MSPReasoningEffort(rawValue: "high")!
    public static let xhigh = MSPReasoningEffort(rawValue: "xhigh")!
    public static let max = MSPReasoningEffort(rawValue: "max")!
    public static let ultra = MSPReasoningEffort(rawValue: "ultra")!

    /// UI/configuration sentinel meaning "use the selected model's default".
    /// This value must be reconciled before constructing a provider request.
    public static let modelDefault = MSPReasoningEffort(rawValue: "model_default")!
    public static let modelDefaultValue = "model_default"
}

public struct MSPReasoningEffortPreset: Codable, Hashable, Sendable {
    public var effort: MSPReasoningEffort
    public var description: String

    public init(effort: MSPReasoningEffort, description: String) {
        self.effort = effort
        self.description = description
    }
}
