import MSPCore

struct MSPPythonInvocationPlanner {
    var invocation: MSPPythonInvocation
    var context: MSPCommandContext

    func plan() throws -> MSPPythonExecutionRequest {
        let entrypoint: MSPPythonEntrypoint
        switch try MSPPythonOptionParser.launcherEntrypoint(in: invocation.arguments) {
        case .command(let source, let arguments):
            entrypoint = .command(source: source, arguments: arguments)
        case .module(let name, let arguments):
            entrypoint = .module(name: name, arguments: arguments)
        case .script(let operand, let arguments):
            entrypoint = .script(
                path: MSPPythonScriptPath(
                    originalOperand: operand,
                    virtualPath: try virtualScriptPath(for: operand)
                ),
                arguments: arguments
            )
        case .standardInput(let arguments):
            entrypoint = .standardInput(arguments: arguments)
        case .interactive(let arguments):
            entrypoint = .interactive(arguments: arguments)
        }
        return MSPPythonExecutionRequest(
            invocation: invocation,
            entrypoint: entrypoint,
            virtualCurrentDirectory: MSPWorkspacePathResolver.normalize(context.currentDirectory)
        )
    }

    private func virtualScriptPath(for operand: String) throws -> String {
        if let workspace = context.workspace {
            return try workspace.fileSystem.resolve(
                operand,
                from: context.currentDirectory
            ).virtualPath
        }
        return MSPWorkspacePathResolver.normalize(operand, from: context.currentDirectory)
    }
}

public enum MSPPythonPlanningError: Error, Sendable, Equatable {
    case optionRequiresArgument(String)

    func result(commandName: String) -> MSPCommandResult {
        switch self {
        case .optionRequiresArgument(let option):
            return .failure(
                exitCode: 1,
                stderr: "\(commandName): option \(option) requires an argument\n"
            )
        }
    }
}
