import Foundation

package enum MSPShellParameterExpansionSyntax {
    package struct ArraySubscript: Equatable {
        package var name: String
        package var key: String
    }

    package struct ArraySplat: Equatable {
        package var name: String
        package var mode: String
    }

    package struct ParameterSubstring: Equatable {
        package var name: String
        package var offset: String
        package var length: String?
    }

    package struct ParameterOperationWord: Equatable {
        package var rawText: String
        var word: ShellWord

        package var isEmpty: Bool {
            rawText.isEmpty
        }
    }

    package enum ParameterForm: Equatable {
        case special(name: String)
        case length(ParameterLength)
        case arrayValues(name: String)
        case arrayIndices(name: String)
        case operation(name: String, operation: ParameterOperation)
        case substring(ParameterSubstring)
        case arraySubscript(ArraySubscript)
        case plain(name: String)
        case badSubstitution
    }

    package enum ParameterLength: Equatable {
        case arrayCount(name: String)
        case nested(expression: String)
        case reference(name: String)
    }

    package enum ParameterOperation: Equatable {
        case defaultValue(word: ParameterOperationWord, checkEmpty: Bool)
        case assignDefault(word: ParameterOperationWord, checkEmpty: Bool)
        case errorIfUnset(word: ParameterOperationWord, checkEmpty: Bool)
        case useAlternative(word: ParameterOperationWord, checkEmpty: Bool)
        case lowercaseFirst
        case lowercaseAll
        case uppercaseFirst
        case uppercaseAll
        case replacement(pattern: String, replacement: String, global: Bool)
        case removePrefix(pattern: String, longest: Bool)
        case removeSuffix(pattern: String, longest: Bool)
    }

    package static func parameterForm(_ expression: String, grammar: MSPShellGrammar) -> ParameterForm {
        if isSpecialParameterReference(expression) {
            return .special(name: expression)
        }
        if expression.hasPrefix("#") {
            let countedExpression = String(expression.dropFirst())
            if countedExpression.hasSuffix("[@]") || countedExpression.hasSuffix("[*]") {
                let name = String(countedExpression.dropLast(3))
                if MSPShellExpansionScanner.isShellVariableName(name) {
                    guard grammar.expansion.arrayParameterExpansion else {
                        return .badSubstitution
                    }
                    return .length(.arrayCount(name: name))
                }
            }
            if arraySubscriptExpression(countedExpression) != nil {
                guard grammar.expansion.arrayParameterExpansion else {
                    return .badSubstitution
                }
                return .length(.nested(expression: countedExpression))
            }
            if isParameterReference(countedExpression, grammar: grammar) {
                return .length(.reference(name: countedExpression))
            }
        }
        if let splat = arraySplatExpression(expression) {
            guard grammar.expansion.arrayParameterExpansion else {
                return .badSubstitution
            }
            return .arrayValues(name: splat.name)
        }
        if expression.hasPrefix("!"),
           let splat = arraySplatExpression(String(expression.dropFirst())) {
            guard grammar.expansion.arrayParameterExpansion else {
                return .badSubstitution
            }
            return .arrayIndices(name: splat.name)
        }
        if expression.hasPrefix("!"), grammar.target == .debianDash12 {
            return .badSubstitution
        }
        if let operation = alternativeOperation(expression, grammar: grammar) {
            return operation
        }
        if let substring = substringExpression(expression) {
            guard grammar.expansion.parameterSubstring else {
                return .badSubstitution
            }
            return .substring(substring)
        }
        if let operation = caseModificationOperation(expression) {
            guard grammar.expansion.parameterCaseModification else {
                return .badSubstitution
            }
            return operation
        }
        if let operation = replacementOperation(expression, grammar: grammar) {
            guard grammar.expansion.parameterReplacement else {
                return .badSubstitution
            }
            return operation
        }
        if let subscriptExpression = arraySubscriptExpression(expression) {
            guard grammar.expansion.arrayParameterExpansion else {
                return .badSubstitution
            }
            return .arraySubscript(subscriptExpression)
        }
        if let operation = removalOperation(expression, grammar: grammar) {
            return operation
        }
        return .plain(name: expression)
    }

    package static func arraySplatExpression(_ expression: String) -> ArraySplat? {
        guard expression.hasSuffix("[@]") || expression.hasSuffix("[*]") else {
            return nil
        }
        let name = String(expression.dropLast(3))
        guard MSPShellExpansionScanner.isShellVariableName(name),
              let mode = expression.dropLast().last else {
            return nil
        }
        return ArraySplat(name: name, mode: String(mode))
    }

    static func substringExpression(_ expression: String) -> ParameterSubstring? {
        guard let separator = topLevelSubstringSeparator(in: expression) else {
            return nil
        }
        let name = String(expression[..<separator])
        guard isParameterReference(name) else { return nil }
        let fieldsStart = expression.index(after: separator)
        let fields = substringFields(in: expression, startingAt: fieldsStart)
        guard !fields.offset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ParameterSubstring(name: name, offset: fields.offset, length: fields.length)
    }

    private static func substringFields(
        in expression: String,
        startingAt start: String.Index
    ) -> (offset: String, length: String?) {
        if let lengthSeparator = topLevelSubstringSeparator(in: expression, startingAt: start) {
            return (
                String(expression[start..<lengthSeparator]),
                String(expression[expression.index(after: lengthSeparator)...])
            )
        }
        return (String(expression[start...]), nil)
    }

    private static func topLevelSubstringSeparator(
        in expression: String,
        startingAt start: String.Index? = nil
    ) -> String.Index? {
        var index = start ?? expression.startIndex
        var bracketDepth = 0
        var braceDepth = 0
        var parenDepth = 0
        var quote: Character?
        while index < expression.endIndex {
            let character = expression[index]
            if let activeQuote = quote {
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex {
                        index = expression.index(after: index)
                    }
                    continue
                }
                if character == activeQuote {
                    quote = nil
                }
                index = expression.index(after: index)
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case ":" where bracketDepth == 0 && braceDepth == 0 && parenDepth == 0:
                let next = expression.index(after: index)
                if start == nil,
                   next < expression.endIndex,
                   ["-", "=", "+", "?"].contains(String(expression[next])) {
                    break
                }
                return index
            default:
                break
            }
            index = expression.index(after: index)
        }
        return nil
    }

    private static func alternativeOperation(_ expression: String, grammar: MSPShellGrammar) -> ParameterForm? {
        let operators = [":-", ":=", ":+", ":?", "-", "=", "+", "?"]
        var index = expression.startIndex
        var subscriptDepth = 0
        while index < expression.endIndex {
            let character = expression[index]
            if character == "[" {
                subscriptDepth += 1
                index = expression.index(after: index)
                continue
            }
            if character == "]" {
                subscriptDepth = max(0, subscriptDepth - 1)
                index = expression.index(after: index)
                continue
            }
            if subscriptDepth == 0 {
                for operatorText in operators where expression[index...].hasPrefix(operatorText) {
                    let name = String(expression[..<index])
                    guard isParameterReference(name, grammar: grammar) else { continue }
                    let wordStart = expression.index(index, offsetBy: operatorText.count)
                    let word = parameterOperationWord(String(expression[wordStart...]), grammar: grammar)
                    switch operatorText {
                    case ":-":
                        return .operation(name: name, operation: .defaultValue(word: word, checkEmpty: true))
                    case "-":
                        return .operation(name: name, operation: .defaultValue(word: word, checkEmpty: false))
                    case ":=":
                        return .operation(name: name, operation: .assignDefault(word: word, checkEmpty: true))
                    case "=":
                        return .operation(name: name, operation: .assignDefault(word: word, checkEmpty: false))
                    case ":?":
                        return .operation(name: name, operation: .errorIfUnset(word: word, checkEmpty: true))
                    case "?":
                        return .operation(name: name, operation: .errorIfUnset(word: word, checkEmpty: false))
                    case ":+":
                        return .operation(name: name, operation: .useAlternative(word: word, checkEmpty: true))
                    case "+":
                        return .operation(name: name, operation: .useAlternative(word: word, checkEmpty: false))
                    default:
                        break
                    }
                }
            }
            index = expression.index(after: index)
        }
        return nil
    }

    private static func parameterOperationWord(
        _ text: String,
        grammar: MSPShellGrammar
    ) -> ParameterOperationWord {
        var word = ShellWord()
        var index = text.startIndex
        var quote: Character?
        var quoteStartPartCount = 0
        var quoteStartRawTextCount = 0

        func markQuoteStart() {
            word.markQuoted()
            quoteStartPartCount = word.parts.count
            quoteStartRawTextCount = word.rawText.count
        }

        func appendEmptyQuoteIfNeeded() {
            guard word.parts.count == quoteStartPartCount,
                  word.rawText.count == quoteStartRawTextCount else {
                return
            }
            word.appendEmptyQuotedFragment()
        }

        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    appendEmptyQuoteIfNeeded()
                    quote = nil
                    index = text.index(after: index)
                    continue
                }
                if character == "\\" && activeQuote == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        if text[next] == "\n" {
                            index = text.index(after: next)
                            continue
                        }
                        if MSPShellLexerSubstitutionScanner.doubleQuoteEscapableCharacters.contains(text[next]) {
                            word.append(text[next], expandable: false, quoted: true)
                        } else {
                            word.append(character, expandable: false, quoted: true)
                            word.append(text[next], expandable: false, quoted: true)
                        }
                        index = text.index(after: next)
                    } else {
                        word.append(character, expandable: false, quoted: true)
                        index = next
                    }
                    continue
                }
                if activeQuote == "\"",
                   let substitution = parameterOperationBracedParameterText(in: text, startingAt: index, grammar: grammar) {
                    word.append(substitution.text, expandable: true, quoted: true)
                    index = substitution.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   let substitution = parameterOperationCommandOrArithmeticText(in: text, startingAt: index, grammar: grammar) {
                    word.append(substitution.text, expandable: true, quoted: true)
                    index = substitution.nextIndex
                    continue
                }
                if activeQuote == "\"", character == "`",
                   let substitution = try? MSPShellLexerSubstitutionScanner.backtickSubstitutionText(
                        in: text,
                        startingAt: index
                   ) {
                    word.append(substitution.text, expandable: true, quoted: true)
                    index = substitution.nextIndex
                    continue
                }
                word.append(character, expandable: activeQuote != "'", quoted: true)
                index = text.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                markQuoteStart()
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "'" {
                if grammar.recognizesAnsiCQuote(in: .parameterOperationWord),
                   let quoted = try? MSPShellAnsiCQuote.quotedText(in: text, startingAt: index) {
                    word.markQuoted()
                    if quoted.text.isEmpty {
                        word.appendEmptyQuotedFragment()
                    } else {
                        word.append(quoted.text, expandable: false, quoted: true)
                    }
                    index = quoted.nextIndex
                    continue
                }
            }
            if let substitution = parameterOperationBracedParameterText(in: text, startingAt: index, grammar: grammar) {
                word.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }
            if let substitution = parameterOperationCommandOrArithmeticText(in: text, startingAt: index, grammar: grammar) {
                word.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }
            if character == "`",
               let substitution = try? MSPShellLexerSubstitutionScanner.backtickSubstitutionText(
                    in: text,
                    startingAt: index
               ) {
                word.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }
            if (character == "<" || character == ">"),
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                let mode: MSPShellProcessSubstitutionMode = character == "<" ? .input : .output
                if grammar.recognizesProcessSubstitution(in: .parameterOperationWord),
                   let substitution = try? MSPShellLexerProcessSubstitutionScanner.processSubstitutionText(
                    in: text,
                    startingAt: index,
                    mode: mode,
                    grammar: grammar
                ) {
                    word.append(substitution.text, expandable: true)
                    index = substitution.nextIndex
                    continue
                }
            }
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    if text[next] != "\n" {
                        word.append(text[next], expandable: false, quoted: true)
                    }
                    index = text.index(after: next)
                } else {
                    word.append(character, expandable: false, quoted: true)
                    index = next
                }
                continue
            }

            word.append(character, expandable: true)
            index = text.index(after: index)
        }

        if word.isEmpty {
            word.markPresent()
        }
        return ParameterOperationWord(rawText: text, word: word)
    }

    private static func parameterOperationBracedParameterText(
        in text: String,
        startingAt index: String.Index,
        grammar: MSPShellGrammar
    ) -> (text: String, nextIndex: String.Index)? {
        guard index < text.endIndex,
              text[index] == "$",
              text.index(after: index) < text.endIndex,
              text[text.index(after: index)] == "{" else {
            return nil
        }
        return try? MSPShellLexerSubstitutionScanner.bracedParameterExpansionText(
            in: text,
            startingAt: index,
            grammar: grammar
        )
    }

    private static func parameterOperationCommandOrArithmeticText(
        in text: String,
        startingAt index: String.Index,
        grammar: MSPShellGrammar
    ) -> (text: String, nextIndex: String.Index)? {
        guard index < text.endIndex,
              text[index] == "$",
              text.index(after: index) < text.endIndex,
              text[text.index(after: index)] == "(" else {
            return nil
        }
        let next = text.index(after: index)
        if text.index(next, offsetBy: 1, limitedBy: text.index(before: text.endIndex)) != nil,
           text[text.index(after: next)] == "(" {
            return try? MSPShellLexerSubstitutionScanner.arithmeticExpansionText(in: text, startingAt: index)
        }
        return try? MSPShellLexerSubstitutionScanner.commandSubstitutionText(
            in: text,
            startingAt: index,
            grammar: grammar
        )
    }

    private static func caseModificationOperation(_ expression: String) -> ParameterForm? {
        for operatorText in [",,", ",", "^^", "^"] where expression.hasSuffix(operatorText) {
            let name = String(expression.dropLast(operatorText.count))
            if isParameterReference(name) {
                switch operatorText {
                case ",,":
                    return .operation(name: name, operation: .lowercaseAll)
                case ",":
                    return .operation(name: name, operation: .lowercaseFirst)
                case "^^":
                    return .operation(name: name, operation: .uppercaseAll)
                case "^":
                    return .operation(name: name, operation: .uppercaseFirst)
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func removalOperation(_ expression: String, grammar: MSPShellGrammar) -> ParameterForm? {
        let operators = ["##", "%%", "#", "%"]
        var index = expression.startIndex
        var subscriptDepth = 0
        while index < expression.endIndex {
            let character = expression[index]
            if character == "[" {
                subscriptDepth += 1
                index = expression.index(after: index)
                continue
            }
            if character == "]" {
                subscriptDepth = max(0, subscriptDepth - 1)
                index = expression.index(after: index)
                continue
            }
            if subscriptDepth == 0 {
                for operatorText in operators where expression[index...].hasPrefix(operatorText) {
                    let name = String(expression[..<index])
                    guard isParameterReference(name, grammar: grammar) else { continue }
                    let patternStart = expression.index(index, offsetBy: operatorText.count)
                    let pattern = String(expression[patternStart...])
                    switch operatorText {
                    case "##":
                        return .operation(name: name, operation: .removePrefix(pattern: pattern, longest: true))
                    case "#":
                        return .operation(name: name, operation: .removePrefix(pattern: pattern, longest: false))
                    case "%%":
                        return .operation(name: name, operation: .removeSuffix(pattern: pattern, longest: true))
                    case "%":
                        return .operation(name: name, operation: .removeSuffix(pattern: pattern, longest: false))
                    default:
                        break
                    }
                }
            }
            index = expression.index(after: index)
        }
        return nil
    }

    private static func replacementOperation(_ expression: String, grammar: MSPShellGrammar) -> ParameterForm? {
        let operators = ["//", "/"]
        for operatorText in operators {
            guard let operatorRange = expression.range(of: operatorText) else { continue }
            let name = String(expression[..<operatorRange.lowerBound])
            guard name.allSatisfy(\.isNumber) || MSPShellExpansionScanner.isShellVariableName(name) else { continue }
            guard grammar.expansion.parameterReplacement else {
                return .badSubstitution
            }
            let rest = String(expression[operatorRange.upperBound...])
            let separator = rest.firstIndex(of: "/")
            let pattern = separator.map { String(rest[..<$0]) } ?? rest
            let replacement = separator.map { String(rest[rest.index(after: $0)...]) } ?? ""
            return .operation(
                name: name,
                operation: .replacement(
                    pattern: pattern,
                    replacement: replacement,
                    global: operatorText == "//"
                )
            )
        }
        return nil
    }

    package static func arraySubscriptExpression(_ expression: String) -> ArraySubscript? {
        guard let open = expression.firstIndex(of: "["),
              expression.hasSuffix("]") else {
            return nil
        }
        let name = String(expression[..<open])
        guard MSPShellExpansionScanner.isShellVariableName(name) else { return nil }
        let close = expression.index(before: expression.endIndex)
        return ArraySubscript(name: name, key: String(expression[expression.index(after: open)..<close]))
    }

    static func isParameterReference(_ expression: String) -> Bool {
        isParameterReference(expression, grammar: .msp)
    }

    static func isParameterReference(_ expression: String, grammar: MSPShellGrammar) -> Bool {
        guard !expression.isEmpty else { return false }
        if expression.allSatisfy(\.isNumber) {
            return true
        }
        if ["#", "?", "@", "*"].contains(expression) {
            return true
        }
        if MSPShellExpansionScanner.isShellVariableName(expression) {
            return true
        }
        guard grammar.expansion.arrayParameterExpansion else {
            return false
        }
        return arraySubscriptExpression(expression) != nil
    }

    private static func isSpecialParameterReference(_ expression: String) -> Bool {
        expression.allSatisfy(\.isNumber) || ["#", "?", "@", "*"].contains(expression)
    }
}
