import Foundation

extension MSPPOSIXSedRunner {
    static func applySubstitution(
        _ substitution: MSPPOSIXSedSubstitution,
        regex: NSRegularExpression,
        to currentLine: inout String,
        currentLineTerminated: Bool,
        output: inout [SedOutputRecord]
    ) -> Bool {
        let range = NSRange(currentLine.startIndex..<currentLine.endIndex, in: currentLine)
        let matches = regex.matches(in: currentLine, options: [], range: range)
        guard !matches.isEmpty else { return false }
        let selectedMatches = selectedSubstitutionMatches(matches, substitution: substitution)
        guard !selectedMatches.isEmpty else { return false }
        for match in selectedMatches.reversed() {
            guard let matchRange = Range(match.range, in: currentLine) else { continue }
            let replacement = replacementString(
                substitution.replacement,
                line: currentLine,
                match: match
            )
            currentLine.replaceSubrange(matchRange, with: replacement)
        }
        if substitution.print {
            output.append(SedOutputRecord(text: currentLine, terminated: currentLineTerminated))
        }
        return true
    }

    private static func selectedSubstitutionMatches(
        _ matches: [NSTextCheckingResult],
        substitution: MSPPOSIXSedSubstitution
    ) -> [NSTextCheckingResult] {
        if substitution.global {
            let firstOccurrence = substitution.occurrence ?? 1
            return matches.enumerated().compactMap { index, match in
                index + 1 >= firstOccurrence ? match : nil
            }
        }
        if let occurrence = substitution.occurrence {
            let index = occurrence - 1
            return matches.indices.contains(index) ? [matches[index]] : []
        }
        return [matches[0]]
    }

    private static func replacementString(
        _ replacement: String,
        line: String,
        match: NSTextCheckingResult
    ) -> String {
        var output = ""
        var index = replacement.startIndex
        while index < replacement.endIndex {
            let character = replacement[index]
            if character == "\\" {
                let next = replacement.index(after: index)
                guard next < replacement.endIndex else {
                    output.append(character)
                    index = next
                    continue
                }
                if replacement[next].isNumber,
                   let captureIndex = Int(String(replacement[next])),
                   captureIndex < match.numberOfRanges,
                   let captureRange = Range(match.range(at: captureIndex), in: line) {
                    output += line[captureRange]
                } else {
                    output += replacementEscapedCharacter(replacement[next])
                }
                index = replacement.index(after: next)
                continue
            }
            if character == "&" {
                if let matchRange = Range(match.range, in: line) {
                    output += line[matchRange]
                }
            } else {
                output.append(character)
            }
            index = replacement.index(after: index)
        }
        return output
    }

    private static func replacementEscapedCharacter(_ character: Character) -> String {
        switch character {
        case "n":
            return "\n"
        case "t":
            return "\t"
        case "r":
            return "\r"
        default:
            return String(character)
        }
    }
}
