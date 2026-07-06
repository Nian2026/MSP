import MSPCore
import MSPShell

extension RuntimeBuiltinContext {
    mutating func executeDeclareCommand(
        commandName: String,
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        var declaresIndexedArray = false
        var declaresAssociativeArray = false
        var declaresNameref = false
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
                case "a":
                    declaresIndexedArray = true
                    declaresAssociativeArray = false
                case "A":
                    declaresAssociativeArray = true
                    declaresIndexedArray = false
                case "p":
                    printDeclarations = true
                case "g", "i", "r", "x", "l", "u":
                    continue
                case "n":
                    declaresNameref = true
                default:
                    return .failure(exitCode: 2, stderr: "\(commandName): -\(option): invalid option\n")
                }
            }
            index += 1
        }

        let namesOrAssignments = Array(arguments.dropFirst(index))
        if printDeclarations || namesOrAssignments.isEmpty {
            return .success(stdout: declarationOutput(for: namesOrAssignments))
        }

        guard appliesStateChange else {
            return .success()
        }

        for argument in namesOrAssignments {
            if declaresNameref {
                if let assignment = shellRuntimeAssignment(argument) {
                    guard shellRuntimeVariableName(assignment.value) else {
                        return .failure(
                            exitCode: 2,
                            stderr: "\(commandName): `\(assignment.value)': invalid variable name for name reference\n"
                        )
                    }
                    shellNamerefs[assignment.name] = assignment.value
                    configuration.environment[assignment.name] = assignment.value
                    shellArrays.removeValue(forKey: assignment.name)
                    shellAssociativeArrays.removeValue(forKey: assignment.name)
                    continue
                }
                guard shellRuntimeVariableName(argument) else {
                    return .failure(exitCode: 1, stderr: "\(commandName): `\(argument)': not a valid identifier\n")
                }
                shellNamerefs[argument] = configuration.environment[argument] ?? ""
                continue
            }
            if let arrayAssignment = decodedArrayAssignmentArgument(argument) {
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
                let name = resolvedShellNamerefName(assignment.name)
                configuration.environment[name] = assignment.value
                shellNamerefs.removeValue(forKey: name)
                if declaresAssociativeArray {
                    shellAssociativeArrays[name] = ["": assignment.value]
                    shellArrays.removeValue(forKey: name)
                    continue
                }
                if declaresIndexedArray {
                    shellArrays[name] = MSPShellIndexedArray([assignment.value])
                    shellAssociativeArrays.removeValue(forKey: name)
                }
                continue
            }
            guard shellRuntimeVariableName(argument) else {
                return .failure(exitCode: 1, stderr: "\(commandName): `\(argument)': not a valid identifier\n")
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
}
