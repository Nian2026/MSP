import Foundation
import MSPCore

public struct MSPCommandCommand: MSPCommand {
    public let name = "command"
    public let summary: String? = "Execute or look up a command while bypassing shell functions."

    private let spec = MSPPOSIXCommandSpec(
        name: "command",
        allowedShortOptions: ["p", "v", "V"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed: MSPPOSIXParsedArguments
        do {
            parsed = try spec.parse(invocation.arguments, stopAtFirstOperand: true)
        } catch let failure as MSPCommandFailure {
            throw mspPOSIXCommandOptionFailure(failure)
        }
        let lookup = parsed.options.contains { $0.matches(short: "v") }
        let describe = parsed.options.contains { $0.matches(short: "V") }
        guard let target = parsed.operands.first else {
            return .success()
        }
        if lookup || describe {
            let visible = Set(context.availableCommandNames)
            let output: MSPPOSIXCommandLookupOutput = describe ? .description : .commandLookup
            var stdoutRows: [String] = []
            var stderrRows: [String] = []
            var missing = false
            for operand in parsed.operands {
                let rows = mspPOSIXLookupRows(
                    for: operand,
                    availableCommandNames: visible,
                    commandLookupPaths: context.commandLookupPaths,
                    environmentPath: context.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
                    includeBuiltins: true,
                    showAll: false,
                    output: output
                )
                if rows.isEmpty {
                    missing = true
                    if describe {
                        stderrRows.append("command: \(operand): not found")
                    }
                } else {
                    stdoutRows.append(contentsOf: rows)
                }
            }
            return MSPCommandResult(
                stdout: stdoutRows.isEmpty ? "" : stdoutRows.joined(separator: "\n") + "\n",
                stderr: stderrRows.isEmpty ? "" : mspPOSIXBashShellDiagnosticStderr(
                    stderrRows.joined(separator: "\n") + "\n",
                    invocation: invocation
                ),
                exitCode: missing ? 1 : 0
            )
        }
        let result = await context.runSubcommand(
            name: target,
            arguments: Array(parsed.operands.dropFirst()),
            rawInput: parsed.operands.map(mspPOSIXShellQuote).joined(separator: " "),
            standardInput: context.standardInput
        )
        guard result.exitCode == 127,
              result.stderr == "\(target): command not found\n" else {
            return result
        }
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderr: mspPOSIXBashShellDiagnosticStderr(result.stderr, invocation: invocation),
            exitCode: result.exitCode,
            stateChange: result.stateChange
        )
    }
}

public struct MSPBuiltinCommand: MSPCommand {
    public let name = "builtin"
    public let summary: String? = "Execute a shell builtin command."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var operands = invocation.arguments
        if operands.first == "--" {
            operands.removeFirst()
        }
        guard let target = operands.first else {
            return .success()
        }
        guard mspPOSIXShellBuiltinNames.contains(target) else {
            return .failure(stderr: mspPOSIXBashShellDiagnosticStderr(
                "builtin: \(target): not a shell builtin\n",
                invocation: invocation
            ))
        }
        return await context.runSubcommand(
            name: target,
            arguments: Array(operands.dropFirst()),
            rawInput: operands.map(mspPOSIXShellQuote).joined(separator: " "),
            standardInput: context.standardInput
        )
    }
}

public struct MSPEnvCommand: MSPCommand {
    public let name = "env"
    public let summary: String? = "Print or run with a modified environment."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var arguments = invocation.arguments
        var environment = context.environment
        var environmentOrder = context.environment.keys.sorted()
        var nullTerminated = false
        var newDirectory: String?
        var index = 0
        var parsingOptions = true
        while index < arguments.count {
            let argument = arguments[index]
            if parsingOptions, argument == "--" {
                parsingOptions = false
                index += 1
                continue
            }

            if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
                if argument == "--help" {
                    return .success(stdout: mspPOSIXEnvHelpText())
                }
                if argument == "--version" {
                    return .success(stdout: "env (MSP coreutils-compatible) 9.1\n")
                }
                if argument == "--ignore-environment" {
                    environment.removeAll()
                    environmentOrder.removeAll()
                    index += 1
                    continue
                }
                if argument == "--null" {
                    nullTerminated = true
                    index += 1
                    continue
                }
                if argument == "--chdir" {
                    guard index + 1 < arguments.count else {
                        return mspPOSIXEnvFailure(
                            "env: option '--chdir' requires an argument\n\(mspPOSIXEnvHelpHint())"
                        )
                    }
                    newDirectory = arguments[index + 1]
                    index += 2
                    continue
                }
                if argument.hasPrefix("--chdir=") {
                    newDirectory = String(argument.dropFirst("--chdir=".count))
                    index += 1
                    continue
                }
                if argument == "--split-string" {
                    guard index + 1 < arguments.count else {
                        return mspPOSIXEnvFailure(
                            "env: option '--split-string' requires an argument\n\(mspPOSIXEnvHelpHint())"
                        )
                    }
                    arguments = mspPOSIXEnvSplitString(arguments[index + 1]) + Array(arguments.dropFirst(index + 2))
                    index = 0
                    parsingOptions = true
                    continue
                }
                if argument.hasPrefix("--split-string=") {
                    arguments = mspPOSIXEnvSplitString(String(argument.dropFirst("--split-string=".count))) + Array(arguments.dropFirst(index + 1))
                    index = 0
                    parsingOptions = true
                    continue
                }
                if argument == "--unset" {
                    guard index + 1 < arguments.count else {
                        return mspPOSIXEnvFailure(
                            "env: option '--unset' requires an argument\n\(mspPOSIXEnvHelpHint())"
                        )
                    }
                    mspPOSIXEnvRemove(arguments[index + 1], from: &environment, order: &environmentOrder)
                    index += 2
                    continue
                }
                if argument.hasPrefix("--unset=") {
                    mspPOSIXEnvRemove(
                        String(argument.dropFirst("--unset=".count)),
                        from: &environment,
                        order: &environmentOrder
                    )
                    index += 1
                    continue
                }
                return mspPOSIXEnvFailure(
                    "env: unrecognized option '\(argument)'\n\(mspPOSIXEnvHelpHint())"
                )
            }

            if parsingOptions, argument.hasPrefix("-"), argument != "-" {
                let characters = Array(argument.dropFirst())
                var characterIndex = 0
                var restartedArguments = false
                while characterIndex < characters.count {
                    switch characters[characterIndex] {
                    case "i":
                        environment.removeAll()
                        environmentOrder.removeAll()
                        characterIndex += 1
                    case "0":
                        nullTerminated = true
                        characterIndex += 1
                    case "C":
                        let directory: String
                        if characterIndex + 1 < characters.count {
                            directory = String(characters[(characterIndex + 1)...])
                        } else {
                            guard index + 1 < arguments.count else {
                                return mspPOSIXEnvFailure(
                                    "env: option requires an argument -- 'C'\n\(mspPOSIXEnvHelpHint())"
                                )
                            }
                            index += 1
                            directory = arguments[index]
                        }
                        newDirectory = directory
                        characterIndex = characters.count
                    case "u":
                        let name: String
                        if characterIndex + 1 < characters.count {
                            name = String(characters[(characterIndex + 1)...])
                        } else {
                            guard index + 1 < arguments.count else {
                                return mspPOSIXEnvFailure(
                                    "env: option requires an argument -- 'u'\n\(mspPOSIXEnvHelpHint())"
                                )
                            }
                            index += 1
                            name = arguments[index]
                        }
                        mspPOSIXEnvRemove(name, from: &environment, order: &environmentOrder)
                        characterIndex = characters.count
                    case "S":
                        let splitString: String
                        let consumedArguments: Int
                        if characterIndex + 1 < characters.count {
                            splitString = String(characters[(characterIndex + 1)...])
                            consumedArguments = 1
                        } else {
                            guard index + 1 < arguments.count else {
                                return mspPOSIXEnvFailure(
                                    "env: option requires an argument -- 'S'\n\(mspPOSIXEnvHelpHint())"
                                )
                            }
                            splitString = arguments[index + 1]
                            consumedArguments = 2
                        }
                        arguments = mspPOSIXEnvSplitString(splitString) + Array(arguments.dropFirst(index + consumedArguments))
                        index = 0
                        characterIndex = characters.count
                        parsingOptions = true
                        restartedArguments = true
                    case let option:
                        return mspPOSIXEnvFailure(
                            "env: invalid option -- '\(option)'\n\(mspPOSIXEnvHelpHint())"
                        )
                    }
                }
                if restartedArguments {
                    continue
                }
                index += 1
                continue
            }

            if parsingOptions, argument == "-" {
                environment.removeAll()
                environmentOrder.removeAll()
                index += 1
                continue
            }

            if let assignment = mspPOSIXEnvironmentAssignment(argument) {
                mspPOSIXEnvSet(
                    name: assignment.name,
                    value: assignment.value,
                    environment: &environment,
                    order: &environmentOrder
                )
                index += 1
                continue
            }
            break
        }

        let remaining = Array(arguments.dropFirst(index))
        if newDirectory != nil, remaining.isEmpty {
            return mspPOSIXEnvFailure(
                "env: must specify command with --chdir (-C)\n\(mspPOSIXEnvHelpHint())"
            )
        }
        guard let target = remaining.first else {
            return printEnvironment(environment, order: environmentOrder, nullTerminated: nullTerminated)
        }
        if nullTerminated {
            return mspPOSIXEnvFailure(
                "env: cannot specify --null (-0) with command\n\(mspPOSIXEnvHelpHint())"
            )
        }
        guard mspPOSIXEnvCanExecute(target, context: context, environment: environment) else {
            return .failure(
                exitCode: 127,
                stderr: "env: \(MSPPOSIXCommandSupport.gnuQuote(target)): No such file or directory\n"
            )
        }
        let commandDirectory: String
        if let newDirectory {
            do {
                commandDirectory = try mspPOSIXEnvResolvedDirectory(newDirectory, context: context)
            } catch {
                return .failure(
                    exitCode: 125,
                    stderr: "env: cannot change directory to \(MSPPOSIXCommandSupport.gnuQuote(newDirectory)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                )
            }
        } else {
            commandDirectory = context.currentDirectory
        }
        if target == "env", remaining.count == 1 {
            return printEnvironment(environment, order: environmentOrder, nullTerminated: false)
        }
        let rawInput = mspPOSIXShellBuiltinNames.contains(target)
            ? ""
            : remaining.map(mspPOSIXShellQuote).joined(separator: " ")
        return await mspPOSIXRunEnvSubcommand(
            context: context,
            name: target,
            arguments: Array(remaining.dropFirst()),
            rawInput: rawInput,
            standardInput: context.standardInput,
            environment: environment,
            currentDirectory: commandDirectory
        )
    }

    private func printEnvironment(
        _ environment: [String: String],
        order: [String],
        nullTerminated: Bool
    ) -> MSPCommandResult {
        let separator = nullTerminated ? "\0" : "\n"
        var seen: Set<String> = []
        let orderedKeys = order.filter { key in
            guard environment[key] != nil, !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        } + environment.keys.sorted().filter { !seen.contains($0) }
        let output = orderedKeys.map { "\($0)=\(environment[$0] ?? "")" }
        return .success(stdout: output.isEmpty ? "" : output.joined(separator: separator) + separator)
    }
}

private func mspPOSIXEnvResolvedDirectory(_ directory: String, context: MSPCommandContext) throws -> String {
    let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: "env")
    let resolved = try fileSystem.resolve(directory, from: context.currentDirectory)
    let info = try fileSystem.stat(resolved.virtualPath, from: "/")
    guard info.isDirectory else {
        throw MSPWorkspaceFileSystemError.notDirectory(resolved.virtualPath)
    }
    return resolved.virtualPath
}

private func mspPOSIXRunEnvSubcommand(
    context: MSPCommandContext,
    name: String,
    arguments: [String],
    rawInput: String,
    standardInput: Data,
    environment: [String: String],
    currentDirectory: String
) async -> MSPCommandResult {
    guard let subcommandRunner = context.subcommandRunner else {
        return .failure(exitCode: 125, stderr: "\(name): subcommand execution is not available\n")
    }
    var childContext = context
    childContext.currentDirectory = currentDirectory
    childContext.standardInput = standardInput
    childContext.standardInputClosed = false
    childContext.environment = environment
    return await subcommandRunner(
        MSPCommandInvocation(name: name, arguments: arguments, rawInput: rawInput),
        childContext
    )
}

private func mspPOSIXEnvironmentAssignment(_ value: String) -> (name: String, value: String)? {
    guard let equals = value.firstIndex(of: "=") else {
        return nil
    }
    let name = String(value[..<equals])
    return (name, String(value[value.index(after: equals)...]))
}

private func mspPOSIXEnvSplitString(_ value: String) -> [String] {
    enum QuoteMode {
        case none
        case single
        case double
    }

    var arguments: [String] = []
    var current = ""
    var quoteMode = QuoteMode.none
    var iterator = value.makeIterator()

    while let character = iterator.next() {
        switch (character, quoteMode) {
        case ("'", .none):
            quoteMode = .single
        case ("'", .single):
            quoteMode = .none
        case ("\"", .none):
            quoteMode = .double
        case ("\"", .double):
            quoteMode = .none
        case ("\\", .none), ("\\", .double):
            if let escaped = iterator.next() {
                current.append(escaped)
            } else {
                current.append(character)
            }
        case (_, .none) where character.isWhitespace:
            if !current.isEmpty {
                arguments.append(current)
                current.removeAll()
            }
        default:
            current.append(character)
        }
    }

    if !current.isEmpty {
        arguments.append(current)
    }
    return arguments
}

func mspPOSIXShellQuote(_ value: String) -> String {
    if mspPOSIXShellQuoteIsSafe(value) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func mspPOSIXShellQuotedLength(_ value: String) -> Int {
    if mspPOSIXShellQuoteIsSafe(value) {
        return value.utf8.count
    }
    var apostropheCount = 0
    for byte in value.utf8 where byte == 0x27 {
        apostropheCount += 1
    }
    return value.utf8.count + 2 + apostropheCount * 3
}

private func mspPOSIXShellQuoteIsSafe(_ value: String) -> Bool {
    guard !value.isEmpty else {
        return false
    }
    return value.utf8.allSatisfy { byte in
        (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x40
            || byte == 0x25
            || byte == 0x2B
            || byte == 0x3D
            || byte == 0x3A
            || byte == 0x2C
            || byte == 0x2E
            || byte == 0x2F
            || byte == 0x2D
            || byte == 0x5F
    }
}

private func mspPOSIXEnvCanExecute(
    _ target: String,
    context: MSPCommandContext,
    environment: [String: String]
) -> Bool {
    !mspPOSIXLookupRows(
        for: target,
        availableCommandNames: Set(context.availableCommandNames),
        commandLookupPaths: context.commandLookupPaths,
        environmentPath: environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
        includeBuiltins: false,
        showAll: false,
        output: .path
    ).isEmpty
}

private func mspPOSIXEnvSet(
    name: String,
    value: String,
    environment: inout [String: String],
    order: inout [String]
) {
    if environment[name] == nil {
        order.append(name)
    }
    environment[name] = value
}

private func mspPOSIXEnvRemove(
    _ name: String,
    from environment: inout [String: String],
    order: inout [String]
) {
    environment.removeValue(forKey: name)
    order.removeAll { $0 == name }
}

private func mspPOSIXEnvFailure(_ stderr: String) -> MSPCommandResult {
    .failure(exitCode: 125, stderr: stderr)
}

private func mspPOSIXEnvHelpHint() -> String {
    "Try 'env --help' for more information.\n"
}

private func mspPOSIXEnvHelpText() -> String {
    """
    Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]
    Set each NAME to VALUE in the environment and run COMMAND.

      -i, --ignore-environment  start with an empty environment
      -0, --null           end each output line with NUL, not newline
      -u, --unset=NAME     remove variable from the environment
      -C, --chdir=DIR      change working directory to DIR
      -S, --split-string=S  process and split S into separate arguments
      -v, --debug          print verbose information for each processing step
          --help           display this help and exit
          --version        output version information and exit

    A mere - implies -i.  If no COMMAND, print the resulting environment.

    """
}

private func mspPOSIXCommandOptionFailure(_ failure: MSPCommandFailure) -> MSPCommandFailure {
    let prefix = "command: unsupported option -- "
    guard failure.result.stderr.hasPrefix(prefix) else {
        return failure
    }
    let option = String(failure.result.stderr.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return MSPCommandFailure(
        result: .failure(
            exitCode: 2,
            stderr: "command: \(option.count == 1 ? "-\(option)" : "--"): invalid option\ncommand: usage: command [-pVv] command [arg ...]\n"
        )
    )
}
