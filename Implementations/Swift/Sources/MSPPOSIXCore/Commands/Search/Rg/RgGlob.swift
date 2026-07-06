import Foundation

struct RgGlobRule {
    var pattern: String
    var isExclusion: Bool

    init(rawPattern: String) {
        if rawPattern.hasPrefix("!") {
            self.isExclusion = true
            self.pattern = String(rawPattern.dropFirst())
        } else {
            self.isExclusion = false
            self.pattern = rawPattern
        }
    }

    func matches(_ displayPath: String) -> Bool {
        rgPath(displayPath, matchesGlob: pattern)
    }
}

private func rgPath(_ displayPath: String, matchesGlob pattern: String) -> Bool {
    let comparablePath = rgComparableGlobPath(displayPath)
    let target = pattern.contains("/")
        ? comparablePath
        : MSPPOSIXCommandSupport.basename(comparablePath)
    guard let regex = try? NSRegularExpression(pattern: "^" + rgGlobRegex(pattern) + "$") else {
        return false
    }
    return regex.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
}

private func rgComparableGlobPath(_ displayPath: String) -> String {
    var path = displayPath
    while path.hasPrefix("./") {
        path.removeFirst(2)
    }
    while path.hasPrefix("/") {
        path.removeFirst()
    }
    return path
}

private func rgGlobRegex(_ pattern: String) -> String {
    var output = ""
    for character in pattern {
        switch character {
        case "*":
            output += ".*"
        case "?":
            output += "."
        case ".", "\\", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|":
            output += "\\\(character)"
        default:
            output.append(character)
        }
    }
    return output
}
