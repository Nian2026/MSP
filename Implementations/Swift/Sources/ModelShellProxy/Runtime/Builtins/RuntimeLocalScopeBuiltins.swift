import MSPCore
import MSPShell

extension RuntimeBuiltinContext {
    mutating func executeLocalCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard functionDepth > 0 else {
            return .failure(exitCode: 1, stderr: "local: can only be used in a function\n")
        }
        guard appliesStateChange else {
            return .success()
        }

        var declaresIndexedArray = false
        var declaresAssociativeArray = false
        var declaresNameref = false
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
                case "a":
                    declaresIndexedArray = true
                    declaresAssociativeArray = false
                case "A":
                    declaresAssociativeArray = true
                    declaresIndexedArray = false
                case "n":
                    declaresNameref = true
                case "g", "i", "r", "x", "l", "u":
                    continue
                default:
                    return .failure(exitCode: 2, stderr: "local: -\(option): invalid option\n")
                }
            }
            index += 1
        }

        for argument in arguments.dropFirst(index) {
            if declaresNameref {
                if let assignment = shellRuntimeAssignment(argument) {
                    guard shellRuntimeVariableName(assignment.value) else {
                        return .failure(
                            exitCode: 2,
                            stderr: "local: `\(assignment.value)': invalid variable name for name reference\n"
                        )
                    }
                    guard recordFunctionLocalEnvironmentValueIfNeeded(assignment.name) else {
                        return .failure(exitCode: 1, stderr: "local: not in a function\n")
                    }
                    shellNamerefs[assignment.name] = assignment.value
                    configuration.environment[assignment.name] = assignment.value
                    shellArrays.removeValue(forKey: assignment.name)
                    shellAssociativeArrays.removeValue(forKey: assignment.name)
                    continue
                }
                guard shellRuntimeVariableName(argument) else {
                    return .failure(exitCode: 1, stderr: "local: `\(argument)': not a valid identifier\n")
                }
                guard recordFunctionLocalEnvironmentValueIfNeeded(argument) else {
                    return .failure(exitCode: 1, stderr: "local: not in a function\n")
                }
                shellNamerefs[argument] = configuration.environment[argument] ?? ""
                continue
            }

            if let arrayAssignment = decodedArrayAssignmentArgument(argument) {
                guard recordFunctionLocalEnvironmentValueIfNeeded(arrayAssignment.name) else {
                    return .failure(exitCode: 1, stderr: "local: not in a function\n")
                }
                if declaresAssociativeArray {
                    applyAssociativeArrayAssignment(
                        name: arrayAssignment.name,
                        values: arrayAssignment.values,
                        append: arrayAssignment.append
                    )
                } else {
                    applyIndexedArrayAssignment(
                        name: arrayAssignment.name,
                        values: arrayAssignment.values,
                        append: arrayAssignment.append
                    )
                }
                continue
            }

            if let assignment = shellRuntimeAssignment(argument) {
                guard recordFunctionLocalEnvironmentValueIfNeeded(assignment.name) else {
                    return .failure(exitCode: 1, stderr: "local: not in a function\n")
                }
                configuration.environment[assignment.name] = assignment.value
                shellNamerefs.removeValue(forKey: assignment.name)
                if declaresAssociativeArray {
                    shellAssociativeArrays[assignment.name] = ["": assignment.value]
                    shellArrays.removeValue(forKey: assignment.name)
                    configuration.environment.removeValue(forKey: assignment.name)
                    continue
                }
                if declaresIndexedArray {
                    let array = MSPShellIndexedArray([assignment.value])
                    shellArrays[assignment.name] = array
                    shellAssociativeArrays.removeValue(forKey: assignment.name)
                    configuration.environment[assignment.name] = array.first ?? ""
                }
                continue
            }
            guard shellRuntimeVariableName(argument) else {
                return .failure(exitCode: 1, stderr: "local: `\(argument)': not a valid identifier\n")
            }
            guard recordFunctionLocalEnvironmentValueIfNeeded(argument) else {
                return .failure(exitCode: 1, stderr: "local: not in a function\n")
            }
            if declaresIndexedArray {
                shellArrays[argument] = shellArrays[argument] ?? MSPShellIndexedArray()
                shellAssociativeArrays.removeValue(forKey: argument)
                shellNamerefs.removeValue(forKey: argument)
                configuration.environment[argument] = shellArrays[argument]?.first ?? ""
            } else if declaresAssociativeArray {
                shellAssociativeArrays[argument] = shellAssociativeArrays[argument] ?? [:]
                shellArrays.removeValue(forKey: argument)
                shellNamerefs.removeValue(forKey: argument)
                configuration.environment.removeValue(forKey: argument)
            } else if configuration.environment[argument] == nil {
                configuration.environment[argument] = ""
            }
        }
        return .success()
    }

    mutating func recordFunctionLocalEnvironmentValueIfNeeded(_ name: String) -> Bool {
        guard !functionLocalEnvironmentStack.isEmpty else {
            return false
        }
        let topIndex = functionLocalEnvironmentStack.count - 1
        if functionLocalEnvironmentStack[topIndex].keys.contains(name) {
            return true
        }
        functionLocalEnvironmentStack[topIndex][name] = MSPShellLocalVariableSnapshot(
            environment: configuration.environment[name],
            array: shellArrays[name],
            associativeArray: shellAssociativeArrays[name],
            nameref: shellNamerefs[name],
            wasExported: exportedVariableNames.contains(name),
            wasReadonly: readonlyVariableNames.contains(name)
        )
        return true
    }
}
