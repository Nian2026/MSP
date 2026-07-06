import Foundation

public struct MSPGoalCapability: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case enabled
        case disabled
    }

    public var mode: Mode
    public var persistentThreadStateAvailable: Bool
    public var restoredGoal: MSPGoalSnapshot?

    public init(
        mode: Mode,
        persistentThreadStateAvailable: Bool = true,
        restoredGoal: MSPGoalSnapshot? = nil
    ) {
        self.mode = mode
        self.persistentThreadStateAvailable = persistentThreadStateAvailable
        self.restoredGoal = restoredGoal
    }

    public static func enabled(
        persistentThreadStateAvailable: Bool = true,
        restoredGoal: MSPGoalSnapshot? = nil
    ) -> MSPGoalCapability {
        MSPGoalCapability(
            mode: .enabled,
            persistentThreadStateAvailable: persistentThreadStateAvailable,
            restoredGoal: restoredGoal
        )
    }

    public static let disabled = MSPGoalCapability(mode: .disabled)

    public var isEnabled: Bool {
        mode == .enabled
    }

    public var toolsVisible: Bool {
        isEnabled && persistentThreadStateAvailable
    }

    public var declaration: MSPGoalCapabilityDeclaration {
        MSPGoalCapabilityDeclaration(
            name: "goal",
            enabled: isEnabled && persistentThreadStateAvailable,
            methods: isEnabled && persistentThreadStateAvailable
                ? ["thread/goal/set", "thread/goal/get", "thread/goal/clear"]
                : [],
            modelTools: toolsVisible ? MSPGoalTools.toolNames : [],
            persistentThreadStateAvailable: persistentThreadStateAvailable,
            supportsRuntimeAccounting: isEnabled && persistentThreadStateAvailable,
            supportsIdleContinuation: isEnabled && persistentThreadStateAvailable
        )
    }

    func augmentTools(
        _ tools: [MSPAgentModelToolDefinition]
    ) -> [MSPAgentModelToolDefinition] {
        guard toolsVisible else {
            return tools.filter { !MSPGoalTools.isGoalTool($0.name) }
        }
        var result = tools.filter { !MSPGoalTools.isGoalTool($0.name) }
        result.append(contentsOf: MSPGoalTools.modelToolDefinitions)
        return result
    }
}

public struct MSPGoalCapabilityDeclaration: Hashable, Sendable {
    public var name: String
    public var enabled: Bool
    public var methods: [String]
    public var modelTools: [String]
    public var persistentThreadStateAvailable: Bool
    public var supportsRuntimeAccounting: Bool
    public var supportsIdleContinuation: Bool

    public init(
        name: String,
        enabled: Bool,
        methods: [String],
        modelTools: [String],
        persistentThreadStateAvailable: Bool,
        supportsRuntimeAccounting: Bool,
        supportsIdleContinuation: Bool
    ) {
        self.name = name
        self.enabled = enabled
        self.methods = methods
        self.modelTools = modelTools
        self.persistentThreadStateAvailable = persistentThreadStateAvailable
        self.supportsRuntimeAccounting = supportsRuntimeAccounting
        self.supportsIdleContinuation = supportsIdleContinuation
    }
}
