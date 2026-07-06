import MSPShell

extension RuntimeBuiltinContext {
    func declarationOutput(for requestedNames: [String]) -> String {
        let names = requestedNames.isEmpty
            ? Array(Set(configuration.environment.keys)
                .union(shellArrays.keys)
                .union(shellAssociativeArrays.keys)
                .union(shellNamerefs.keys))
                .sorted()
            : requestedNames
        let lines = names.compactMap { name -> String? in
            if let target = shellNamerefs[name] {
                return "declare -n \(name)=\"\(escapedDeclarationValue(target))\""
            }
            if let values = shellAssociativeArrays[name] {
                let body = values.keys.sorted()
                    .map { key in
                        "[\(escapedDeclarationKey(key))]=\"\(escapedDeclarationValue(values[key] ?? ""))\""
                    }
                    .joined(separator: " ")
                return "declare -A \(name)=(\(body))"
            }
            if let values = shellArrays[name] {
                let dense = values.hasDenseZeroBasedIndices
                let body = values.indicesByIndex
                    .map { index in
                        let value = "\"\(escapedDeclarationValue(values[index] ?? ""))\""
                        return dense ? value : "[\(index)]=\(value)"
                    }
                    .joined(separator: " ")
                return "declare -a \(name)=(\(body))"
            }
            guard let value = configuration.environment[name] else {
                return nil
            }
            return "declare -- \(name)=\"\(escapedDeclarationValue(value))\""
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    func escapedDeclarationValue(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "$":
                escaped += "\\$"
            case "`":
                escaped += "\\`"
            case "\n":
                escaped += "\\n"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    func escapedDeclarationKey(_ value: String) -> String {
        escapedDeclarationValue(value)
    }
}
