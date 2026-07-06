import Foundation

func grepFragments(
    line: String,
    options: GrepOptions,
    compiled: [NSRegularExpression]
) -> [String] {
    if options.fixedStrings {
        let comparisonOptions: String.CompareOptions = options.ignoreCase ? [.caseInsensitive] : []
        return options.patterns.flatMap { pattern -> [String] in
            var fragments: [String] = []
            var searchStart = line.startIndex
            while searchStart <= line.endIndex,
                  let range = line.range(of: pattern, options: comparisonOptions, range: searchStart..<line.endIndex) {
                let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
                let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
                let wordOK = !options.wordRegexp || (grepIsWordBoundary(before) && grepIsWordBoundary(after))
                let lineOK = !options.lineRegexp || (range.lowerBound == line.startIndex && range.upperBound == line.endIndex)
                if wordOK && lineOK {
                    fragments.append(String(line[range]))
                }
                searchStart = range.upperBound < line.endIndex ? range.upperBound : line.endIndex
                if range.isEmpty { break }
            }
            return fragments
        }
    }

    let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
    return compiled.flatMap { regex in
        regex.matches(in: line, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return String(line[range])
        }
    }
}

func grepBasicRegexPattern(from pattern: String) -> String {
    var output = ""
    var index = pattern.startIndex
    while index < pattern.endIndex {
        let character = pattern[index]
        if character == "\\" {
            let nextIndex = pattern.index(after: index)
            guard nextIndex < pattern.endIndex else {
                output += "\\\\"
                index = nextIndex
                continue
            }
            let next = pattern[nextIndex]
            switch next {
            case "+", "?", "|", "(", ")":
                output.append(next)
            case "{", "}":
                output += "\\\(next)"
            default:
                output += "\\\(next)"
            }
            index = pattern.index(after: nextIndex)
            continue
        }
        switch character {
        case "+", "?", "|", "(", ")", "{", "}":
            output += "\\\(character)"
        default:
            output.append(character)
        }
        index = pattern.index(after: index)
    }
    return output
}

func grepIsWordBoundary(_ character: Character?) -> Bool {
    guard let character else { return true }
    return !(character.isLetter || character.isNumber || character == "_")
}
