import Foundation

enum MSPPOSIXAwkStringBuiltins {
    struct GsubResult {
        var count: Int
        var updated: String
    }

    struct MatchResult {
        var start: Int
        var length: Int
    }

    static func substr(source: String, start: Double, length: Double?) -> String {
        let characters = Array(source)
        let startIndex = max(Int(start) - 1, 0)
        guard startIndex < characters.count else { return "" }
        let endIndex: Int
        if let length {
            endIndex = min(startIndex + max(Int(length), 0), characters.count)
        } else {
            endIndex = characters.count
        }
        guard startIndex <= endIndex else { return "" }
        return String(characters[startIndex..<endIndex])
    }

    static func gsub(pattern: String, replacement: String, original: String) -> GsubResult {
        let result = replacing(pattern: pattern, replacement: replacement, original: original, limit: nil)
        return GsubResult(count: result.count, updated: result.updated)
    }

    static func gensub(pattern: String, replacement: String, how: String, original: String) -> String {
        let limit: Int?
        if how == "g" {
            limit = nil
        } else if let nth = Int(how), nth > 0 {
            limit = nth
        } else {
            limit = 1
        }
        return replacing(pattern: pattern, replacement: replacement, original: original, limit: limit).updated
    }

    static func match(source: String, pattern: String) -> MatchResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: nsRange),
              let range = Range(match.range, in: source) else {
            return nil
        }
        return MatchResult(
            start: source.distance(from: source.startIndex, to: range.lowerBound) + 1,
            length: source.distance(from: range.lowerBound, to: range.upperBound)
        )
    }

    private static func replacing(
        pattern: String,
        replacement: String,
        original: String,
        limit: Int?
    ) -> (count: Int, updated: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (0, original)
        }
        let matches = regex.matches(
            in: original,
            range: NSRange(original.startIndex..<original.endIndex, in: original)
        )
        guard !matches.isEmpty else { return (0, original) }

        var output = ""
        var cursor = original.startIndex
        var replacedCount = 0
        for (index, match) in matches.enumerated() {
            guard limit == nil || index + 1 == limit else { continue }
            guard let range = Range(match.range, in: original) else { continue }
            output.append(contentsOf: original[cursor..<range.lowerBound])
            output.append(regexReplacement(replacement, match: String(original[range])))
            cursor = range.upperBound
            replacedCount += 1
            if limit != nil { break }
        }
        output.append(contentsOf: original[cursor...])
        return (replacedCount, output)
    }

    private static func regexReplacement(_ replacement: String, match: String) -> String {
        var result = ""
        var index = replacement.startIndex
        while index < replacement.endIndex {
            let character = replacement[index]
            if character == "\\" {
                let next = replacement.index(after: index)
                guard next < replacement.endIndex else {
                    result.append(character)
                    break
                }
                let nextCharacter = replacement[next]
                result.append(nextCharacter == "&" ? "&" : String(character) + String(nextCharacter))
                index = replacement.index(after: next)
                continue
            }
            if character == "&" {
                result.append(match)
            } else {
                result.append(character)
            }
            index = replacement.index(after: index)
        }
        return result
    }
}

extension MSPPOSIXAwkRunner {
    func evaluateFunctionCall(name: String, arguments: [ExpressionNode]) -> String {
        switch name {
        case "length":
            return evaluateLength(arguments: arguments)
        case "index":
            return evaluateIndex(arguments: arguments)
        case "sprintf":
            return evaluateSprintf(arguments: arguments)
        case "substr":
            return evaluateSubstr(arguments: arguments)
        default:
            return evaluateFunctionCall(name: name, argumentTexts: arguments.map(\.sourceText))
        }
    }

    private func evaluateFunctionCall(name: String, argumentTexts arguments: [String]) -> String {
        switch name {
        case "tolower":
            return evaluateString(arguments.first ?? "").lowercased()
        case "sub":
            let pattern = regexPattern(from: arguments.first ?? "")
            let replacement = evaluateString(arguments.dropFirst().first ?? "")
            let target = arguments.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = target.map { evaluateString($0) } ?? currentLine
            guard let range = original.range(of: pattern, options: regexOptions) else { return "0" }
            let replaced = original.replacingCharacters(in: range, with: replacement)
            if let target, !target.isEmpty {
                setLValue(target, value: replaced)
            } else {
                setCurrentLine(replaced)
            }
            return "1"
        case "gsub":
            return evaluateGsub(arguments: arguments)
        case "gensub":
            return evaluateGensub(arguments: arguments)
        case "match":
            return evaluateMatch(arguments: arguments)
        case "close":
            guard let first = arguments.first else { return "0" }
            let target = evaluateString(first)
            pipeOutputRecords[target] = nil
            fileInputRecords[target] = nil
            return "0"
        case "split":
            guard arguments.count >= 2 else { return "0" }
            let source = evaluateString(arguments[0])
            let arrayName = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = arguments.count >= 3 ? evaluateString(arguments[2]) : " "
            let pieces = separator.isEmpty
                ? source.map(String.init)
                : source.components(separatedBy: separator)
            arrays[arrayName] = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { (String($0.offset + 1), $0.element) })
            return String(pieces.count)
        default:
            if let function = functions[name] {
                return callUserFunction(function, arguments: arguments)
            }
            return ""
        }
    }

    private func evaluateLength(arguments: [ExpressionNode]) -> String {
        guard let first = arguments.first else {
            return String(currentLine.count)
        }
        let argument = first.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if MSPPOSIXAwkSyntax.isAwkIdentifier(argument), let array = arrays[argument] {
            return String(array.count)
        }
        return String(evaluateExpressionNode(first).count)
    }

    private func evaluateIndex(arguments: [ExpressionNode]) -> String {
        guard arguments.count >= 2 else { return "0" }
        let source = evaluateExpressionNode(arguments[0])
        let needle = evaluateExpressionNode(arguments[1])
        guard !needle.isEmpty, let range = source.range(of: needle) else { return "0" }
        return String(source.distance(from: source.startIndex, to: range.lowerBound) + 1)
    }

    private func evaluateSprintf(arguments: [ExpressionNode]) -> String {
        guard let format = arguments.first else { return "" }
        let values = arguments.dropFirst().map { evaluateExpressionNode($0) }
        return MSPPOSIXAwkPrintf.format(format: evaluateExpressionNode(format), values: values)
    }

    private func evaluateSubstr(arguments: [ExpressionNode]) -> String {
        guard arguments.count >= 2 else { return "" }
        let source = evaluateExpressionNode(arguments[0])
        let length = arguments.count >= 3 ? numericValue(arguments[2]) : nil
        return MSPPOSIXAwkStringBuiltins.substr(source: source, start: numericValue(arguments[1]), length: length)
    }

    private func evaluateGsub(arguments: [String]) -> String {
        guard arguments.count >= 2 else { return "0" }
        let pattern = regexPattern(from: arguments[0])
        let replacement = evaluateString(arguments[1])
        let target = arguments.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = target.map { evaluateString($0) } ?? currentLine
        let result = MSPPOSIXAwkStringBuiltins.gsub(pattern: pattern, replacement: replacement, original: original)
        guard result.count > 0 else { return "0" }
        if let target, !target.isEmpty {
            setLValue(target, value: result.updated)
        } else {
            setCurrentLine(result.updated)
        }
        return String(result.count)
    }

    private func evaluateGensub(arguments: [String]) -> String {
        guard arguments.count >= 3 else { return "" }
        let pattern = regexPattern(from: arguments[0])
        let replacement = evaluateString(arguments[1])
        let how = evaluateString(arguments[2]).lowercased()
        let original = arguments.count >= 4 ? evaluateString(arguments[3]) : currentLine
        return MSPPOSIXAwkStringBuiltins.gensub(pattern: pattern, replacement: replacement, how: how, original: original)
    }

    private func evaluateMatch(arguments: [String]) -> String {
        guard arguments.count >= 2 else {
            variables["RSTART"] = "0"
            variables["RLENGTH"] = "-1"
            return "0"
        }
        let source = evaluateString(arguments[0])
        let pattern = regexPattern(from: arguments[1])
        guard let match = MSPPOSIXAwkStringBuiltins.match(source: source, pattern: pattern) else {
            variables["RSTART"] = "0"
            variables["RLENGTH"] = "-1"
            return "0"
        }
        variables["RSTART"] = String(match.start)
        variables["RLENGTH"] = String(match.length)
        return String(match.start)
    }

    private func callUserFunction(_ function: UserFunction, arguments: [String]) -> String {
        var previousValues: [String: String?] = [:]
        for (index, parameter) in function.parameters.enumerated() {
            previousValues[parameter] = variables[parameter]
            variables[parameter] = index < arguments.count ? evaluateString(arguments[index]) : ""
        }
        do {
            try executeStatements(function.body)
        } catch let signal as ReturnSignal {
            for parameter in function.parameters {
                variables[parameter] = previousValues[parameter] ?? nil
            }
            return signal.value
        } catch {
            for parameter in function.parameters {
                variables[parameter] = previousValues[parameter] ?? nil
            }
            return ""
        }
        for parameter in function.parameters {
            variables[parameter] = previousValues[parameter] ?? nil
        }
        return ""
    }
}
