import Foundation

enum MSPShellHereDocumentPreprocessor {
    private struct HereDocumentSpec {
        var delimiter: String
        var expandable: Bool
        var stripsLeadingTabs: Bool
        var sourceRange: Range<String.Index>
    }

    private struct HereDocumentDelimiter {
        var value: String
        var expandable: Bool
        var nextIndex: String.Index
    }

    static func commandWithEncodedHereDocuments(
        _ command: String,
        grammar: MSPShellGrammar
    ) throws -> String {
        var output = ""
        var index = command.startIndex

        while index < command.endIndex {
            let header = logicalCommandHeader(in: command, startingAt: index)
            let headerText = String(command[header.range])
            let specs = try hereDocumentSpecs(in: headerText, grammar: grammar)
            guard !specs.isEmpty else {
                output += headerText
                if header.hasTerminatingNewline {
                    output.append("\n")
                }
                index = header.nextIndex
                continue
            }

            guard header.hasTerminatingNewline else {
                let wanted = specs.first?.delimiter ?? ""
                throw ShellExit.usage("<<: here-document delimited by end-of-file (wanted \(wanted))")
            }

            index = header.nextIndex
            var bodies: [String] = []
            for spec in specs {
                let body = try readHereDocumentBody(
                    in: command,
                    startingAt: &index,
                    spec: spec
                )
                bodies.append(body)
            }

            output += lineReplacingHereDocuments(headerText, specs: specs, bodies: bodies)
            output.append("\n")
        }

        return output
    }

    private static func logicalCommandHeader(
        in command: String,
        startingAt start: String.Index
    ) -> (range: Range<String.Index>, hasTerminatingNewline: Bool, nextIndex: String.Index) {
        var index = start
        var quote: Character?

        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = command.index(after: index)
                    continue
                }
                if activeQuote == "\"", character == "\\" {
                    let next = command.index(after: index)
                    index = next < command.endIndex ? command.index(after: next) : next
                    continue
                }
                index = command.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == "\n" {
                return (start..<index, true, command.index(after: index))
            }
            index = command.index(after: index)
        }

        return (start..<command.endIndex, false, command.endIndex)
    }

    private static func readHereDocumentBody(
        in command: String,
        startingAt index: inout String.Index,
        spec: HereDocumentSpec
    ) throws -> String {
        var bodyLines: [String] = []
        while index < command.endIndex {
            let lineStart = index
            var lineEnd = index
            while lineEnd < command.endIndex, command[lineEnd] != "\n" {
                lineEnd = command.index(after: lineEnd)
            }
            let rawBodyLine = String(command[lineStart..<lineEnd])
            let nextIndex = lineEnd < command.endIndex
                ? command.index(after: lineEnd)
                : lineEnd
            let terminatorCandidate = spec.stripsLeadingTabs
                ? String(rawBodyLine.drop { $0 == "\t" })
                : rawBodyLine
            if terminatorCandidate == spec.delimiter {
                index = nextIndex
                return bodyLines.isEmpty ? "" : bodyLines.joined(separator: "\n") + "\n"
            }
            let bodyLine = spec.stripsLeadingTabs
                ? String(rawBodyLine.drop { $0 == "\t" })
                : rawBodyLine
            bodyLines.append(bodyLine)
            index = nextIndex
        }

        throw ShellExit.usage("<<: here-document delimited by end-of-file (wanted \(spec.delimiter))")
    }

    private static func hereDocumentSpecs(
        in line: String,
        grammar: MSPShellGrammar
    ) throws -> [HereDocumentSpec] {
        var specs: [HereDocumentSpec] = []
        var index = line.startIndex
        var quote: Character?
        while index < line.endIndex {
            let character = line[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\" {
                    let next = line.index(after: index)
                    index = next < line.endIndex ? line.index(after: next) : next
                    continue
                }
                index = line.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = line.index(after: index)
                continue
            }
            if let skipped = nonRedirectionOperatorContextEnd(in: line, startingAt: index, grammar: grammar) {
                index = skipped
                continue
            }
            guard character == "<" else {
                index = line.index(after: index)
                continue
            }
            let second = line.index(after: index)
            guard second < line.endIndex, line[second] == "<" else {
                index = second
                continue
            }
            let third = line.index(after: second)
            guard third >= line.endIndex || line[third] != "<" else {
                index = third
                continue
            }

            var cursor = third
            var stripsLeadingTabs = false
            if cursor < line.endIndex, line[cursor] == "-" {
                stripsLeadingTabs = true
                cursor = line.index(after: cursor)
            }
            while cursor < line.endIndex, line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            let delimiter = try hereDocumentDelimiter(in: line, startingAt: cursor, grammar: grammar)
            cursor = delimiter.nextIndex
            guard !delimiter.value.isEmpty else {
                index = cursor
                continue
            }
            guard !delimiter.value.hasPrefix(MSPShellHereDocumentMarker.prefix) else {
                index = cursor
                continue
            }
            specs.append(HereDocumentSpec(
                delimiter: delimiter.value,
                expandable: delimiter.expandable,
                stripsLeadingTabs: stripsLeadingTabs,
                sourceRange: index..<cursor
            ))
            index = cursor
        }
        return specs
    }

    private static func hereDocumentDelimiter(
        in line: String,
        startingAt start: String.Index,
        grammar: MSPShellGrammar
    ) throws -> HereDocumentDelimiter {
        var cursor = start
        var value = ""
        var expandable = true
        var quote: Character?

        while cursor < line.endIndex {
            let character = line[cursor]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    cursor = line.index(after: cursor)
                    continue
                }
                value.append(character)
                cursor = line.index(after: cursor)
                continue
            }

            if character == "'" || character == "\"" {
                expandable = false
                quote = character
                cursor = line.index(after: cursor)
                continue
            }
            if grammar.recognizesAnsiCQuote(in: .hereDocumentDelimiter), character == "$" {
                let next = line.index(after: cursor)
                if next < line.endIndex, line[next] == "'" {
                    let quoted = try MSPShellAnsiCQuote.quotedText(in: line, startingAt: cursor)
                    expandable = false
                    value += quoted.text
                    cursor = quoted.nextIndex
                    continue
                }
                if next < line.endIndex, line[next] == "\"" {
                    expandable = false
                    quote = "\""
                    cursor = line.index(after: next)
                    continue
                }
            }
            if character == "\\" {
                expandable = false
                let next = line.index(after: cursor)
                guard next < line.endIndex else {
                    cursor = next
                    continue
                }
                value.append(line[next])
                cursor = line.index(after: next)
                continue
            }
            if character.isWhitespace || character == ";" || character == "|" || character == "&" {
                break
            }
            value.append(character)
            cursor = line.index(after: cursor)
        }

        return HereDocumentDelimiter(value: value, expandable: expandable, nextIndex: cursor)
    }

    private static func nonRedirectionOperatorContextEnd(
        in line: String,
        startingAt index: String.Index,
        grammar: MSPShellGrammar
    ) -> String.Index? {
        let character = line[index]
        if character == "$",
           line.index(after: index) < line.endIndex,
           line[line.index(after: index)] == "(" {
            let openIndex = line.index(after: index)
            let bodyStart = line.index(after: openIndex)
            if bodyStart < line.endIndex, line[bodyStart] == "(" {
                return try? MSPShellLexerSubstitutionScanner.arithmeticExpansionText(
                    in: line,
                    startingAt: index
                ).nextIndex
            }
        }

        if grammar.lexical.arithmeticCommand,
           character == "(",
           line.index(after: index) < line.endIndex,
           line[line.index(after: index)] == "(" {
            return try? MSPShellLexerSubstitutionScanner.arithmeticCommandText(
                in: line,
                startingAt: index,
                grammar: grammar
            ).nextIndex
        }

        if grammar.lexical.doubleBracketConditional,
           character == "[",
           line.index(after: index) < line.endIndex,
           line[line.index(after: index)] == "[" {
            return doubleBracketConditionalEnd(in: line, startingAt: index)
        }

        return nil
    }

    private static func doubleBracketConditionalEnd(
        in line: String,
        startingAt start: String.Index
    ) -> String.Index? {
        var index = line.index(start, offsetBy: 2)
        var quote: Character?
        while index < line.endIndex {
            let character = line[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = line.index(after: index)
                    continue
                }
                if activeQuote == "\"", character == "\\" {
                    let next = line.index(after: index)
                    index = next < line.endIndex ? line.index(after: next) : next
                    continue
                }
                index = line.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index = line.index(after: index)
                continue
            }
            if character == "\\" {
                let next = line.index(after: index)
                index = next < line.endIndex ? line.index(after: next) : next
                continue
            }
            if character == "]" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "]" {
                    return line.index(after: next)
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func lineReplacingHereDocuments(_ line: String, specs: [HereDocumentSpec], bodies: [String]) -> String {
        var output = ""
        var cursor = line.startIndex
        for (offset, spec) in specs.enumerated() {
            output += line[cursor..<spec.sourceRange.lowerBound]
            let body = offset < bodies.count ? bodies[offset] : ""
            let encoded = encodeHereDocumentPlaceholder(body: body, expandable: spec.expandable)
            output += "\(spec.stripsLeadingTabs ? "<<-" : "<<")\(encoded)"
            cursor = spec.sourceRange.upperBound
        }
        output += line[cursor...]
        return output
    }

    private static func encodeHereDocumentPlaceholder(body: String, expandable: Bool) -> String {
        MSPShellHereDocumentMarker.encoded(body: body, expandable: expandable)
    }
}
