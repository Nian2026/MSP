import MSPCore

struct MSPPythonCommand: MSPStreamingCommand {
    var name: String
    var summary: String?
    var runtime: any MSPPythonRuntime

    init(
        name: String,
        runtime: any MSPPythonRuntime,
        summary: String? = "Run Python inside the configured MSP interpreter runtime."
    ) {
        self.name = name
        self.runtime = runtime
        self.summary = summary
    }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.count == 1,
           (invocation.arguments[0] == "--version" || invocation.arguments[0] == "-V") {
            return .success(stdout: "Python 3.11.2\n")
        }
        let pythonInvocation = MSPPythonInvocation(
            commandName: invocation.name,
            arguments: invocation.arguments,
            rawInput: invocation.rawInput
        )
        let request: MSPPythonExecutionRequest
        do {
            request = try MSPPythonInvocationPlanner(
                invocation: pythonInvocation,
                context: context
            ).plan()
        } catch let error as MSPPythonPlanningError {
            return error.result(commandName: invocation.name)
        }
        return await runtime.runPython(
            request: request,
            context: context
        )
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.count == 1,
           (invocation.arguments[0] == "--version" || invocation.arguments[0] == "-V") {
            return .success(stdout: "Python 3.11.2\n")
        }
        let pythonInvocation = MSPPythonInvocation(
            commandName: invocation.name,
            arguments: invocation.arguments,
            rawInput: invocation.rawInput
        )
        let request: MSPPythonExecutionRequest
        do {
            request = try MSPPythonInvocationPlanner(
                invocation: pythonInvocation,
                context: context
            ).plan()
        } catch let error as MSPPythonPlanningError {
            return error.result(commandName: invocation.name)
        }
        return await runtime.runPythonStreaming(
            request: request,
            context: context
        )
    }
}
