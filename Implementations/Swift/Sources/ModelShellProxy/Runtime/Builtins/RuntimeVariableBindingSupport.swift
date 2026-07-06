extension RuntimeBuiltinContext {
    func shellRuntimeAssignment(_ value: String) -> (name: String, value: String)? {
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
            return nil
        }
        let name = String(value[..<equals])
        guard shellRuntimeVariableName(name) else {
            return nil
        }
        return (name, String(value[value.index(after: equals)...]))
    }

    func shellRuntimeVariableName(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    func resolvedShellNamerefName(_ name: String) -> String {
        var current = name
        var seen: Set<String> = []
        while let next = shellNamerefs[current],
              shellRuntimeVariableName(next),
              !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }
}
