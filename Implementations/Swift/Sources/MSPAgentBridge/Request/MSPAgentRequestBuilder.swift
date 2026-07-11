import Foundation

public struct MSPAgentRequestBuildContext: Hashable, Sendable {
    public var model: String
    public var prompt: String
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

    public init(
        model: String,
        prompt: String,
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
        self.model = model
        self.prompt = prompt
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
    }
}

public struct MSPAgentRequestBody: Codable, Hashable, Sendable {
    public var model: String
    public var instructions: String
    public var input: [MSPAgentInputMessage]
    public var tools: [MSPAgentModelToolDefinition]
    public var toolChoice: String
    public var parallelToolCalls: Bool
    public var reasoning: MSPAgentReasoningOptions?
    public var store: Bool
    public var stream: Bool
    public var include: [String]
    public var promptCacheKey: String?
    public var text: MSPAgentTextOptions

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case reasoning
        case store
        case stream
        case include
        case promptCacheKey = "prompt_cache_key"
        case text
    }
}

public struct MSPAgentInputMessage: Codable, Hashable, Sendable {
    public var type: String
    public var role: String
    public var content: [MSPAgentInputContent]

    public init(
        role: String,
        content: [MSPAgentInputContent],
        type: String = "message"
    ) {
        self.type = type
        self.role = role
        self.content = content
    }
}

public struct MSPAgentInputContent: Codable, Hashable, Sendable {
    public var type: String
    public var text: String

    public init(text: String, type: String = "input_text") {
        self.type = type
        self.text = text
    }
}

public struct MSPAgentFreeformToolFormat: Codable, Hashable, Sendable {
    public var type: String
    public var syntax: String
    public var definition: String

    public init(
        type: String,
        syntax: String,
        definition: String
    ) {
        self.type = type
        self.syntax = syntax
        self.definition = definition
    }
}

public struct MSPAgentModelToolDefinition: Codable, Hashable, Sendable {
    public var type: String
    public var name: String
    public var description: String
    public var parameters: MSPAgentJSONValue
    public var strict: Bool
    public var format: MSPAgentFreeformToolFormat?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case description
        case parameters
        case strict
        case format
    }

    public init(
        type: String = "function",
        name: String,
        description: String,
        parameters: MSPAgentJSONValue,
        strict: Bool = true,
        format: MSPAgentFreeformToolFormat? = nil
    ) {
        self.type = type
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
        self.format = format
    }

    public init(
        name: String,
        description: String,
        format: MSPAgentFreeformToolFormat
    ) {
        self.init(
            type: "custom",
            name: name,
            description: description,
            parameters: .object([:]),
            strict: false,
            format: format
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        parameters = try container.decodeIfPresent(MSPAgentJSONValue.self, forKey: .parameters) ?? .object([:])
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict) ?? false
        format = try container.decodeIfPresent(MSPAgentFreeformToolFormat.self, forKey: .format)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        if type == "custom" {
            try container.encodeIfPresent(format, forKey: .format)
        } else {
            try container.encode(parameters, forKey: .parameters)
            try container.encode(strict, forKey: .strict)
        }
    }
}

public struct MSPAgentReasoningOptions: Codable, Hashable, Sendable {
    public var effort: String

    public init(effort: String) {
        self.effort = effort
    }
}

public struct MSPAgentTextOptions: Codable, Hashable, Sendable {
    public var verbosity: String

    public init(verbosity: String) {
        self.verbosity = verbosity
    }
}

public struct MSPAgentRequestBuilder: Sendable {
    public init() {}

    public func build(context: MSPAgentRequestBuildContext) -> MSPAgentRequestBody {
        let reasoningEffort = context.reasoningEffort
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = reasoningEffort.isEmpty
            || reasoningEffort == MSPReasoningEffort.modelDefaultValue
            ? nil
            : MSPAgentReasoningOptions(effort: reasoningEffort)
        return MSPAgentRequestBody(
            model: context.model,
            instructions: context.instructions,
            input: [
                developerMessage(for: context),
                currentUserMessage(prompt: context.prompt)
            ],
            tools: context.tools,
            toolChoice: context.toolChoice,
            parallelToolCalls: context.parallelToolCalls,
            reasoning: reasoning,
            store: context.store,
            stream: context.stream,
            include: context.include,
            promptCacheKey: context.promptCacheKey ?? defaultPromptCacheKey(for: context.tools),
            text: MSPAgentTextOptions(verbosity: context.textVerbosity)
        )
    }

    public func envelope(from body: MSPAgentRequestBody) throws -> MSPAgentRequestEnvelope {
        let payloadValue = try MSPAgentJSONValue(encoding: body)
        guard let payload = payloadValue.objectValue else {
            throw MSPAgentModelClientError.invalidStreamPayload("request body did not encode as object")
        }
        let inputValue = try MSPAgentJSONValue(encoding: body.input)
        return MSPAgentRequestEnvelope(
            payload: payload,
            input: inputValue.arrayValue ?? []
        )
    }

    public static let execCommandToolDefinition: MSPAgentModelToolDefinition = {
        let parameters = (try? JSONDecoder().decode(
            MSPAgentJSONValue.self,
            from: Data(MSPExecCommandToolSchema.parametersJSON.utf8)
        )) ?? .object([
            "type": .string("object"),
            "properties": .object([
                MSPExecCommandToolSchema.commandArgumentName: .object([
                    "type": .string("string")
                ])
            ]),
            "required": .array([.string(MSPExecCommandToolSchema.commandArgumentName)]),
            "additionalProperties": .bool(false)
        ])
        return MSPAgentModelToolDefinition(
            name: MSPExecCommandToolSchema.name,
            description: "Run a GNU/Linux-style shell command inside the active workspace.",
            parameters: parameters,
            strict: false
        )
    }()

    public static let writeStdinToolDefinition: MSPAgentModelToolDefinition = {
        let parameters = (try? JSONDecoder().decode(
            MSPAgentJSONValue.self,
            from: Data(MSPWriteStdinToolSchema.parametersJSON.utf8)
        )) ?? .object([
            "type": .string("object"),
            "properties": .object([
                MSPWriteStdinToolSchema.sessionIDArgumentName: .object([
                    "type": .string("number")
                ])
            ]),
            "required": .array([.string(MSPWriteStdinToolSchema.sessionIDArgumentName)]),
            "additionalProperties": .bool(false)
        ])
        return MSPAgentModelToolDefinition(
            name: MSPWriteStdinToolSchema.name,
            description: "Write to or poll an active exec_command session.",
            parameters: parameters,
            strict: false
        )
    }()

    public static let applyPatchToolDefinition = MSPAgentModelToolDefinition(
        name: MSPApplyPatchToolSchema.name,
        description: MSPApplyPatchToolSchema.description,
        format: MSPApplyPatchToolSchema.format()
    )

    public static let updatePlanToolDefinition = MSPAgentModelToolDefinition(
        name: MSPUpdatePlanToolSchema.name,
        description: MSPUpdatePlanToolSchema.description,
        parameters: MSPUpdatePlanToolSchema.parameters,
        strict: false
    )

    public static let defaultToolDefinitions: [MSPAgentModelToolDefinition] = [
        execCommandToolDefinition,
        writeStdinToolDefinition
    ]

    public static let codexToolDefinitions: [MSPAgentModelToolDefinition] = [
        execCommandToolDefinition,
        writeStdinToolDefinition,
        applyPatchToolDefinition
    ]

    public static func toolDefinitions(includeApplyPatch: Bool) -> [MSPAgentModelToolDefinition] {
        includeApplyPatch ? codexToolDefinitions : defaultToolDefinitions
    }

    private func developerMessage(for context: MSPAgentRequestBuildContext) -> MSPAgentInputMessage {
        MSPAgentInputMessage(
            role: "developer",
            content: context.developerContextBlocks.map { MSPAgentInputContent(text: $0) }
                + [
                    MSPAgentInputContent(text: environmentContext(context.environmentNotes)),
                    MSPAgentInputContent(text: toolPolicyContext(toolDefinitions: context.tools))
                ]
        )
    }

    private func currentUserMessage(prompt: String) -> MSPAgentInputMessage {
        MSPAgentInputMessage(
            role: "user",
            content: [MSPAgentInputContent(text: prompt)]
        )
    }

    private func toolPolicyContext(toolDefinitions: [MSPAgentModelToolDefinition]) -> String {
        let names = toolDefinitions
            .map(\.name)
            .sorted()
            .joined(separator: ", ")
        var rules = [
            "Use \(MSPExecCommandToolSchema.name) for workspace command execution when available.",
            "Use \(MSPWriteStdinToolSchema.name) with empty chars to poll a running exec_command session, or non-empty chars only when the session is interactive.",
            "Function tool arguments must match the declared schema exactly.",
            "Tool output is plain text containing command metadata and stdout/stderr, not a JSON envelope."
        ]
        if toolDefinitions.contains(where: { $0.name == MSPApplyPatchToolSchema.name }) {
            rules.append("Use \(MSPApplyPatchToolSchema.name) for UTF-8 text or code file edits when available; it is a FREEFORM patch tool, not JSON.")
        }
        if toolDefinitions.contains(where: { $0.name == MSPUpdatePlanToolSchema.name }) {
            rules.append("Use \(MSPUpdatePlanToolSchema.name) to keep task progress current when available.")
        }
        return """
        Available tools:
        \(names.isEmpty ? "(none)" : names)

        Tool contract:
        \(rules.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private func environmentContext(_ notes: [String]) -> String {
        let text = notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else {
            return "Environment notes: none."
        }
        return """
        Environment notes:
        \(text)
        """
    }

    private func defaultPromptCacheKey(for tools: [MSPAgentModelToolDefinition]) -> String {
        let names = tools.map(\.name).sorted().joined(separator: ",")
        return "model-shell-proxy-agent-v0:\(names)"
    }
}

public enum MSPAgentInstructions {
    public static let defaultInstructions = """
    You are working with a Linux workspace.
    Treat the visible workspace root as / and use the provided command tool for file and command work.
    """

    public static let defaultApplicationContext = """
    You are working in a Linux workspace.
    The visible root is /.
    Use workspace paths such as /, /notes, or /documents.
    Do not ask the user to type shell commands. Use exec_command yourself when workspace inspection or file operations are needed.
    """

    public static func defaultEnvironmentNotes(
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return [
            "Execution surface: Linux workspace.",
            "Workspace root visible to you: /",
            "Current date: \(formatter.string(from: date))",
            "Timezone: \(timeZone.identifier)"
        ]
    }
}
