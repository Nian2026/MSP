import Foundation

public enum MSPShellParserError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyInput
    case syntax(exitCode: Int, message: String)
    case unsupportedExecutionForm(String)

    public var description: String {
        switch self {
        case .emptyInput:
            return "empty command"
        case .syntax(_, let message):
            return message
        case .unsupportedExecutionForm(let message):
            return message
        }
    }
}

public struct MSPShellParser: Sendable {
    public init() {}

    public func parse(_ input: String) throws -> MSPParsedShellScript {
        let script = try parseScript(input)
        return MSPShellASTToParsedConversion.parsedShellScript(
            from: script,
            rawInput: input
        )
    }

    public func parseExecutableInvocation(_ input: String) throws -> MSPParsedCommandLine {
        let pipelines = try parseExecutablePipelines(input)
        guard pipelines.count == 1,
              let pipeline = pipelines.first,
              pipeline.leadingOperator == nil,
              !pipeline.isNegated,
              pipeline.commands.count == 1,
              pipeline.pipeOperators.isEmpty,
              let command = pipeline.commands.first else {
            throw MSPShellParserError.unsupportedExecutionForm(
                "shell: execution for this shell form is not implemented yet"
            )
        }
        return command
    }

    public func parseExecutableInvocations(_ input: String) throws -> [MSPParsedCommandLine] {
        try parseExecutablePipelines(input).flatMap(\.commands)
    }

    public func parseExecutablePipelines(_ input: String) throws -> [MSPParsedCommandPipeline] {
        try parseExecutablePipelines(input, enablesExtendedGlob: true)
    }

    public func parseExecutablePipelines(
        _ input: String,
        enablesExtendedGlob: Bool
    ) throws -> [MSPParsedCommandPipeline] {
        let script = try parseScript(input, enablesExtendedGlob: enablesExtendedGlob)
        do {
            return try MSPShellASTToParsedConversion.parsedCommandPipelines(from: script)
        } catch MSPShellParsedCommandConversionError.emptyInput {
            throw MSPShellParserError.emptyInput
        }
    }

    private func parseScript(
        _ input: String,
        enablesExtendedGlob: Bool = true
    ) throws -> ShellScript {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MSPShellParserError.emptyInput
        }
        do {
            return try ShellScriptParser.script(
                from: input,
                grammar: MSPShellGrammar.msp.withExtendedGlob(enablesExtendedGlob)
            )
        } catch let exit as ShellExit {
            throw MSPShellParserError.syntax(exitCode: exit.code, message: exit.message)
        } catch {
            throw MSPShellParserError.syntax(exitCode: 2, message: String(describing: error))
        }
    }
}
