import Foundation
import MSPCore

func mspPOSIXXargsLogicalLines(from text: String, eofMarker: String?) throws -> [[String]] {
    var lines: [[String]] = []
    let rawLines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    for rawLine in rawLines {
        let words = try mspPOSIXXargsShellWords(from: rawLine)
        guard !words.isEmpty else {
            continue
        }
        if let eofMarker, !eofMarker.isEmpty, let eofIndex = words.firstIndex(of: eofMarker) {
            let prefix = Array(words[..<eofIndex])
            if !prefix.isEmpty {
                lines.append(prefix)
            }
            break
        }
        lines.append(words)
    }
    return lines
}

func mspPOSIXXargsValues(
    from text: String,
    delimiter: Character?,
    nullDelimited: Bool,
    lineDelimited: Bool,
    eofMarker: String?
) throws -> [String] {
    func applyEOF(_ values: [String]) -> [String] {
        guard let eofMarker, !eofMarker.isEmpty else {
            return values
        }
        return Array(values.prefix { $0 != eofMarker })
    }
    if nullDelimited {
        return mspPOSIXXargsDelimitedValues(from: text, delimiter: "\0")
    }
    if let delimiter {
        return mspPOSIXXargsDelimitedValues(from: text, delimiter: delimiter)
    }
    if lineDelimited {
        return applyEOF(text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init))
    }
    return applyEOF(try mspPOSIXXargsShellWords(from: text))
}

private func mspPOSIXXargsDelimitedValues(from text: String, delimiter: Character) -> [String] {
    var values: [String] = []
    var current = ""
    for character in text {
        if character == delimiter {
            values.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty {
        values.append(current)
    }
    return values
}

func mspPOSIXXargsShellWords(from text: String) throws -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false
    var wordStarted = false

    for character in text {
        if escaping {
            current.append(character)
            escaping = false
            wordStarted = true
            continue
        }
        if character == "\\" {
            escaping = true
            continue
        }
        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
                wordStarted = true
            } else if character == "\n" || character == "\r" {
                let quoteName = activeQuote == "'" ? "single quote" : "double quote"
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "xargs: unmatched \(quoteName); by default quotes are special to xargs unless you use the -0 option\n"
                ))
            } else {
                current.append(character)
                wordStarted = true
            }
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            wordStarted = true
            continue
        }
        if character.isWhitespace {
            if wordStarted || !current.isEmpty {
                words.append(current)
                current = ""
                wordStarted = false
            }
            continue
        }
        current.append(character)
        wordStarted = true
    }

    if escaping {
        current.append("\\")
        wordStarted = true
    }
    if let quote {
        let quoteName = quote == "'" ? "single quote" : "double quote"
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "xargs: unmatched \(quoteName); by default quotes are special to xargs unless you use the -0 option\n"
        ))
    }
    if wordStarted || !current.isEmpty {
        words.append(current)
    }
    return words
}

func mspPOSIXXargsDelimiter(_ rawValue: String) throws -> Character {
    let decoded: String
    switch rawValue {
    case #"\\0"#, #"\0"#:
        decoded = "\0"
    case #"\\n"#, #"\n"#:
        decoded = "\n"
    case #"\\r"#, #"\r"#:
        decoded = "\r"
    case #"\\t"#, #"\t"#:
        decoded = "\t"
    case #"\\\\"#, #"\\"#:
        decoded = "\\"
    default:
        decoded = rawValue
    }
    guard decoded.count == 1, let character = decoded.first else {
        throw MSPCommandFailure.usage("xargs: delimiter must be a single character\n")
    }
    return character
}

func mspPOSIXXargsPositiveInteger(_ value: String, option: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
        throw MSPCommandFailure.usage("xargs: invalid positive integer for \(option)\n")
    }
    return parsed
}

func mspPOSIXXargsNonNegativeInteger(_ value: String, option: String) throws -> Int {
    guard let parsed = Int(value), parsed >= 0 else {
        throw MSPCommandFailure.usage("xargs: invalid non-negative integer for \(option)\n")
    }
    return parsed
}
