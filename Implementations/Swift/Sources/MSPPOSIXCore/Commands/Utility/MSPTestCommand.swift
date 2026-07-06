import MSPCore

public struct MSPTestCommand: MSPCommand {
    public let name: String
    public let summary: String? = "Evaluate simple shell test expressions."

    public init(name: String = "test") {
        self.name = name
    }

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var arguments = invocation.arguments
        if name == "[" {
            guard arguments.last == "]" else {
                throw MSPCommandFailure.usage(mspPOSIXBashShellDiagnosticStderr(
                    "[: missing `]'\n",
                    invocation: invocation
                ))
            }
            arguments.removeLast()
        }
        if name == "[[" {
            guard arguments.last == "]]" else {
                throw MSPCommandFailure.usage(mspPOSIXBashShellDiagnosticStderr(
                    "[[: missing `]]'\n",
                    invocation: invocation
                ))
            }
            arguments.removeLast()
        }

        do {
            let result = try evaluate(arguments, context: context, patternMatching: name == "[[")
            return MSPCommandResult(exitCode: result ? 0 : 1)
        } catch let failure as MSPCommandFailure {
            throw MSPCommandFailure(result: MSPCommandResult(
                stdoutData: failure.result.stdoutData,
                stderr: mspPOSIXBashShellDiagnosticStderr(failure.result.stderr, invocation: invocation),
                exitCode: failure.result.exitCode,
                stateChange: failure.result.stateChange
            ))
        } catch {
            throw MSPCommandFailure.usage(mspPOSIXBashShellDiagnosticStderr(
                "\(name): invalid expression\n",
                invocation: invocation
            ))
        }
    }

    private func evaluate(
        _ arguments: [String],
        context: MSPCommandContext,
        patternMatching: Bool
    ) throws -> Bool {
        if arguments.count > 3 {
            var parser = MSPTestExpressionParser(
                commandName: name,
                arguments: arguments,
                context: context,
                patternMatching: patternMatching,
                evaluator: self
            )
            return try parser.parse()
        }
        switch arguments.count {
        case 0:
            return false
        case 1:
            return !arguments[0].isEmpty
        case 2:
            if arguments[0] == "!" {
                return !arguments[1].isEmpty
            }
            return try evaluateUnary(operatorName: arguments[0], operand: arguments[1], context: context)
        case 3:
            if arguments[0] == "!" {
                return try !evaluate(Array(arguments.dropFirst()), context: context, patternMatching: patternMatching)
            }
            return try evaluateBinary(
                arguments[0],
                operatorName: arguments[1],
                rhs: arguments[2],
                context: context,
                patternMatching: patternMatching
            )
        default:
            throw MSPCommandFailure.usage("\(name): too many arguments\n")
        }
    }

    private func evaluateUnary(
        operatorName: String,
        operand: String,
        context: MSPCommandContext
    ) throws -> Bool {
        switch operatorName {
        case "-n":
            return !operand.isEmpty
        case "-z":
            return operand.isEmpty
        case "-a", "-b", "-c", "-e", "-f", "-d", "-g", "-G", "-h", "-k", "-L", "-N", "-O", "-p", "-r", "-s", "-S", "-t", "-u", "-w", "-x":
            if operatorName == "-t" {
                return false
            }
            if (operatorName == "-r" || operatorName == "-x"),
               isVirtualExecutablePath(operand, context: context) {
                return true
            }
            guard let fileSystem = context.workspace?.fileSystem else {
                return false
            }
            if operatorName == "-L" || operatorName == "-h" {
                do {
                    _ = try fileSystem.readSymbolicLink(operand, from: context.currentDirectory)
                    return true
                } catch {
                    return false
                }
            }
            do {
                let info = try fileSystem.stat(operand, from: context.currentDirectory)
                switch operatorName {
                case "-a", "-e":
                    return true
                case "-b", "-c", "-p", "-S":
                    return false
                case "-f":
                    return info.type == .regularFile
                case "-d":
                    return info.type == .directory
                case "-g":
                    return mspTestPermissionAllows(info.permissions, mask: 0o2000, defaultValue: false)
                case "-G", "-O":
                    return false
                case "-k":
                    return mspTestPermissionAllows(info.permissions, mask: 0o1000, defaultValue: false)
                case "-N":
                    return false
                case "-s":
                    return (info.size ?? 0) > 0
                case "-r":
                    return mspTestPermissionAllows(info.permissions, mask: 0o444, defaultValue: true)
                case "-u":
                    return mspTestPermissionAllows(info.permissions, mask: 0o4000, defaultValue: false)
                case "-w":
                    return mspTestPermissionAllows(info.permissions, mask: 0o222, defaultValue: true)
                case "-x":
                    return mspTestPermissionAllows(info.permissions, mask: 0o111, defaultValue: false)
                default:
                    return false
                }
            } catch {
                return false
            }
        default:
            throw MSPCommandFailure.usage("\(name): \(operatorName): unary operator expected\n")
        }
    }

    fileprivate func evaluateBinary(
        _ lhs: String,
        operatorName: String,
        rhs: String,
        context: MSPCommandContext? = nil,
        patternMatching: Bool
    ) throws -> Bool {
        switch operatorName {
        case "=", "==":
            if patternMatching {
                return mspCore100GlobMatch(lhs, pattern: rhs)
            }
            return lhs == rhs
        case "!=":
            if patternMatching {
                return !mspCore100GlobMatch(lhs, pattern: rhs)
            }
            return lhs != rhs
        case "<":
            return lhs < rhs
        case ">":
            return lhs > rhs
        case "-eq", "-ne", "-gt", "-ge", "-lt", "-le":
            guard let lhsValue = Int(lhs), let rhsValue = Int(rhs) else {
                let badValue = Int(lhs) == nil ? lhs : rhs
                throw MSPCommandFailure.usage("\(name): \(badValue): integer expression expected\n")
            }
            switch operatorName {
            case "-eq":
                return lhsValue == rhsValue
            case "-ne":
                return lhsValue != rhsValue
            case "-gt":
                return lhsValue > rhsValue
            case "-ge":
                return lhsValue >= rhsValue
            case "-lt":
                return lhsValue < rhsValue
            case "-le":
                return lhsValue <= rhsValue
            default:
                return false
            }
        case "-nt", "-ot", "-ef":
            guard let context else {
                return false
            }
            return evaluateFileComparison(lhs, operatorName: operatorName, rhs: rhs, context: context)
        default:
            throw MSPCommandFailure.usage("\(name): \(operatorName): binary operator expected\n")
        }
    }

    fileprivate func evaluateUnaryForParser(
        operatorName: String,
        operand: String,
        context: MSPCommandContext
    ) throws -> Bool {
        try evaluateUnary(operatorName: operatorName, operand: operand, context: context)
    }

    private func evaluateFileComparison(
        _ lhs: String,
        operatorName: String,
        rhs: String,
        context: MSPCommandContext
    ) -> Bool {
        guard let fileSystem = context.workspace?.fileSystem else {
            return false
        }
        do {
            let lhsInfo = try fileSystem.stat(lhs, from: context.currentDirectory)
            let rhsInfo = try fileSystem.stat(rhs, from: context.currentDirectory)
            switch operatorName {
            case "-ef":
                let lhsPath = MSPWorkspacePathResolver.normalize(lhs, from: context.currentDirectory)
                let rhsPath = MSPWorkspacePathResolver.normalize(rhs, from: context.currentDirectory)
                return lhsPath == rhsPath
            case "-nt":
                guard let lhsDate = lhsInfo.modificationDate, let rhsDate = rhsInfo.modificationDate else {
                    return false
                }
                return lhsDate > rhsDate
            case "-ot":
                guard let lhsDate = lhsInfo.modificationDate, let rhsDate = rhsInfo.modificationDate else {
                    return false
                }
                return lhsDate < rhsDate
            default:
                return false
            }
        } catch {
            return false
        }
    }

    private func isVirtualExecutablePath(_ operand: String, context: MSPCommandContext) -> Bool {
        let normalized = MSPWorkspacePathResolver.normalize(operand, from: context.currentDirectory)
        let executablePrefix: String
        switch normalized {
        case let path where path.hasPrefix("/usr/local/bin/"):
            executablePrefix = "/usr/local/bin/"
        case let path where path.hasPrefix("/usr/bin/"):
            executablePrefix = "/usr/bin/"
        case let path where path.hasPrefix("/bin/"):
            executablePrefix = "/bin/"
        default:
            return false
        }
        let executable = String(normalized.dropFirst(executablePrefix.count))
        guard !executable.isEmpty, !executable.contains("/") else {
            return false
        }
        return Set(context.availableCommandNames).contains(executable)
    }
}

private struct MSPTestExpressionParser {
    var commandName: String
    var arguments: [String]
    var context: MSPCommandContext
    var patternMatching: Bool
    var evaluator: MSPTestCommand
    var index = 0

    mutating func parse() throws -> Bool {
        let value = try parseOr()
        guard index == arguments.count else {
            throw MSPCommandFailure.usage("\(commandName): syntax error: `\(arguments[index])' unexpected\n")
        }
        return value
    }

    private mutating func parseOr() throws -> Bool {
        var value = try parseAnd()
        while match("-o") {
            let rhs = try parseAnd()
            value = value || rhs
        }
        return value
    }

    private mutating func parseAnd() throws -> Bool {
        var value = try parseTerm()
        while match("-a") {
            let rhs = try parseTerm()
            value = value && rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Bool {
        if match("!") {
            return try !parseTerm()
        }
        if match("(") {
            let value = try parseOr()
            guard match(")") else {
                throw MSPCommandFailure.usage("\(commandName): `)' expected\n")
            }
            return value
        }
        guard index < arguments.count else {
            throw MSPCommandFailure.usage("\(commandName): argument expected\n")
        }

        if index + 1 < arguments.count,
           mspTestUnaryOperators.contains(arguments[index]) {
            let operatorName = arguments[index]
            let operand = arguments[index + 1]
            index += 2
            return try evaluator.evaluateUnaryForParser(
                operatorName: operatorName,
                operand: operand,
                context: context
            )
        }

        if index + 2 < arguments.count,
           mspTestBinaryOperators.contains(arguments[index + 1]) {
            let lhs = arguments[index]
            let operatorName = arguments[index + 1]
            let rhs = arguments[index + 2]
            index += 3
            return try evaluator.evaluateBinary(
                lhs,
                operatorName: operatorName,
                rhs: rhs,
                context: context,
                patternMatching: patternMatching
            )
        }

        let value = arguments[index]
        index += 1
        return !value.isEmpty
    }

    private mutating func match(_ token: String) -> Bool {
        guard index < arguments.count, arguments[index] == token else {
            return false
        }
        index += 1
        return true
    }
}

private let mspTestUnaryOperators: Set<String> = [
    "-a", "-b", "-c", "-d", "-e", "-f", "-g", "-G", "-h", "-k", "-L", "-N",
    "-O", "-p", "-r", "-s", "-S", "-t", "-u", "-w", "-x", "-n", "-z"
]

private let mspTestBinaryOperators: Set<String> = [
    "=", "==", "!=", "<", ">", "-eq", "-ne", "-gt", "-ge", "-lt", "-le",
    "-ef", "-nt", "-ot"
]

private func mspTestPermissionAllows(
    _ permissions: UInt16?,
    mask: UInt16,
    defaultValue: Bool
) -> Bool {
    guard let permissions else {
        return defaultValue
    }
    return permissions & mask != 0
}
