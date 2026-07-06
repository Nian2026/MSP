import Foundation

enum ShellParserDiagnostic {
    case danglingListOperator
    case expected(String)
    case scopedUnexpectedControlOperator(String)
    case missingCommandAfterPipe
    case missingCommandAtNewline
    case missingRedirectionTarget(String)
    case unexpectedControlOperator
    case unexpectedGroupEnd
    case unexpectedGroupStart
    case unexpectedReservedWord(String)
    case unexpectedToken(String)

    var message: String {
        switch self {
        case .danglingListOperator:
            return "syntax error near unexpected token `newline'"
        case .expected(let token):
            return "syntax error: expected \(token)"
        case .scopedUnexpectedControlOperator(let scope):
            return "\(scope): syntax error near unexpected shell control operator"
        case .missingCommandAfterPipe:
            return "|: missing command"
        case .missingCommandAtNewline:
            return "syntax error near unexpected token `newline'"
        case .missingRedirectionTarget(let operatorText):
            return "\(operatorText): missing redirection target"
        case .unexpectedControlOperator:
            return "syntax error near unexpected shell control operator"
        case .unexpectedGroupEnd:
            return "syntax error near unexpected )"
        case .unexpectedGroupStart:
            return "syntax error near unexpected ("
        case .unexpectedReservedWord(let word):
            return "syntax error near unexpected token `\(word)'"
        case .unexpectedToken(let token):
            return "syntax error near unexpected token `\(token)'"
        }
    }
}

func mspShellParserUsage(_ diagnostic: ShellParserDiagnostic) -> ShellExit {
    ShellExit.usage(diagnostic.message)
}

enum ShellTokenClassifier {
    enum CommandListTokenRole: Equatable {
        case commandStart
        case alwaysSeparator(ShellListSeparator)
        case listOperator(ShellListSeparator)
        case pipelineSeparator
        case caseTerminator(ShellCaseTerminator)
        case groupEnd
    }

    static func wordLike(_ token: ShellToken) -> ShellWord? {
        switch token {
        case .word(let word):
            return word
        case .assignmentWord(_, original: let word):
            return word
        case .reservedWord(_, original: let word):
            return word
        case .arithmeticCommand, .redirectionOperator, .pipe(_), .separator, .caseTerminator(_), .groupStart, .groupEnd:
            return nil
        }
    }

    static func wordLike(in tokens: [ShellToken], at index: Int) -> ShellWord? {
        guard index < tokens.count else { return nil }
        return wordLike(tokens[index])
    }

    static func reservedWord(in tokens: [ShellToken], at index: Int) -> ShellReservedWord? {
        guard index < tokens.count,
              case .reservedWord(let word, _) = tokens[index] else {
            return nil
        }
        return word
    }

    static func isUnquotedWord(_ word: ShellWord, _ value: String) -> Bool {
        word.rawText == value && isFullyUnquoted(word)
    }

    static func isFullyUnquoted(_ word: ShellWord) -> Bool {
        word.parts.allSatisfy { !$0.isQuoted }
    }

    static func isFunctionName(_ value: String) -> Bool {
        mspShellVariableName(value)
    }

    static func isFunctionDefinitionStart(
        in tokens: [ShellToken],
        at startIndex: Int,
        grammar: MSPShellGrammar
    ) -> Bool {
        functionDefinitionBodyStartIndex(in: tokens, at: startIndex, grammar: grammar) != nil
    }

    static func functionDefinitionBodyStartIndex(
        in tokens: [ShellToken],
        at startIndex: Int,
        grammar: MSPShellGrammar
    ) -> Int? {
        if startIndex + 1 < tokens.count,
           grammar.parser.functionReservedWordDefinition,
           reservedWord(in: tokens, at: startIndex) == .function,
           case .word(let nameWord) = tokens[startIndex + 1],
           isFunctionName(nameWord.rawText),
           isFullyUnquoted(nameWord) {
            var bodyIndex = startIndex + 2
            if bodyIndex + 1 < tokens.count,
               case .groupStart = tokens[bodyIndex],
               case .groupEnd = tokens[bodyIndex + 1] {
                bodyIndex += 2
            }
            bodyIndex = indexAfterFunctionDefinitionNewlines(in: tokens, at: bodyIndex)
            return isFunctionBodyStart(in: tokens, at: bodyIndex) ? bodyIndex : nil
        }
        guard startIndex + 3 < tokens.count,
              case .word(let nameWord) = tokens[startIndex],
              isFunctionName(nameWord.rawText),
              isFullyUnquoted(nameWord),
              case .groupStart = tokens[startIndex + 1],
              case .groupEnd = tokens[startIndex + 2] else {
            return nil
        }
        let bodyIndex = indexAfterFunctionDefinitionNewlines(in: tokens, at: startIndex + 3)
        return isFunctionBodyStart(in: tokens, at: bodyIndex) ? bodyIndex : nil
    }

    private static func indexAfterFunctionDefinitionNewlines(
        in tokens: [ShellToken],
        at startIndex: Int
    ) -> Int {
        var index = startIndex
        while index < tokens.count {
            guard case .separator(.newline) = tokens[index] else { break }
            index += 1
        }
        return index
    }

    private static func isFunctionBodyStart(in tokens: [ShellToken], at index: Int) -> Bool {
        guard index < tokens.count else { return false }
        if reservedWord(in: tokens, at: index) == .leftBrace {
            return true
        }
        if case .groupStart = tokens[index] {
            return true
        }
        return false
    }

    static func isCompoundStartReservedWord(_ word: ShellReservedWord) -> Bool {
        switch word {
        case .ifWord, .whileWord, .until, .forWord, .caseWord:
            return true
        case .then, .elseWord, .elif, .fi, .doWord, .done, .esac, .inWord, .function, .leftBrace, .rightBrace, .bang:
            return false
        }
    }

    static func isCompoundEndReservedWord(_ word: ShellReservedWord) -> Bool {
        switch word {
        case .fi, .done, .esac:
            return true
        case .ifWord, .then, .elseWord, .elif, .forWord, .whileWord, .until, .doWord, .caseWord, .inWord, .function, .leftBrace, .rightBrace, .bang:
            return false
        }
    }

    static func isControlReservedWord(_ word: ShellReservedWord) -> Bool {
        switch word {
        case .then, .doWord, .elseWord, .elif, .inWord, .leftBrace:
            return true
        case .ifWord, .fi, .forWord, .whileWord, .until, .done, .caseWord, .esac, .function, .rightBrace, .bang:
            return false
        }
    }

    static func commandPositionAfterCompoundStart(_ word: ShellReservedWord) -> Bool {
        word == .ifWord || word == .whileWord || word == .until
    }

    static func commandListRole(_ token: ShellToken) -> CommandListTokenRole {
        switch token {
        case .separator(let separator) where separator.isCommandTerminator:
            return .alwaysSeparator(separator)
        case .separator(let separator):
            return .listOperator(separator)
        case .pipe(_):
            return .pipelineSeparator
        case .caseTerminator(let terminator):
            return .caseTerminator(terminator)
        case .groupEnd:
            return .groupEnd
        case .word, .assignmentWord, .reservedWord, .arithmeticCommand, .redirectionOperator, .groupStart:
            return .commandStart
        }
    }

    static func isSimpleCommandBoundary(_ token: ShellToken) -> Bool {
        switch token {
        case .arithmeticCommand, .pipe(_), .separator, .caseTerminator(_), .groupStart, .groupEnd:
            return true
        case .word, .assignmentWord, .reservedWord, .redirectionOperator:
            return false
        }
    }
}

struct ShellCompoundTokenStops {
    var reservedWords: Set<ShellReservedWord> = []
    var words: Set<String> = []
    var caseTerminator = false
    var groupEnd = false
}

enum ShellCompoundTokenStop: Equatable {
    case reservedWord(ShellReservedWord)
    case word(String)
    case caseTerminator(ShellCaseTerminator)
    case groupEnd
}

struct ShellCompoundTokenScanResult {
    var tokens: [ShellToken]
    var stop: ShellCompoundTokenStop
    var index: Int
}

private struct ShellCasePatternScanContext {
    var depth: Int
    var awaitingIn: Bool
    var readingPattern: Bool
}

struct ShellCompoundTokenScanner {
    var tokens: [ShellToken]
    var index: Int
    var grammar: MSPShellGrammar

    mutating func collect(
        until stops: ShellCompoundTokenStops,
        missingMessage: String,
        consumeBudget: () throws -> Void
    ) throws -> ShellCompoundTokenScanResult {
        var collected: [ShellToken] = []
        var nestedDepth = 0
        var groupDepth = 0
        var commandPosition = true
        var commandPositionAfterRedirectionTarget: Bool?
        var pendingFunctionBodyBrace = false
        var casePatternContexts: [ShellCasePatternScanContext] = []

        func activeCasePatternContextIndex() -> Int? {
            casePatternContexts.lastIndex { $0.depth == nestedDepth }
        }

        func isReadingCasePattern() -> Bool {
            guard let contextIndex = activeCasePatternContextIndex() else { return false }
            return casePatternContexts[contextIndex].readingPattern
        }

        func beginCasePatternIfAwaitingIn() {
            guard let contextIndex = activeCasePatternContextIndex(),
                  casePatternContexts[contextIndex].awaitingIn else {
                return
            }
            casePatternContexts[contextIndex].awaitingIn = false
            casePatternContexts[contextIndex].readingPattern = true
        }

        func beginNextCasePatternIfActive() {
            guard let contextIndex = activeCasePatternContextIndex() else { return }
            let nextIndex = nextNonSeparatorIndex(startingAt: index)
            if ShellTokenClassifier.reservedWord(in: tokens, at: nextIndex) == .esac {
                return
            }
            casePatternContexts[contextIndex].readingPattern = true
        }

        func nextNonSeparatorIndex(startingAt startIndex: Int) -> Int {
            var nextIndex = startIndex
            while nextIndex < tokens.count {
                guard case .separator(let separator) = tokens[nextIndex],
                      separator.isCommandTerminator else {
                    break
                }
                nextIndex += 1
            }
            return nextIndex
        }

        func finishActiveCasePattern() {
            guard let contextIndex = activeCasePatternContextIndex() else { return }
            casePatternContexts[contextIndex].readingPattern = false
        }

        while index < tokens.count {
            try consumeBudget()
            if isReadingCasePattern() {
                if case .groupEnd = tokens[index] {
                    finishActiveCasePattern()
                    collected.append(tokens[index])
                    index += 1
                    commandPosition = true
                    commandPositionAfterRedirectionTarget = nil
                    pendingFunctionBodyBrace = false
                    continue
                }
                collected.append(tokens[index])
                index += 1
                commandPosition = true
                commandPositionAfterRedirectionTarget = nil
                pendingFunctionBodyBrace = false
                continue
            }
            if case .groupStart = tokens[index] {
                groupDepth += 1
                collected.append(tokens[index])
                index += 1
                continue
            }
            if case .groupEnd = tokens[index] {
                if groupDepth == 0, nestedDepth == 0, stops.groupEnd {
                    return ShellCompoundTokenScanResult(tokens: collected, stop: .groupEnd, index: index)
                }
                if groupDepth > 0 {
                    groupDepth -= 1
                }
                collected.append(tokens[index])
                index += 1
                commandPosition = false
                continue
            }
            if case .caseTerminator(let terminator) = tokens[index] {
                if nestedDepth == 0, groupDepth == 0, stops.caseTerminator {
                    return ShellCompoundTokenScanResult(tokens: collected, stop: .caseTerminator(terminator), index: index)
                }
                collected.append(tokens[index])
                index += 1
                commandPosition = true
                commandPositionAfterRedirectionTarget = nil
                pendingFunctionBodyBrace = false
                if nestedDepth > 0, groupDepth == 0 {
                    beginNextCasePatternIfActive()
                }
                continue
            }
            if case .separator = tokens[index] {
                collected.append(tokens[index])
                index += 1
                commandPosition = true
                commandPositionAfterRedirectionTarget = nil
                pendingFunctionBodyBrace = false
                continue
            }
            if case .pipe(_) = tokens[index] {
                collected.append(tokens[index])
                index += 1
                commandPosition = true
                commandPositionAfterRedirectionTarget = nil
                continue
            }
            if case .redirectionOperator = tokens[index] {
                collected.append(tokens[index])
                index += 1
                commandPositionAfterRedirectionTarget = commandPosition
                continue
            }
            if case .arithmeticCommand = tokens[index] {
                collected.append(tokens[index])
                index += 1
                commandPosition = false
                commandPositionAfterRedirectionTarget = nil
                pendingFunctionBodyBrace = false
                continue
            }
            if let word = ShellTokenClassifier.wordLike(in: tokens, at: index) {
                let raw = word.rawText
                if let restoredCommandPosition = commandPositionAfterRedirectionTarget {
                    collected.append(tokens[index])
                    index += 1
                    commandPosition = restoredCommandPosition
                    commandPositionAfterRedirectionTarget = nil
                    continue
                }
                if commandPosition,
                   nestedDepth == 0,
                   groupDepth == 0,
                   let reserved = ShellTokenClassifier.reservedWord(in: tokens, at: index),
                   stops.reservedWords.contains(reserved) {
                    return ShellCompoundTokenScanResult(tokens: collected, stop: .reservedWord(reserved), index: index)
                }

                if commandPosition,
                   nestedDepth == 0,
                   groupDepth == 0,
                   stops.words.contains(raw),
                   ShellTokenClassifier.isUnquotedWord(word, raw) {
                    return ShellCompoundTokenScanResult(tokens: collected, stop: .word(raw), index: index)
                }

                let isFunctionStart = groupDepth == 0
                    && commandPosition
                    && ShellTokenClassifier.isFunctionDefinitionStart(in: tokens, at: index, grammar: grammar)
                if isFunctionStart {
                    pendingFunctionBodyBrace = true
                }

                if groupDepth == 0,
                   pendingFunctionBodyBrace,
                   ShellTokenClassifier.reservedWord(in: tokens, at: index) == .leftBrace {
                    nestedDepth += 1
                    collected.append(tokens[index])
                    index += 1
                    commandPosition = true
                    pendingFunctionBodyBrace = false
                    continue
                }

                if groupDepth == 0,
                   commandPosition,
                   ShellTokenClassifier.reservedWord(in: tokens, at: index) == .leftBrace {
                    nestedDepth += 1
                    collected.append(tokens[index])
                    index += 1
                    commandPosition = true
                    continue
                }
                if groupDepth == 0,
                   commandPosition,
                   ShellTokenClassifier.reservedWord(in: tokens, at: index) == .rightBrace {
                    if nestedDepth > 0 {
                        nestedDepth -= 1
                        collected.append(tokens[index])
                        index += 1
                        commandPosition = false
                        continue
                    }
                }
                if groupDepth == 0,
                   commandPosition,
                   let reserved = ShellTokenClassifier.reservedWord(in: tokens, at: index),
                   ShellTokenClassifier.isCompoundStartReservedWord(reserved) {
                    nestedDepth += 1
                    if reserved == .caseWord {
                        casePatternContexts.append(ShellCasePatternScanContext(
                            depth: nestedDepth,
                            awaitingIn: true,
                            readingPattern: false
                        ))
                    }
                    collected.append(tokens[index])
                    index += 1
                    commandPosition = ShellTokenClassifier.commandPositionAfterCompoundStart(reserved)
                    continue
                }
                if groupDepth == 0,
                   commandPosition,
                   let reserved = ShellTokenClassifier.reservedWord(in: tokens, at: index),
                   ShellTokenClassifier.isCompoundEndReservedWord(reserved) {
                    if nestedDepth > 0 {
                        if reserved == .esac,
                           casePatternContexts.last?.depth == nestedDepth {
                            _ = casePatternContexts.popLast()
                        }
                        nestedDepth -= 1
                        collected.append(tokens[index])
                        index += 1
                        commandPosition = false
                        continue
                    }
                }

                collected.append(tokens[index])
                index += 1

                if let reserved = ShellTokenClassifier.reservedWord(in: tokens, at: index - 1),
                   ShellTokenClassifier.isControlReservedWord(reserved) {
                    commandPosition = true
                    if reserved == .inWord, groupDepth == 0 {
                        beginCasePatternIfAwaitingIn()
                    }
                } else {
                    commandPosition = false
                }
                if !pendingFunctionBodyBrace, !isFunctionStart {
                    pendingFunctionBodyBrace = false
                }
                continue
            }
        }
        throw ShellExit.usage(missingMessage)
    }
}
