import MSPCore

extension RuntimeBuiltinContext {
    mutating func executeAliasCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard !arguments.isEmpty else {
            return .success(stdout: shellAliases.keys.sorted().map(aliasDeclaration).joined())
        }

        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0
        for argument in arguments {
            if let equals = argument.firstIndex(of: "="), equals != argument.startIndex {
                let name = String(argument[..<equals])
                let value = String(argument[argument.index(after: equals)...])
                if appliesStateChange {
                    shellAliases[name] = value
                }
                continue
            }
            if shellAliases[argument] != nil {
                stdout += aliasDeclaration(argument)
            } else {
                exitCode = 1
                stderr += diagnostics.diagnostic("alias: \(argument): not found", lineNumber: nil)
            }
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    mutating func executeUnaliasCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard !arguments.isEmpty else {
            return .failure(exitCode: 2, stderr: "unalias: usage: unalias [-a] name [name ...]\n")
        }

        var removesAll = false
        var names: [String] = []
        for argument in arguments {
            if argument == "--" {
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                for option in argument.dropFirst() {
                    switch option {
                    case "a":
                        removesAll = true
                    default:
                        return .failure(
                            exitCode: 2,
                            stderr: diagnostics.diagnostic("unalias: -\(option): invalid option", lineNumber: nil)
                                + "unalias: usage: unalias [-a] name [name ...]\n"
                        )
                    }
                }
            } else {
                names.append(argument)
            }
        }

        if removesAll {
            if appliesStateChange {
                shellAliases.removeAll()
            }
            return .success()
        }
        guard !names.isEmpty else {
            return .failure(exitCode: 2, stderr: "unalias: usage: unalias [-a] name [name ...]\n")
        }

        var stderr = ""
        var exitCode: Int32 = 0
        for name in names {
            if shellAliases[name] == nil {
                exitCode = 1
                stderr += diagnostics.diagnostic("unalias: \(name): not found", lineNumber: nil)
                continue
            }
            if appliesStateChange {
                shellAliases.removeValue(forKey: name)
            }
        }
        return MSPCommandResult(stderr: stderr, exitCode: exitCode)
    }

    func aliasDeclaration(_ name: String) -> String {
        "alias \(name)='\(escapedAliasValue(shellAliases[name] ?? ""))'\n"
    }

    func escapedAliasValue(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
