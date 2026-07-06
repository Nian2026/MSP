import Foundation
import MSPCore

extension ShellScriptReentryRuntime {
    func shellLauncherInvocation(
        commandName: String,
        shellLauncherName: String,
        arguments: [String],
        standardInput: Data,
        standardInputClosed: Bool
    ) throws -> ShellLauncherInvocation {
        var index = 0
        var inlineCommand: String?
        var syntaxCheckOnly = false
        let builtin = context.runtimeBuiltinContext()
        var childErrexit = builtin.isErrexitEnabled
        var childNounset = builtin.isNounsetEnabled
        var childPipefail = builtin.isPipefailEnabled

        while index < arguments.count {
            let argument = arguments[index]
            if shellLauncherName == "bash",
               argument == "--noprofile" || argument == "--norc" {
                index += 1
                continue
            }
            if argument == "-o" || argument == "+o" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure.usage("\(commandName): option requires an argument -- o\n")
                }
                let enable = argument == "-o"
                switch arguments[index + 1] {
                case "errexit":
                    childErrexit = enable
                case "nounset":
                    childNounset = enable
                case "pipefail":
                    childPipefail = enable
                case "xtrace":
                    break
                default:
                    throw MSPCommandFailure.usage("\(commandName): unsupported option -- \(arguments[index + 1])\n")
                }
                index += 2
                continue
            }
            if argument == "-c" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure.usage("\(commandName): option requires an argument -- c\n")
                }
                inlineCommand = arguments[index + 1]
                index += 2
                break
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                break
            }

            var consumedCommand = false
            for option in argument.dropFirst() {
                switch option {
                case "c":
                    guard index + 1 < arguments.count else {
                        throw MSPCommandFailure.usage("\(commandName): option requires an argument -- c\n")
                    }
                    inlineCommand = arguments[index + 1]
                    index += 2
                    consumedCommand = true
                    break
                case "e":
                    childErrexit = true
                case "u":
                    childNounset = true
                case "n":
                    syntaxCheckOnly = true
                case "l", "x":
                    continue
                default:
                    throw MSPCommandFailure.usage("\(commandName): unsupported option -- \(option)\n")
                }
            }
            if consumedCommand {
                break
            }
            index += 1
        }

        let scriptName: String
        let script: String
        let positional: [String]
        let executionStandardInput: Data
        let executionStandardInputClosed: Bool
        if let inlineCommand {
            let remaining = Array(arguments.dropFirst(index))
            scriptName = remaining.first ?? commandName
            positional = Array(remaining.dropFirst())
            script = inlineCommand
            executionStandardInput = standardInput
            executionStandardInputClosed = standardInputClosed
        } else if index < arguments.count {
            scriptName = arguments[index]
            script = try sourceScriptText(path: scriptName, commandName: commandName)
            positional = Array(arguments.dropFirst(index + 1))
            executionStandardInput = standardInput
            executionStandardInputClosed = standardInputClosed
        } else if standardInputClosed {
            throw MSPCommandFailure.usage("\(commandName): stdin: Bad file descriptor\n")
        } else if !standardInput.isEmpty {
            scriptName = commandName
            script = String(decoding: standardInput, as: UTF8.self)
            positional = []
            executionStandardInput = Data()
            executionStandardInputClosed = false
        } else {
            throw MSPCommandFailure.usage("\(commandName): missing -c command\n")
        }

        return ShellLauncherInvocation(
            script: script,
            scriptName: scriptName,
            positionalParameters: positional,
            standardInput: executionStandardInput,
            standardInputClosed: executionStandardInputClosed,
            syntaxCheckOnly: syntaxCheckOnly,
            errexitEnabled: childErrexit,
            nounsetEnabled: childNounset,
            pipefailEnabled: childPipefail
        )
    }
}

struct ShellLauncherInvocation {
    var script: String
    var scriptName: String
    var positionalParameters: [String]
    var standardInput: Data
    var standardInputClosed: Bool
    var syntaxCheckOnly: Bool
    var errexitEnabled: Bool
    var nounsetEnabled: Bool
    var pipefailEnabled: Bool
}
