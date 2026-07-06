import Foundation

public struct MSPPlanModeCapability: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case enabled
        case disabled
    }

    public var mode: Mode

    public init(mode: Mode = .enabled) {
        self.mode = mode
    }

    public static let enabled = MSPPlanModeCapability(mode: .enabled)
    public static let disabled = MSPPlanModeCapability(mode: .disabled)

    public var isEnabled: Bool {
        mode == .enabled
    }

    public var declaration: MSPPlanModeCapabilityDeclaration {
        MSPPlanModeCapabilityDeclaration(
            name: "plan_mode",
            enabled: isEnabled,
            methods: isEnabled ? [
                "thread/plan_mode/enter",
                "turn/plan_mode/start",
                "thread/plan_mode/approve",
                "thread/plan_mode/reject",
                "thread/plan_mode/modify"
            ] : [],
            modelTools: [],
            supportsProposedPlanParsing: isEnabled,
            supportsImplementationHandoff: isEnabled
        )
    }
}

public struct MSPPlanModeCapabilityDeclaration: Hashable, Sendable {
    public var name: String
    public var enabled: Bool
    public var methods: [String]
    public var modelTools: [String]
    public var supportsProposedPlanParsing: Bool
    public var supportsImplementationHandoff: Bool

    public init(
        name: String,
        enabled: Bool,
        methods: [String],
        modelTools: [String],
        supportsProposedPlanParsing: Bool,
        supportsImplementationHandoff: Bool
    ) {
        self.name = name
        self.enabled = enabled
        self.methods = methods
        self.modelTools = modelTools
        self.supportsProposedPlanParsing = supportsProposedPlanParsing
        self.supportsImplementationHandoff = supportsImplementationHandoff
    }
}
