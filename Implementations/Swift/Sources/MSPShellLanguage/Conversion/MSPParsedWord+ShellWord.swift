import Foundation

extension MSPParsedWord {
    init(shellWord: ShellWord) {
        self.init(
            parts: shellWord.parts.map { part in
                Part(
                    text: part.text,
                    isExpandable: part.isExpandable,
                    isQuoted: part.isQuoted
                )
            },
            hasExplicitEmptyQuotedFragment: shellWord.hasExplicitEmptyQuotedFragment
        )
    }
}

extension MSPShellParameterExpansionSyntax.ParameterOperationWord {
    package var parsedWord: MSPParsedWord {
        MSPParsedWord(shellWord: word)
    }
}
