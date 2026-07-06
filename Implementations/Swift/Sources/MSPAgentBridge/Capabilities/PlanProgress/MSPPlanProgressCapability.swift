import Foundation

public struct MSPPlanProgressCapability: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case enabled
        case disabled
    }

    public var mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public static func enabled() -> MSPPlanProgressCapability {
        MSPPlanProgressCapability(mode: .enabled)
    }

    public static let disabled = MSPPlanProgressCapability(mode: .disabled)

    public var isEnabled: Bool {
        mode == .enabled
    }

    public var toolsVisible: Bool {
        isEnabled
    }

    public var declaration: MSPPlanProgressCapabilityDeclaration {
        MSPPlanProgressCapabilityDeclaration(
            name: "plan_progress",
            enabled: toolsVisible,
            modelTools: toolsVisible ? [MSPUpdatePlanToolSchema.name] : []
        )
    }

    func augmentTools(
        _ tools: [MSPAgentModelToolDefinition]
    ) -> [MSPAgentModelToolDefinition] {
        var result = tools.filter { $0.name != MSPUpdatePlanToolSchema.name }
        if toolsVisible {
            result.append(MSPAgentRequestBuilder.updatePlanToolDefinition)
        }
        return result
    }
}

public struct MSPPlanProgressCapabilityDeclaration: Hashable, Sendable {
    public var name: String
    public var enabled: Bool
    public var modelTools: [String]

    public init(
        name: String,
        enabled: Bool,
        modelTools: [String]
    ) {
        self.name = name
        self.enabled = enabled
        self.modelTools = modelTools
    }
}
