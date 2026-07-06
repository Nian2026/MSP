func globMatches(_ value: String, pattern: String, caseInsensitive: Bool) -> Bool {
    let valueCharacters = Array(caseInsensitive ? value.lowercased() : value)
    let patternCharacters = Array(caseInsensitive ? pattern.lowercased() : pattern)
    var memo: [String: Bool] = [:]

    func matches(valueIndex: Int, patternIndex: Int) -> Bool {
        let key = "\(valueIndex):\(patternIndex)"
        if let cached = memo[key] {
            return cached
        }

        let result: Bool
        if patternIndex == patternCharacters.count {
            result = valueIndex == valueCharacters.count
        } else {
            switch patternCharacters[patternIndex] {
            case "*":
                result = matches(valueIndex: valueIndex, patternIndex: patternIndex + 1)
                    || (valueIndex < valueCharacters.count
                        && matches(valueIndex: valueIndex + 1, patternIndex: patternIndex))
            case "?":
                result = valueIndex < valueCharacters.count
                    && matches(valueIndex: valueIndex + 1, patternIndex: patternIndex + 1)
            default:
                result = valueIndex < valueCharacters.count
                    && valueCharacters[valueIndex] == patternCharacters[patternIndex]
                    && matches(valueIndex: valueIndex + 1, patternIndex: patternIndex + 1)
            }
        }

        memo[key] = result
        return result
    }

    return matches(valueIndex: 0, patternIndex: 0)
}
