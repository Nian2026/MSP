import MSPCore

extension RuntimeBuiltinContext {
    mutating func executeUnsetCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        var unsetsVariables = true
        var unsetsFunctions = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                break
            }
            for option in argument.dropFirst() {
                switch option {
                case "v":
                    unsetsVariables = true
                    unsetsFunctions = false
                case "f":
                    unsetsVariables = false
                    unsetsFunctions = true
                default:
                    return .failure(
                        exitCode: 2,
                        stderr: diagnostics.diagnostic("unset: -\(option): invalid option", lineNumber: nil)
                            + "unset: usage: unset [-f] [-v] [-n] [name ...]\n"
                    )
                }
            }
            index += 1
        }

        guard appliesStateChange else {
            return .success()
        }
        for name in arguments.dropFirst(index) {
            if unsetsFunctions {
                shellFunctions.removeValue(forKey: name)
                shellFunctionSourceNames.removeValue(forKey: name)
                continue
            }
            guard unsetsVariables else {
                continue
            }
            if let subscriptExpression = unsetSubscriptExpression(name) {
                let targetName = resolvedShellNamerefName(subscriptExpression.name)
                if readonlyVariableNames.contains(targetName) {
                    return .failure(
                        exitCode: 1,
                        stderr: diagnostics.diagnostic("unset: \(targetName): cannot unset: readonly variable", lineNumber: nil)
                    )
                }
                if shellAssociativeArrays[targetName] != nil {
                    shellAssociativeArrays[targetName]?.removeValue(forKey: subscriptExpression.key)
                } else if let index = Int(subscriptExpression.key), index >= 0 {
                    shellArrays[targetName]?[index] = nil
                    configuration.environment[targetName] = shellArrays[targetName]?.first ?? ""
                }
                continue
            }
            if readonlyVariableNames.contains(name) {
                return .failure(
                    exitCode: 1,
                    stderr: diagnostics.diagnostic("unset: \(name): cannot unset: readonly variable", lineNumber: nil)
                )
            }
            configuration.environment.removeValue(forKey: name)
            shellArrays.removeValue(forKey: name)
            shellAssociativeArrays.removeValue(forKey: name)
            shellNamerefs.removeValue(forKey: name)
            exportedVariableNames.remove(name)
        }
        return .success()
    }

    func unsetSubscriptExpression(_ expression: String) -> (name: String, key: String)? {
        guard let open = expression.firstIndex(of: "["),
              expression.hasSuffix("]") else {
            return nil
        }
        let name = String(expression[..<open])
        guard shellRuntimeVariableName(name) else {
            return nil
        }
        let close = expression.index(before: expression.endIndex)
        return (name, String(expression[expression.index(after: open)..<close]))
    }
}
