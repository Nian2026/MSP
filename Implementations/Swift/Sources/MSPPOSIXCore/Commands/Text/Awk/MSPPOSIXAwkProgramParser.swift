import Foundation

struct MSPPOSIXAwkParsedProgram {
    var blocks: [MSPPOSIXAwkRunner.Block]
    var functions: [String: MSPPOSIXAwkRunner.UserFunction]
}

enum MSPPOSIXAwkProgramParser {
    static func parse(_ program: String) throws -> MSPPOSIXAwkParsedProgram {
        var source = program
        let functions = try extractFunctions(from: &source)
        var blocks: [MSPPOSIXAwkRunner.Block] = []
        var index = source.startIndex
        while let open = MSPPOSIXAwkSyntax.findTopLevelOpeningBrace(in: source, startingAt: index) {
            let close = try matchingBrace(in: source, open: open)
            let prefix = splitProgramPrefix(String(source[index..<open]))
            let actionlessPatterns: ArraySlice<String>
            let header: String
            if prefix.endedWithSeparator {
                actionlessPatterns = prefix.segments[...]
                header = ""
            } else {
                actionlessPatterns = prefix.segments.dropLast()
                header = prefix.segments.last ?? ""
            }
            for pattern in actionlessPatterns {
                blocks.append(MSPPOSIXAwkRunner.Block(kind: .record(pattern), body: "print $0"))
            }
            let body = String(source[source.index(after: open)..<close])
            if header == "BEGIN" {
                blocks.append(MSPPOSIXAwkRunner.Block(kind: .begin, body: body))
            } else if header == "END" {
                blocks.append(MSPPOSIXAwkRunner.Block(kind: .end, body: body))
            } else {
                blocks.append(MSPPOSIXAwkRunner.Block(kind: .record(header.isEmpty ? nil : header), body: body))
            }
            index = source.index(after: close)
        }
        for pattern in splitProgramPrefix(String(source[index...])).segments {
            blocks.append(MSPPOSIXAwkRunner.Block(kind: .record(pattern), body: "print $0"))
        }
        if blocks.isEmpty {
            throw MSPPOSIXAwkError.usage("awk: only simple print and aggregation programs are supported")
        }
        return MSPPOSIXAwkParsedProgram(blocks: blocks, functions: functions)
    }

    private static func splitProgramPrefix(_ text: String) -> (segments: [String], endedWithSeparator: Bool) {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var regex = false
        var parenDepth = 0
        var bracketDepth = 0
        var previousNonWhitespace: Character?
        var endedWithSeparator = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                current.append(character)
                if character == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        current.append(text[next])
                        index = next
                    }
                } else if character == activeQuote {
                    quote = nil
                }
                index = text.index(after: index)
                continue
            }
            if regex {
                current.append(character)
                if character == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        current.append(text[next])
                        index = next
                    }
                } else if character == "/" {
                    regex = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                endedWithSeparator = false
            } else if character == "/", MSPPOSIXAwkSyntax.isRegexStart(previousNonWhitespace) {
                regex = true
                current.append(character)
                endedWithSeparator = false
            } else if character == "(" {
                parenDepth += 1
                current.append(character)
                endedWithSeparator = false
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
                endedWithSeparator = false
            } else if character == "[" {
                bracketDepth += 1
                current.append(character)
                endedWithSeparator = false
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
                endedWithSeparator = false
            } else if parenDepth == 0, bracketDepth == 0, (character == ";" || character == "\n") {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(trimmed)
                }
                current = ""
                endedWithSeparator = true
            } else {
                current.append(character)
                if !character.isWhitespace {
                    endedWithSeparator = false
                }
            }
            if !character.isWhitespace {
                previousNonWhitespace = character
            }
            index = text.index(after: index)
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(trimmed)
        }
        return (segments, endedWithSeparator)
    }

    private static func extractFunctions(from source: inout String) throws -> [String: MSPPOSIXAwkRunner.UserFunction] {
        var result: [String: MSPPOSIXAwkRunner.UserFunction] = [:]
        var cursor = source.startIndex
        while let range = source.range(of: "function", range: cursor..<source.endIndex) {
            guard MSPPOSIXAwkSyntax.isWordBoundary(source, before: range.lowerBound),
                  MSPPOSIXAwkSyntax.isWordBoundary(source, after: range.upperBound) else {
                cursor = range.upperBound
                continue
            }
            var index = range.upperBound
            MSPPOSIXAwkSyntax.skipWhitespace(in: source, index: &index)
            let nameStart = index
            while index < source.endIndex, MSPPOSIXAwkSyntax.isIdentifierBody(source[index]) {
                index = source.index(after: index)
            }
            let name = String(source[nameStart..<index])
            guard !name.isEmpty else { throw MSPPOSIXAwkError.usage("awk: malformed function") }
            MSPPOSIXAwkSyntax.skipWhitespace(in: source, index: &index)
            guard index < source.endIndex, source[index] == "(" else {
                throw MSPPOSIXAwkError.usage("awk: malformed function \(name)")
            }
            let paramsClose = try MSPPOSIXAwkSyntax.matchingParen(in: source, open: index)
            let paramsText = String(source[source.index(after: index)..<paramsClose])
            let params = MSPPOSIXAwkSyntax.splitTopLevel(paramsText, separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            index = source.index(after: paramsClose)
            MSPPOSIXAwkSyntax.skipWhitespace(in: source, index: &index)
            guard index < source.endIndex, source[index] == "{" else {
                throw MSPPOSIXAwkError.usage("awk: malformed function \(name)")
            }
            let bodyClose = try matchingBrace(in: source, open: index)
            let body = String(source[source.index(after: index)..<bodyClose])
            result[name] = MSPPOSIXAwkRunner.UserFunction(parameters: params, body: body)
            let removal = range.lowerBound..<source.index(after: bodyClose)
            source.removeSubrange(removal)
            cursor = source.startIndex
        }
        return result
    }

    private static func matchingBrace(in text: String, open: String.Index) throws -> String.Index {
        try MSPPOSIXAwkSyntax.matchingPair(in: text, open: open, openCharacter: "{", closeCharacter: "}")
    }
}
