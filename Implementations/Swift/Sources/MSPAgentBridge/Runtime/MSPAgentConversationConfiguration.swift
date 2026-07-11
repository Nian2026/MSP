import Foundation

public struct MSPAgentConversationConfiguration: Hashable, Sendable {
    public var model: String
    public var instructions: String
    public var developerContextBlocks: [String]
    public var environmentNotes: [String]
    public var tools: [MSPAgentModelToolDefinition]
    public var toolChoice: String
    public var reasoningEffort: String
    public var textVerbosity: String
    public var store: Bool
    public var stream: Bool
    public var parallelToolCalls: Bool
    public var include: [String]
    public var promptCacheKey: String?
    public var compactionPolicy: MSPCompactionPolicy
    public var turnInterruptCapability: MSPTurnInterruptCapability
    public var turnSteerCapability: MSPTurnSteerCapability
    public var goalCapability: MSPGoalCapability
    public var planProgressCapability: MSPPlanProgressCapability
    public var planModeCapability: MSPPlanModeCapability

    public init(
        model: String,
        instructions: String = MSPAgentInstructions.defaultInstructions,
        developerContextBlocks: [String] = [MSPAgentInstructions.defaultApplicationContext],
        environmentNotes: [String] = MSPAgentInstructions.defaultEnvironmentNotes(),
        tools: [MSPAgentModelToolDefinition] = MSPAgentRequestBuilder.defaultToolDefinitions,
        toolChoice: String = "auto",
        reasoningEffort: String = MSPReasoningEffort.modelDefaultValue,
        textVerbosity: String = "medium",
        store: Bool = false,
        stream: Bool = true,
        parallelToolCalls: Bool = false,
        include: [String] = [],
        promptCacheKey: String? = nil,
        compactionPolicy: MSPCompactionPolicy = .automatic,
        goalCapability: MSPGoalCapability = .disabled,
        planProgressCapability: MSPPlanProgressCapability = .disabled,
        planModeCapability: MSPPlanModeCapability = .disabled
    ) {
        self.model = model
        self.instructions = instructions
        self.developerContextBlocks = developerContextBlocks
        self.environmentNotes = environmentNotes
        self.tools = tools
        self.toolChoice = toolChoice
        self.reasoningEffort = reasoningEffort
        self.textVerbosity = textVerbosity
        self.store = store
        self.stream = stream
        self.parallelToolCalls = parallelToolCalls
        self.include = include
        self.promptCacheKey = promptCacheKey
        self.compactionPolicy = compactionPolicy
        self.turnInterruptCapability = .enabled()
        self.turnSteerCapability = .enabled
        self.goalCapability = goalCapability
        self.planProgressCapability = planProgressCapability
        self.planModeCapability = planModeCapability
    }

    public init(
        model: String,
        instructions: String = MSPAgentInstructions.defaultInstructions,
        developerContextBlocks: [String] = [MSPAgentInstructions.defaultApplicationContext],
        environmentNotes: [String] = MSPAgentInstructions.defaultEnvironmentNotes(),
        tools: [MSPAgentModelToolDefinition] = MSPAgentRequestBuilder.defaultToolDefinitions,
        toolChoice: String = "auto",
        reasoningEffort: String = MSPReasoningEffort.modelDefaultValue,
        textVerbosity: String = "medium",
        store: Bool = false,
        stream: Bool = true,
        parallelToolCalls: Bool = false,
        include: [String] = [],
        promptCacheKey: String? = nil,
        compactionPolicy: MSPCompactionPolicy,
        turnInterruptCapability: MSPTurnInterruptCapability,
        turnSteerCapability: MSPTurnSteerCapability = .enabled,
        goalCapability: MSPGoalCapability = .disabled,
        planProgressCapability: MSPPlanProgressCapability = .disabled,
        planModeCapability: MSPPlanModeCapability = .disabled
    ) {
        self.init(
            model: model,
            instructions: instructions,
            developerContextBlocks: developerContextBlocks,
            environmentNotes: environmentNotes,
            tools: tools,
            toolChoice: toolChoice,
            reasoningEffort: reasoningEffort,
            textVerbosity: textVerbosity,
            store: store,
            stream: stream,
            parallelToolCalls: parallelToolCalls,
            include: include,
            promptCacheKey: promptCacheKey,
            compactionPolicy: compactionPolicy,
            goalCapability: goalCapability,
            planProgressCapability: planProgressCapability,
            planModeCapability: planModeCapability
        )
        self.turnInterruptCapability = turnInterruptCapability
        self.turnSteerCapability = turnSteerCapability
    }

    public init(
        model: String,
        instructions: String = MSPAgentInstructions.defaultInstructions,
        developerContextBlocks: [String] = [MSPAgentInstructions.defaultApplicationContext],
        environmentNotes: [String] = MSPAgentInstructions.defaultEnvironmentNotes(),
        tools: [MSPAgentModelToolDefinition] = MSPAgentRequestBuilder.defaultToolDefinitions,
        toolChoice: String = "auto",
        reasoningEffort: String = MSPReasoningEffort.modelDefaultValue,
        textVerbosity: String = "medium",
        store: Bool = false,
        stream: Bool = true,
        parallelToolCalls: Bool = false,
        include: [String] = [],
        promptCacheKey: String? = nil
    ) {
        self.init(
            model: model,
            instructions: instructions,
            developerContextBlocks: developerContextBlocks,
            environmentNotes: environmentNotes,
            tools: tools,
            toolChoice: toolChoice,
            reasoningEffort: reasoningEffort,
            textVerbosity: textVerbosity,
            store: store,
            stream: stream,
            parallelToolCalls: parallelToolCalls,
            include: include,
            promptCacheKey: promptCacheKey,
            compactionPolicy: .automatic
        )
    }

    public init(
        model: String,
        instructions: String = MSPAgentInstructions.defaultInstructions,
        developerContextBlocks: [String] = [MSPAgentInstructions.defaultApplicationContext],
        environmentNotes: [String] = MSPAgentInstructions.defaultEnvironmentNotes(),
        tools: [MSPAgentModelToolDefinition] = MSPAgentRequestBuilder.defaultToolDefinitions,
        toolChoice: String = "auto",
        reasoningEffort: String = MSPReasoningEffort.modelDefaultValue,
        textVerbosity: String = "medium",
        store: Bool = false,
        stream: Bool = true,
        parallelToolCalls: Bool = false,
        include: [String] = [],
        promptCacheKey: String? = nil,
        turnInterruptCapability: MSPTurnInterruptCapability,
        turnSteerCapability: MSPTurnSteerCapability = .enabled,
        goalCapability: MSPGoalCapability = .disabled,
        planProgressCapability: MSPPlanProgressCapability = .disabled,
        planModeCapability: MSPPlanModeCapability = .disabled
    ) {
        self.init(
            model: model,
            instructions: instructions,
            developerContextBlocks: developerContextBlocks,
            environmentNotes: environmentNotes,
            tools: tools,
            toolChoice: toolChoice,
            reasoningEffort: reasoningEffort,
            textVerbosity: textVerbosity,
            store: store,
            stream: stream,
            parallelToolCalls: parallelToolCalls,
            include: include,
            promptCacheKey: promptCacheKey,
            compactionPolicy: .automatic,
            turnInterruptCapability: turnInterruptCapability,
            turnSteerCapability: turnSteerCapability,
            goalCapability: goalCapability,
            planProgressCapability: planProgressCapability,
            planModeCapability: planModeCapability
        )
    }

    public init(
        model: String,
        instructions: String = MSPAgentInstructions.defaultInstructions,
        developerContextBlocks: [String] = [MSPAgentInstructions.defaultApplicationContext],
        environmentNotes: [String] = MSPAgentInstructions.defaultEnvironmentNotes(),
        tools: [MSPAgentModelToolDefinition] = MSPAgentRequestBuilder.defaultToolDefinitions,
        toolChoice: String = "auto",
        reasoningEffort: String = MSPReasoningEffort.modelDefaultValue,
        textVerbosity: String = "medium",
        store: Bool = false,
        stream: Bool = true,
        parallelToolCalls: Bool = false,
        include: [String] = [],
        promptCacheKey: String? = nil,
        turnSteerCapability: MSPTurnSteerCapability,
        goalCapability: MSPGoalCapability = .disabled,
        planProgressCapability: MSPPlanProgressCapability = .disabled,
        planModeCapability: MSPPlanModeCapability = .disabled
    ) {
        self.init(
            model: model,
            instructions: instructions,
            developerContextBlocks: developerContextBlocks,
            environmentNotes: environmentNotes,
            tools: tools,
            toolChoice: toolChoice,
            reasoningEffort: reasoningEffort,
            textVerbosity: textVerbosity,
            store: store,
            stream: stream,
            parallelToolCalls: parallelToolCalls,
            include: include,
            promptCacheKey: promptCacheKey,
            compactionPolicy: .automatic
        )
        self.turnSteerCapability = turnSteerCapability
        self.goalCapability = goalCapability
        self.planProgressCapability = planProgressCapability
        self.planModeCapability = planModeCapability
    }

    func requestContext(
        prompt: String,
        modelProfile: MSPResolvedModelProfile? = nil,
        planProgressToolsVisible: Bool = true
    ) -> MSPAgentRequestBuildContext {
        let baseTools = goalCapability.augmentTools(tools)
        let requestTools = planProgressToolsVisible
            ? planProgressCapability.augmentTools(baseTools)
            : MSPPlanProgressCapability.disabled.augmentTools(baseTools)
        let resolvedReasoningEffort = modelProfile?
            .effectiveReasoningEffort(for: reasoningEffort)?
            .rawValue
            ?? reasoningEffort
        return MSPAgentRequestBuildContext(
            model: model,
            prompt: prompt,
            instructions: instructions,
            developerContextBlocks: developerContextBlocks,
            environmentNotes: environmentNotes,
            tools: requestTools,
            toolChoice: toolChoice,
            reasoningEffort: resolvedReasoningEffort,
            textVerbosity: textVerbosity,
            store: store,
            stream: stream,
            parallelToolCalls: parallelToolCalls,
            include: include,
            promptCacheKey: promptCacheKey
        )
    }
}
