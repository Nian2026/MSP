import Foundation

struct ExampleChatShellOutputParts: Hashable {
    var exitCode: Int?
    var wallTimeSeconds: Double?
    var output: String
    var rawOutput: String
}

enum ExampleChatShellTranscriptDisplaySupport {
    static let internalContentKind = "example_chat.workspace_shell_execution"
    private static let legacyInternalContentKind = "readex.workspace_shell_execution"

    static func internalContent(
        command: String,
        cwd: String,
        exitCode: Int?,
        wallTimeSeconds: Double?,
        output: String,
        rawOutput: String
    ) -> ExampleChatJSONValue {
        var object: [String: ExampleChatJSONValue] = [
            "kind": .string(internalContentKind),
            "command": .string(command.trimmingCharacters(in: .whitespacesAndNewlines)),
            "cwd": .string(cwd),
            "output": .string(output),
            "raw_output": .string(rawOutput)
        ]
        if let exitCode {
            object["exit_code"] = .number(Double(exitCode))
        }
        if let wallTimeSeconds {
            object["wall_time_seconds"] = .number(wallTimeSeconds)
        }
        return .object(object)
    }

    static func toolDisplayStatus(for result: ExampleChatToolResult) -> String {
        guard result.ok else { return "failed" }
        if result.name == .shell,
           let exitCode = shellOutputParts(from: result)?.exitCode,
           exitCode != 0 {
            return "failed"
        }
        return "completed"
    }

    static func shellExecution(
        for call: ExampleChatToolCall,
        cwd: String?
    ) -> AssistantSupportShellExecution? {
        guard call.name == .shell else { return nil }
        let command = shellCommand(from: call.arguments)
        guard !command.isEmpty else { return nil }
        let summary = ExampleChatWorkspaceShellTranscriptDisplaySupport.shellCommandSummary(for: command)
        return AssistantSupportShellExecution(
            command: command,
            cwd: cwd ?? shellCWD(from: call.arguments),
            kind: summary.kind,
            target: summary.target,
            query: summary.query
        )
    }

    static func commandExecution(
        for call: ExampleChatToolCall,
        cwd: String?
    ) -> AssistantSupportCommandExecution? {
        guard call.name == .shell else { return nil }
        let command = shellCommand(from: call.arguments)
        guard !command.isEmpty else { return nil }
        return AssistantSupportCommandExecution(
            id: call.id,
            callID: call.id,
            cwd: cwd ?? shellCWD(from: call.arguments),
            command: command,
            commandActions: [shellCommandAction(for: command)],
            status: "inProgress"
        )
    }

    static func shellExecution(
        for result: ExampleChatToolResult,
        existing: AssistantSupportShellExecution?
    ) -> AssistantSupportShellExecution? {
        guard result.name == .shell else { return nil }
        let internalContent = shellInternalContentObject(from: result)
        let command = internalContent?["command"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? existing?.command.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let summary = ExampleChatWorkspaceShellTranscriptDisplaySupport.shellCommandSummary(for: command)
        let parts = shellOutputParts(from: result)
        return AssistantSupportShellExecution(
            command: command,
            cwd: internalContent?["cwd"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existing?.cwd,
            kind: summary.kind,
            target: summary.target,
            query: summary.query,
            exitCode: parts?.exitCode,
            wallTimeSeconds: parts?.wallTimeSeconds,
            output: parts?.output,
            rawOutput: parts?.rawOutput
        )
    }

    static func commandExecution(
        for result: ExampleChatToolResult,
        existing: AssistantSupportCommandExecution?
    ) -> AssistantSupportCommandExecution? {
        guard result.name == .shell else { return nil }
        let internalContent = shellInternalContentObject(from: result)
        let command = internalContent?["command"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? existing?.command.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !command.isEmpty else { return nil }
        let parts = shellOutputParts(from: result)
        return AssistantSupportCommandExecution(
            id: existing?.id ?? result.callID,
            callID: result.callID,
            cwd: internalContent?["cwd"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existing?.cwd,
            command: command,
            commandActions: [shellCommandAction(for: command)],
            aggregatedOutput: parts?.output,
            exitCode: parts?.exitCode,
            status: toolDisplayStatus(for: result),
            wallTimeSeconds: parts?.wallTimeSeconds
        )
    }

    static func shellCommandAction(for command: String) -> AssistantSupportCommandAction {
        return AssistantSupportCommandAction(
            type: "unknown",
            command: command,
            name: nil,
            path: nil,
            query: nil
        )
    }

    static func shellCommand(from arguments: [String: ExampleChatJSONValue]) -> String {
        arguments["cmd"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    static func shellStartedStatusText(for call: ExampleChatToolCall) -> String {
        shellStatusText(isCompleted: false, isFailed: false)
    }

    static func shellCompletedStatusText(
        for result: ExampleChatToolResult,
        existing: AssistantSupportShellExecution? = nil
    ) -> String {
        shellStatusText(
            isCompleted: true,
            isFailed: toolDisplayStatus(for: result) == "failed"
        )
    }

    static func shellStatusText(isCompleted: Bool, isFailed: Bool) -> String {
        if isFailed {
            return "工作区命令执行失败"
        }
        return isCompleted ? "已执行工作区命令" : "正在执行工作区命令"
    }

    static func shellInternalContentObject(from result: ExampleChatToolResult) -> [String: ExampleChatJSONValue]? {
        guard result.name == .shell,
              let object = result.internalContent?.objectValue,
              shellInternalContentKindIsSupported(object["kind"]?.stringValue) else {
            return nil
        }
        return object
    }

    private static func shellInternalContentKindIsSupported(_ kind: String?) -> Bool {
        let normalized = kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized == internalContentKind || normalized == legacyInternalContentKind
    }

    static func shellOutputParts(from result: ExampleChatToolResult) -> ExampleChatShellOutputParts? {
        if let object = shellInternalContentObject(from: result) {
            let rawOutput = object["raw_output"]?.stringValue
                ?? result.content?.stringValue
                ?? ""
            return ExampleChatShellOutputParts(
                exitCode: object["exit_code"]?.intValue,
                wallTimeSeconds: object["wall_time_seconds"]?.doubleValue,
                output: object["output"]?.stringValue ?? "",
                rawOutput: rawOutput
            )
        }
        return shellOutputParts(from: result.content?.stringValue)
    }

    static func shellOutputParts(from rawValue: String?) -> ExampleChatShellOutputParts? {
        guard let rawOutput = rawValue,
              !rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ExampleChatShellOutputParts(
            exitCode: nil,
            wallTimeSeconds: nil,
            output: rawOutput,
            rawOutput: rawOutput
        )
    }

    private static func shellCWD(from arguments: [String: ExampleChatJSONValue]) -> String? {
        let cwd = arguments["cwd"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return cwd.isEmpty ? nil : cwd
    }
}
