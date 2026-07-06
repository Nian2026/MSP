import Foundation

package enum MSPShellGrammarTarget: Hashable, Sendable {
    case mspCompatibility
    case debianDash12
    case debianBash52
    case zshCompatibility
}

package struct MSPShellGrammarReference: Hashable, Sendable {
    package var parserSource: String
    package var astSource: String

    package static let mspCompatibility = MSPShellGrammarReference(
        parserSource: "MSPShell parser with Debian bash-shaped extensions",
        astSource: "MSPShellLanguage/AST"
    )
    package static let debianDash12 = MSPShellGrammarReference(
        parserSource: "dash-0.5.12/src/parser.c",
        astSource: "dash-0.5.12/src/nodetypes"
    )
    package static let debianBash52 = MSPShellGrammarReference(
        parserSource: "bash-5.2.15/parse.y",
        astSource: "bash-5.2.15/command.h"
    )
    package static let zshCompatibility = MSPShellGrammarReference(
        parserSource: "MSPShell zsh launcher compatibility",
        astSource: "MSPShellLanguage/AST"
    )
}

package struct MSPShellLexicalFeatures: Hashable, Sendable {
    package var functionReservedWord: Bool
    package var doubleBracketConditional: Bool
    package var arithmeticCommand: Bool
    package var processSubstitution: Bool
    package var extendedGlob: Bool
    package var pipeStdoutAndStderr: Bool
    package var hereString: Bool
    package var outputBothRedirection: Bool
    package var caseFallthroughTerminators: Bool
    package var ansiCQuote: Bool
}

package struct MSPShellParserFeatures: Hashable, Sendable {
    package var functionReservedWordDefinition: Bool
    package var doubleBracketConditional: Bool
    package var arithmeticCommand: Bool
    package var cStyleFor: Bool
    package var arrayAssignments: Bool
    package var subscriptAssignments: Bool
}

package struct MSPShellExpansionFeatures: Hashable, Sendable {
    package var braceExpansion: Bool
    package var arrayParameterExpansion: Bool
    package var parameterSubstring: Bool
    package var parameterCaseModification: Bool
    package var parameterReplacement: Bool
    package var ansiCQuoteInParameterWord: Bool
    package var processSubstitutionInParameterWord: Bool
}

package enum MSPShellScanContext: Hashable, Sendable {
    case lexerWord
    case nestedShellInput
    case parameterOperationWord
    case expandedText
    case hereDocumentDelimiter
}

package struct MSPShellGrammar: Hashable, Sendable {
    package var target: MSPShellGrammarTarget
    package var reference: MSPShellGrammarReference
    package var lexical: MSPShellLexicalFeatures
    package var parser: MSPShellParserFeatures
    package var expansion: MSPShellExpansionFeatures

    package static let msp = MSPShellGrammar(
        target: .mspCompatibility,
        reference: .mspCompatibility,
        lexical: .bashLike,
        parser: .bashLike,
        expansion: .bashLike
    )

    package static let debianDash = MSPShellGrammar(
        target: .debianDash12,
        reference: .debianDash12,
        lexical: .dashLike,
        parser: .dashLike,
        expansion: .dashLike
    )

    package static let debianBash = MSPShellGrammar(
        target: .debianBash52,
        reference: .debianBash52,
        lexical: .bashLike,
        parser: .bashLike,
        expansion: .bashLike
    )

    package static let zsh = MSPShellGrammar(
        target: .zshCompatibility,
        reference: .zshCompatibility,
        lexical: .bashLike,
        parser: .bashLike,
        expansion: .bashLike
    )
}

extension MSPShellGrammar {
    package func withExtendedGlob(_ enabled: Bool) -> MSPShellGrammar {
        var grammar = self
        grammar.lexical.extendedGlob = enabled
        return grammar
    }

    package func recognizesAnsiCQuote(in context: MSPShellScanContext) -> Bool {
        switch context {
        case .parameterOperationWord:
            return expansion.ansiCQuoteInParameterWord
        case .lexerWord, .nestedShellInput, .expandedText, .hereDocumentDelimiter:
            return lexical.ansiCQuote
        }
    }

    package func recognizesProcessSubstitution(in context: MSPShellScanContext) -> Bool {
        switch context {
        case .parameterOperationWord:
            return expansion.processSubstitutionInParameterWord
        case .lexerWord, .nestedShellInput, .expandedText:
            return lexical.processSubstitution
        case .hereDocumentDelimiter:
            return false
        }
    }
}

extension MSPShellLexicalFeatures {
    static let dashLike = MSPShellLexicalFeatures(
        functionReservedWord: false,
        doubleBracketConditional: false,
        arithmeticCommand: false,
        processSubstitution: false,
        extendedGlob: false,
        pipeStdoutAndStderr: false,
        hereString: false,
        outputBothRedirection: false,
        caseFallthroughTerminators: false,
        ansiCQuote: false
    )

    static let bashLike = MSPShellLexicalFeatures(
        functionReservedWord: true,
        doubleBracketConditional: true,
        arithmeticCommand: true,
        processSubstitution: true,
        extendedGlob: true,
        pipeStdoutAndStderr: true,
        hereString: true,
        outputBothRedirection: true,
        caseFallthroughTerminators: true,
        ansiCQuote: true
    )
}

extension MSPShellParserFeatures {
    static let dashLike = MSPShellParserFeatures(
        functionReservedWordDefinition: false,
        doubleBracketConditional: false,
        arithmeticCommand: false,
        cStyleFor: false,
        arrayAssignments: false,
        subscriptAssignments: false
    )

    static let bashLike = MSPShellParserFeatures(
        functionReservedWordDefinition: true,
        doubleBracketConditional: true,
        arithmeticCommand: true,
        cStyleFor: true,
        arrayAssignments: true,
        subscriptAssignments: true
    )
}

extension MSPShellExpansionFeatures {
    static let dashLike = MSPShellExpansionFeatures(
        braceExpansion: false,
        arrayParameterExpansion: false,
        parameterSubstring: false,
        parameterCaseModification: false,
        parameterReplacement: false,
        ansiCQuoteInParameterWord: false,
        processSubstitutionInParameterWord: false
    )

    static let bashLike = MSPShellExpansionFeatures(
        braceExpansion: true,
        arrayParameterExpansion: true,
        parameterSubstring: true,
        parameterCaseModification: true,
        parameterReplacement: true,
        ansiCQuoteInParameterWord: true,
        processSubstitutionInParameterWord: true
    )
}

extension MSPShellDialect {
    static func shellLauncherDialect(forExecutable executable: String) -> MSPShellDialect? {
        let name = executable.split(separator: "/").last.map(String.init) ?? executable
        switch name {
        case "sh":
            return .sh
        case "bash":
            return .bash
        case "zsh":
            return .zsh
        default:
            return nil
        }
    }

    var grammar: MSPShellGrammar {
        switch self {
        case .msp:
            return .msp
        case .sh:
            return .debianDash
        case .bash:
            return .debianBash
        case .zsh:
            return .zsh
        }
    }
}
