import Foundation
import MSPCore

public struct MSPShCommand: MSPCommand {
    public let name = "sh"
    public let summary: String? = "Run a command string with the MSP shell interpreter."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: mspShHelpText())
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "sh (MSP shell-compatible) 0.1\n")
        }
        guard let commandLineRunner = context.commandLineRunner else {
            return .failure(exitCode: 125, stderr: "sh: MSP command runner is unavailable\n")
        }

        let parsed = mspShParse(invocation.arguments)
        if let failure = parsed.failure {
            return failure
        }

        let script: String
        if let command = parsed.command {
            script = command
        } else if let stream = context.standardInputStream {
            script = try await mspShReadAll(stream: stream)
        } else {
            script = String(decoding: context.standardInput, as: UTF8.self)
        }

        var childContext = context
        childContext.standardInput = Data()
        childContext.standardInputClosed = true
        childContext.standardInputStream = nil
        return await commandLineRunner(script, childContext)
    }
}

private struct MSPShParseResult {
    var command: String?
    var failure: MSPCommandResult?
}

private func mspShParse(_ arguments: [String]) -> MSPShParseResult {
    var index = 0
    var scansOptions = true
    while index < arguments.count {
        let argument = arguments[index]
        if scansOptions, argument == "--" {
            scansOptions = false
            index += 1
            continue
        }
        if scansOptions, argument == "-c" {
            guard index + 1 < arguments.count else {
                return MSPShParseResult(
                    failure: .failure(exitCode: 2, stderr: "sh: -c requires an argument\n")
                )
            }
            return MSPShParseResult(command: arguments[index + 1])
        }
        if scansOptions, argument.hasPrefix("-"), argument != "-" {
            let options = Array(argument.dropFirst())
            if options.contains("c") {
                guard index + 1 < arguments.count else {
                    return MSPShParseResult(
                        failure: .failure(exitCode: 2, stderr: "sh: -c requires an argument\n")
                    )
                }
                return MSPShParseResult(command: arguments[index + 1])
            }
            index += 1
            continue
        }
        break
    }
    return MSPShParseResult()
}

private func mspShReadAll(stream: any MSPCommandInputStream) async throws -> String {
    var data = Data()
    while let chunk = try await stream.read(maxBytes: 32 * 1024) {
        data.append(chunk)
    }
    return String(decoding: data, as: UTF8.self)
}

private func mspShHelpText() -> String {
    """
    Usage: sh [OPTION]... [-c COMMAND]
    Execute COMMAND with the MSP shell interpreter, or read commands from stdin.

    """
}
