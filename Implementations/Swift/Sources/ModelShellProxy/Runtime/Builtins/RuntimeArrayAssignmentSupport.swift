import MSPShell

extension RuntimeBuiltinContext {
    func decodedArrayAssignmentArgument(
        _ argument: String
    ) -> (append: Bool, name: String, values: [String])? {
        guard let assignment = mspShellDecodedArrayAssignmentArgument(argument) else {
            return nil
        }
        return (assignment.append, assignment.name, assignment.values)
    }

    mutating func applyIndexedArrayAssignment(
        name rawName: String,
        values elements: [String],
        append: Bool
    ) {
        let name = resolvedShellNamerefName(rawName)
        let updatedArray: MSPShellIndexedArray
        if append {
            var array = shellArrays[name] ?? MSPShellIndexedArray()
            applyIndexedCompoundArrayElements(elements, to: &array)
            updatedArray = array
        } else {
            var array = MSPShellIndexedArray()
            applyIndexedCompoundArrayElements(elements, to: &array)
            updatedArray = array
        }
        shellArrays[name] = updatedArray
        shellAssociativeArrays.removeValue(forKey: name)
        shellNamerefs.removeValue(forKey: name)
        configuration.environment[name] = updatedArray.first ?? ""
    }

    mutating func applyIndexedCompoundArrayElements(_ elements: [String], to array: inout MSPShellIndexedArray) {
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

    mutating func applyAssociativeArrayAssignment(
        name rawName: String,
        values elements: [String],
        append: Bool
    ) {
        let name = resolvedShellNamerefName(rawName)
        var values = append ? (shellAssociativeArrays[name] ?? [:]) : [:]
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
        shellAssociativeArrays[name] = values
        shellArrays.removeValue(forKey: name)
        shellNamerefs.removeValue(forKey: name)
        configuration.environment.removeValue(forKey: name)
    }

    func compoundArrayElement(_ argument: String) -> (key: String, value: String)? {
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

    func compoundArraySubscriptCloseIndex(in argument: String) -> String.Index? {
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

    func shellRuntimeQuoteRemovedText(_ text: String) -> String {
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
