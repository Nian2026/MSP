import MSPCore

extension RuntimeBuiltinContext {
    mutating func executeVariableAttributeCommand(
        commandName: String,
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        let setsReadonly = commandName == "readonly"
        var removesExport = false
        var functionsOnly = false
        var printDeclarations = false
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
                case "f":
                    functionsOnly = true
                case "n" where !setsReadonly:
                    removesExport = true
                case "p":
                    printDeclarations = true
                case "a" where setsReadonly:
                    continue
                case "A" where setsReadonly:
                    continue
                default:
                    return .failure(exitCode: 2, stderr: "\(commandName): -\(option): invalid option\n")
                }
            }
            index += 1
        }

        let operands = Array(arguments.dropFirst(index))
        if operands.isEmpty || printDeclarations {
            return .success(stdout: variableAttributeDeclarationOutput(commandName: commandName))
        }

        var exitCode: Int32 = 0
        var stderr = ""
        guard appliesStateChange else {
            return .success()
        }

        for operand in operands {
            if functionsOnly {
                guard shellFunctions[operand] != nil else {
                    exitCode = 1
                    stderr += "\(commandName): \(operand): not a function\n"
                    continue
                }
                continue
            }

            let parsedAssignment = shellRuntimeAttributeAssignment(operand)
            let rawName = parsedAssignment?.name ?? operand
            guard shellRuntimeVariableName(rawName) else {
                exitCode = 1
                stderr += diagnostics.diagnostic("\(commandName): `\(operand)': not a valid identifier", lineNumber: nil)
                continue
            }
            let name = resolvedShellNamerefName(rawName)

            if let assignment = parsedAssignment {
                if readonlyVariableNames.contains(name) {
                    exitCode = 1
                    stderr += diagnostics.diagnostic("\(name): readonly variable", lineNumber: nil)
                    continue
                }
                let value = assignment.appends
                    ? (configuration.environment[name] ?? "") + assignment.value
                    : assignment.value
                configuration.environment[name] = value
                shellArrays.removeValue(forKey: name)
                shellAssociativeArrays.removeValue(forKey: name)
                shellNamerefs.removeValue(forKey: name)
            } else if configuration.environment[name] == nil, setsReadonly {
                configuration.environment[name] = ""
            }

            if setsReadonly {
                readonlyVariableNames.insert(name)
            } else if removesExport {
                exportedVariableNames.remove(name)
            } else {
                exportedVariableNames.insert(name)
            }
        }

        return MSPCommandResult(stderr: stderr, exitCode: exitCode)
    }

    func variableAttributeDeclarationOutput(commandName: String) -> String {
        let isExport = commandName == "export"
        let names = (isExport ? exportedVariableNames : readonlyVariableNames).sorted()
        let flag = isExport ? "x" : "r"
        let lines = names.map { name -> String in
            guard let value = configuration.environment[name] else {
                return "declare -\(flag) \(name)"
            }
            return "declare -\(flag) \(name)=\"\(escapedDeclarationValue(value))\""
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    func shellRuntimeAttributeAssignment(
        _ value: String
    ) -> (name: String, value: String, appends: Bool)? {
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
            return nil
        }
        var name = String(value[..<equals])
        var appends = false
        if name.hasSuffix("+") {
            appends = true
            name.removeLast()
        }
        return (name, String(value[value.index(after: equals)...]), appends)
    }
}
