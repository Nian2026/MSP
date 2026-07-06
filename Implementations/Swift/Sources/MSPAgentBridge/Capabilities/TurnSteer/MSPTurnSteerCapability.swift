import Foundation

public struct MSPTurnSteerCapability: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case enabled
        case disabled
    }

    public var mode: Mode

    public init(mode: Mode = .enabled) {
        self.mode = mode
    }

    public static let enabled = MSPTurnSteerCapability(mode: .enabled)
    public static let disabled = MSPTurnSteerCapability(mode: .disabled)

    public var isEnabled: Bool {
        mode == .enabled
    }

    public var declaration: MSPTurnSteerCapabilityDeclaration {
        MSPTurnSteerCapabilityDeclaration(
            name: "turn_steer",
            enabled: isEnabled,
            methods: isEnabled ? ["turn/steer"] : [],
            requiresExpectedTurnID: true,
            modelVisibleInputBoundary: .activeTurnPendingInput
        )
    }
}

public struct MSPTurnSteerCapabilityDeclaration: Hashable, Sendable {
    public enum ModelVisibleInputBoundary: String, Hashable, Sendable {
        case activeTurnPendingInput = "active_turn_pending_input"
    }

    public var name: String
    public var enabled: Bool
    public var methods: [String]
    public var requiresExpectedTurnID: Bool
    public var modelVisibleInputBoundary: ModelVisibleInputBoundary

    public init(
        name: String,
        enabled: Bool,
        methods: [String],
        requiresExpectedTurnID: Bool,
        modelVisibleInputBoundary: ModelVisibleInputBoundary
    ) {
        self.name = name
        self.enabled = enabled
        self.methods = methods
        self.requiresExpectedTurnID = requiresExpectedTurnID
        self.modelVisibleInputBoundary = modelVisibleInputBoundary
    }
}
