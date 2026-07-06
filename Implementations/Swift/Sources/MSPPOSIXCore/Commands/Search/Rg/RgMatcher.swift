import Foundation
import MSPCore

struct RgMatcher {
    var patterns: [String]
    var fixedStrings: Bool
    var ignoreCase: Bool
    var wordRegexp: Bool
    var lineRegexp: Bool
    var regex: NSRegularExpression?

    init(patterns: [String], fixedStrings: Bool, ignoreCase: Bool, wordRegexp: Bool, lineRegexp: Bool) throws {
        self.patterns = patterns
        self.fixedStrings = fixedStrings
        self.ignoreCase = ignoreCase
        self.wordRegexp = wordRegexp
        self.lineRegexp = lineRegexp
        if fixedStrings {
            self.regex = nil
        } else {
            do {
                let source = patterns.isEmpty ? "" : patterns.map { "(?:\($0))" }.joined(separator: "|")
                self.regex = try NSRegularExpression(
                    pattern: rgAnchoredPattern(source, wordRegexp: wordRegexp, lineRegexp: lineRegexp),
                    options: ignoreCase ? [.caseInsensitive] : []
                )
            } catch {
                throw MSPCommandFailure.usage("rg: regex parse error: \(error.localizedDescription)\n")
            }
        }
    }

    func matches(_ line: String) -> Bool {
        if fixedStrings {
            return patterns.contains { pattern in
                let matched: Bool
                if ignoreCase {
                    matched = line.range(of: pattern, options: [.caseInsensitive]) != nil
                } else {
                    matched = line.contains(pattern)
                }
                guard matched else { return false }
                if lineRegexp {
                    return ignoreCase ? line.caseInsensitiveCompare(pattern) == .orderedSame : line == pattern
                }
                if wordRegexp {
                    return rgLine(line, containsWord: pattern, ignoreCase: ignoreCase)
                }
                return true
            }
        }
        guard let regex else {
            return false
        }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}

private func rgAnchoredPattern(_ pattern: String, wordRegexp: Bool, lineRegexp: Bool) -> String {
    if lineRegexp {
        return "^(?:\(pattern))$"
    }
    if wordRegexp {
        return "\\b(?:\(pattern))\\b"
    }
    return pattern
}

private func rgLine(_ line: String, containsWord pattern: String, ignoreCase: Bool) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
    let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: options) else {
        return false
    }
    return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}
