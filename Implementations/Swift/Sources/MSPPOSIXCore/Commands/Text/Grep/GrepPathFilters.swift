import Foundation

func grepPath(_ path: String, matchesAny patterns: [String]) -> Bool {
    patterns.contains { pattern in
        grepPath(path, matchesGlob: pattern)
    }
}

func grepPath(_ path: String, matchesGlob pattern: String) -> Bool {
    let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    let basename = normalizedPath.split(separator: "/").last.map(String.init) ?? normalizedPath
    if pattern.contains("/") {
        return grepGlobMatch(normalizedPath, pattern: pattern) || grepGlobMatch(path, pattern: pattern)
    }
    return grepGlobMatch(basename, pattern: pattern) || grepGlobMatch(normalizedPath, pattern: pattern)
}

func grepGlobMatch(_ value: String, pattern: String) -> Bool {
    var regex = "^"
    for scalar in pattern.unicodeScalars {
        switch scalar {
        case "*":
            regex += ".*"
        case "?":
            regex += "."
        default:
            regex += NSRegularExpression.escapedPattern(for: String(scalar))
        }
    }
    regex += "$"
    return value.range(of: regex, options: .regularExpression) != nil
}

func grepStripTrailingSlashes(_ value: String) -> String {
    var stripped = value
    while stripped.count > 1, stripped.hasSuffix("/") {
        stripped.removeLast()
    }
    return stripped
}
