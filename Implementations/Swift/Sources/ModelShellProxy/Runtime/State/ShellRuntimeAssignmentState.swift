import MSPShell

extension ShellRuntime {
    func applyAssignmentOnlyStateChange(_ parsed: MSPParsedCommandLine) {
        applyEnvironmentAssignments(parsed.assignments)
        applyArrayAssignments(parsed.arrayAssignments)
        applySubscriptAssignments(parsed.subscriptAssignments)
    }

    func applyEnvironmentAssignments(_ assignments: [MSPParsedAssignment]) {
        configuration.environment = environment(configuration.environment, applying: assignments)
    }

    func applyArrayAssignments(_ assignments: [MSPParsedArrayAssignment]) {
        for assignment in assignments {
            let name = resolvedShellNamerefName(assignment.name)
            let updatedArray: MSPShellIndexedArray
            if assignment.append {
                var array = state.shellArrays[name] ?? MSPShellIndexedArray()
                applyIndexedCompoundArrayElements(assignment.values, to: &array)
                state.shellArrays[name] = array
                updatedArray = array
            } else {
                var array = MSPShellIndexedArray()
                applyIndexedCompoundArrayElements(assignment.values, to: &array)
                updatedArray = array
                state.shellArrays[name] = updatedArray
            }
            state.shellAssociativeArrays.removeValue(forKey: name)
            state.shellNamerefs.removeValue(forKey: name)
            configuration.environment[name] = updatedArray.first ?? ""
        }
    }

    func applyAssociativeArrayAssignment(
        name rawName: String,
        values elements: [String],
        append: Bool
    ) {
        let name = resolvedShellNamerefName(rawName)
        var values = append ? (state.shellAssociativeArrays[name] ?? [:]) : [:]
        var pendingKey: String?
        for element in elements {
            if let assignment = compoundArrayElement(element) {
                values[assignment.key] = assignment.value
            } else if let key = pendingKey {
                values[key] = element
                pendingKey = nil
            } else {
                pendingKey = element
            }
        }
        if let key = pendingKey {
            values[key] = ""
        }
        state.shellAssociativeArrays[name] = values
        state.shellArrays.removeValue(forKey: name)
        state.shellNamerefs.removeValue(forKey: name)
        configuration.environment.removeValue(forKey: name)
    }

    func applySubscriptAssignments(_ assignments: [MSPParsedSubscriptAssignment]) {
        for assignment in assignments {
            let name = resolvedShellNamerefName(assignment.name)
            if state.shellAssociativeArrays[name] != nil {
                let current = state.shellAssociativeArrays[name]?[assignment.key] ?? ""
                state.shellAssociativeArrays[name, default: [:]][assignment.key] = assignment.append
                    ? current + assignment.value
                    : assignment.value
                configuration.environment.removeValue(forKey: name)
                continue
            }
            if let index = Int(assignment.key), index >= 0 {
                var array = state.shellArrays[name] ?? MSPShellIndexedArray()
                array.assign(assignment.value, at: index, appending: assignment.append)
                state.shellArrays[name] = array
                state.shellAssociativeArrays.removeValue(forKey: name)
                configuration.environment[name] = array.first ?? ""
            } else {
                let current = state.shellAssociativeArrays[name]?[assignment.key] ?? ""
                state.shellAssociativeArrays[name, default: [:]][assignment.key] = assignment.append
                    ? current + assignment.value
                    : assignment.value
                state.shellArrays.removeValue(forKey: name)
                configuration.environment.removeValue(forKey: name)
            }
        }
    }

    private func applyIndexedCompoundArrayElements(
        _ elements: [String],
        to array: inout MSPShellIndexedArray
    ) {
        for element in elements {
            if let assignment = compoundArrayElement(element),
               let index = Int(assignment.key),
               index >= 0 {
                array.assign(assignment.value, at: index)
            } else {
                array.append(contentsOf: [element])
            }
        }
    }

    private func compoundArrayElement(_ argument: String) -> (key: String, value: String)? {
        guard argument.hasPrefix("["),
              let close = compoundArraySubscriptCloseIndex(in: argument) else {
            return nil
        }
        let afterClose = argument.index(after: close)
        guard afterClose < argument.endIndex,
              argument[afterClose] == "=" else {
            return nil
        }
        return (
            key: shellRuntimeQuoteRemovedText(String(argument[argument.index(after: argument.startIndex)..<close])),
            value: String(argument[argument.index(after: afterClose)...])
        )
    }

    private func compoundArraySubscriptCloseIndex(in argument: String) -> String.Index? {
        var index = argument.index(after: argument.startIndex)
        var quote: Character?
        while index < argument.endIndex {
            let character = argument[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "\\" {
                    let next = argument.index(after: index)
                    index = next < argument.endIndex ? argument.index(after: next) : next
                    continue
                }
                index = argument.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = argument.index(after: index)
                continue
            }
            if character == "\\" {
                let next = argument.index(after: index)
                index = next < argument.endIndex ? argument.index(after: next) : next
                continue
            }
            if character == "]" {
                return index
            }
            index = argument.index(after: index)
        }
        return nil
    }

    private func shellRuntimeQuoteRemovedText(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = text.index(after: index)
                    continue
                }
                if activeQuote == "\"", character == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        output.append(text[next])
                        index = text.index(after: next)
                    } else {
                        index = next
                    }
                    continue
                }
                output.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    output.append(text[next])
                    index = text.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }
}
