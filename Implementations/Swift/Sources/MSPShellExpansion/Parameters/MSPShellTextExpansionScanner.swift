import Foundation
import MSPShellLanguage

struct MSPShellTextExpansionScanner {
    enum CommandSubstitutionRecognition {
        case preserveAsLiteral
        case recognize
    }

    enum Step {
        case literal(String)
        case processSubstitution(mode: MSPShellProcessSubstitutionMode, command: String)
        case commandSubstitution(command: String, rawText: String)
        case bracedParameter(expression: String)
        case arithmeticExpression(String)
        case parameter(String)
    }

    var text: String
    var commandSubstitutions: CommandSubstitutionRecognition

    func steps() throws -> [Step] {
        var output: [Step] = []
        var literal = ""
        var index = text.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else {
                return
            }
            output.append(.literal(literal))
            literal = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix(MSPShellProcessSubstitutionToken.prefix),
               let token = try MSPShellProcessSubstitutionToken.decodedMarker(
                in: text,
                startingAt: index
               ) {
                flushLiteral()
                output.append(.processSubstitution(mode: token.mode, command: token.command))
                index = token.nextIndex
                continue
            }

            let character = text[index]
            if character == "`" {
                if commandSubstitutions == .recognize {
                    let substitution = try MSPShellSubstitutionScanner.backtickSubstitutionCommand(
                        in: text,
                        startingAt: index
                    )
                    flushLiteral()
                    output.append(.commandSubstitution(
                        command: substitution.command,
                        rawText: String(text[index..<substitution.nextIndex])
                    ))
                    index = substitution.nextIndex
                    continue
                } else if let substitution = try? MSPShellSubstitutionScanner.backtickSubstitutionCommand(
                    in: text,
                    startingAt: index
                ) {
                    literal += text[index..<substitution.nextIndex]
                    index = substitution.nextIndex
                    continue
                }
            }

            guard character == "$" else {
                literal.append(character)
                index = text.index(after: index)
                continue
            }

            let next = text.index(after: index)
            guard next < text.endIndex else {
                literal.append(character)
                index = next
                continue
            }

            if text[next] == "{" {
                guard let end = MSPShellExpansionScanner.bracedParameterEndIndex(
                    in: text,
                    openingBraceIndex: next,
                    grammar: .msp
                ) else {
                    throw MSPShellExpansionError.badSubstitution(String(text[index...]))
                }
                let expressionStart = text.index(after: next)
                flushLiteral()
                output.append(.bracedParameter(expression: String(text[expressionStart..<end])))
                index = text.index(after: end)
                continue
            }

            if text[next] == "(" {
                let secondNext = text.index(after: next)
                if secondNext < text.endIndex, text[secondNext] == "(" {
                    let end = try MSPShellSubstitutionScanner.arithmeticExpansionEndIndex(
                        in: text,
                        startingAt: index,
                        grammar: .msp
                    )
                    let expressionStart = text.index(after: secondNext)
                    let closeSecond = text.index(before: end)
                    let closeFirst = text.index(before: closeSecond)
                    flushLiteral()
                    output.append(.arithmeticExpression(String(text[expressionStart..<closeFirst])))
                    index = end
                    continue
                }

                if commandSubstitutions == .recognize {
                    let end = try MSPShellSubstitutionScanner.commandSubstitutionEndIndex(
                        in: text,
                        startingAt: index,
                        grammar: .msp
                    )
                    let bodyStart = secondNext
                    let bodyEnd = text.index(before: end)
                    flushLiteral()
                    output.append(.commandSubstitution(
                        command: String(text[bodyStart..<bodyEnd]),
                        rawText: String(text[index..<end])
                    ))
                    index = end
                    continue
                } else if let end = try? MSPShellSubstitutionScanner.commandSubstitutionEndIndex(
                    in: text,
                    startingAt: index,
                    grammar: .msp
                ) {
                    literal += text[index..<end]
                    index = end
                    continue
                }
            }

            if MSPShellExpansionScanner.isShellVariableStart(text[next]) {
                var end = text.index(after: next)
                while end < text.endIndex,
                      MSPShellExpansionScanner.isShellVariableBody(text[end]) {
                    end = text.index(after: end)
                }
                flushLiteral()
                output.append(.parameter(String(text[next..<end])))
                index = end
                continue
            }

            if text[next].isNumber || MSPShellWordExpansionCore.isSpecialParameter(text[next]) {
                flushLiteral()
                output.append(.parameter(String(text[next])))
                index = text.index(after: next)
                continue
            }

            literal.append(character)
            index = next
        }

        flushLiteral()
        return output
    }
}
