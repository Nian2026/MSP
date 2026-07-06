import Foundation
import MSPCore
import MSPShell

struct ShellRuntimeBuiltinPorts {
    var readInput: RuntimeBuiltinInputReader
    var consumeInputDescription: (_ descriptionID: Int, _ byteCount: Int) -> Void
    var snapshotPersistentBindings: () -> RuntimeExecPersistentBindingSnapshot
    var restorePersistentBindings: (RuntimeExecPersistentBindingSnapshot) -> Void
    var applyPersistentRedirections: RuntimeExecPersistentRedirectionApplier
}

struct ShellRuntimeExitTrapPorts {
    var runCommandText: (_ commandText: String, _ initialLastExitCode: Int32) async -> MSPCommandResult
}

extension ShellRuntime {
    static let runtimeSpecialBuiltinNames: Set<String> = [
        ".",
        "alias",
        "break",
        "continue",
        "declare",
        "eval",
        "exec",
        "exit",
        "export",
        "local",
        "mapfile",
        "read",
        "readarray",
        "readonly",
        "return",
        "set",
        "shift",
        "sh",
        "bash",
        "shopt",
        "source",
        "trap",
        "typeset",
        "umask",
        "unalias",
        "unset",
        "zsh"
    ]

    func runRuntimeBuiltin(
        _ execute: (inout RuntimeBuiltinContext) -> MSPCommandResult
    ) -> MSPCommandResult {
        var context = runtimeBuiltinContext()
        let result = execute(&context)
        applyRuntimeBuiltinContext(context)
        return result
    }

    func executeReturnCommand(
        arguments: [String],
        lastExitCode: Int32
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeReturnCommand(arguments: arguments, lastExitCode: lastExitCode)
        }
    }

    func executeLoopControlCommand(
        name: String,
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeLoopControlCommand(
                name: name,
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeExitCommand(
        arguments: [String],
        lastExitCode: Int32,
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeExitCommand(
                arguments: arguments,
                lastExitCode: lastExitCode,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeShiftCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeShiftCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeSetCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeSetCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeShoptCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeShoptCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeDeclareCommand(
        commandName: String,
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeDeclareCommand(
                commandName: commandName,
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeVariableAttributeCommand(
        commandName: String,
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeVariableAttributeCommand(
                commandName: commandName,
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeAliasCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeAliasCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeUnaliasCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeUnaliasCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeTrapCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeTrapCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func runExitTrapIfNeeded(
        finalExitCode: Int32,
        ports: ShellRuntimeExitTrapPorts
    ) async -> MSPCommandResult? {
        guard let body = beginExitTrapIfRunnable() else {
            return nil
        }
        let result = await ports.runCommandText(
            body,
            finalExitCode
        )
        let exitCode = finishExitTrap(finalExitCode: finalExitCode)
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderrData: result.stderrData,
            exitCode: exitCode,
            modelContentItems: result.modelContentItems
        )
    }

    func executeDoubleBracketRegexCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        var expression = arguments
        if expression.last == "]]" {
            expression.removeLast()
        }
        guard expression.count == 3, expression[1] == "=~" else {
            return .failure(exitCode: 2, stderr: "[[: conditional binary operator expected\n")
        }

        let lhs = expression[0]
        let pattern = expression[2]
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            return .failure(exitCode: 2, stderr: "[[: \(pattern): invalid regular expression\n")
        }

        let range = NSRange(lhs.startIndex..<lhs.endIndex, in: lhs)
        guard let match = regex.firstMatch(in: lhs, range: range) else {
            if appliesStateChange {
                clearBashRematch()
            }
            return MSPCommandResult(exitCode: 1)
        }

        if appliesStateChange {
            var storage: [Int: String] = [:]
            for index in 0..<match.numberOfRanges {
                let nsRange = match.range(at: index)
                guard nsRange.location != NSNotFound,
                      let stringRange = Range(nsRange, in: lhs) else {
                    storage[index] = ""
                    continue
                }
                storage[index] = String(lhs[stringRange])
            }
            let array = MSPShellIndexedArray(storage: storage)
            setBashRematch(array)
        }
        return MSPCommandResult(exitCode: 0)
    }

    func executeUmaskCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeUmaskCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeUnsetCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeUnsetCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeLocalCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeLocalCommand(
                arguments: arguments,
                appliesStateChange: appliesStateChange
            )
        }
    }

    func executeReadCommand(
        arguments: [String],
        routing: MSPRedirectionRouting,
        assignments: [MSPParsedAssignment],
        appliesStateChange: Bool,
        ports: ShellRuntimeBuiltinPorts
    ) async -> MSPCommandResult {
        var context = runtimeBuiltinContext()
        let result = await context.executeReadCommand(
                arguments: arguments,
                routing: routing,
                assignments: assignments,
                appliesStateChange: appliesStateChange,
                readInput: ports.readInput,
                consumeInputDescription: ports.consumeInputDescription
        )
        applyRuntimeBuiltinContext(context)
        return result
    }

    func executeMapfileCommand(
        commandName: String,
        arguments: [String],
        routing: MSPRedirectionRouting,
        appliesStateChange: Bool,
        ports: ShellRuntimeBuiltinPorts
    ) async -> MSPCommandResult {
        var context = runtimeBuiltinContext()
        let result = await context.executeMapfileCommand(
                commandName: commandName,
                arguments: arguments,
                routing: routing,
                appliesStateChange: appliesStateChange,
                readInput: ports.readInput,
                consumeInputDescription: ports.consumeInputDescription
        )
        applyRuntimeBuiltinContext(context)
        return result
    }

    func assignReadRecord(_ record: String, to names: [String]) {
        _ = runRuntimeBuiltin {
            $0.assignReadRecord(record, to: names)
            return .success()
        }
    }

    func executeExecCommand(
        arguments: [String],
        redirections: [MSPParsedRedirection],
        appliesStateChange: Bool,
        ports: ShellRuntimeBuiltinPorts
    ) -> MSPCommandResult {
        runRuntimeBuiltin {
            $0.executeExecCommand(
                arguments: arguments,
                redirections: redirections,
                appliesStateChange: appliesStateChange,
                snapshotPersistentBindings: ports.snapshotPersistentBindings,
                restorePersistentBindings: ports.restorePersistentBindings,
                applyPersistentRedirections: ports.applyPersistentRedirections
            )
        }
    }
}
