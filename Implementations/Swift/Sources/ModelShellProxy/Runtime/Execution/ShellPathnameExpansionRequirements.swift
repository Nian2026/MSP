import Foundation
import MSPShell

extension MSPParsedCommandLine {
    func mspMayNeedPathnameExpansionCandidates(enablesExtendedGlob: Bool) -> Bool {
        let words = [commandNameWord].compactMap { $0 }
            + argumentWords
            + arrayAssignmentValueWords.flatMap { $0 }
        return words.contains {
            $0.mspMayNeedPathnameExpansionCandidates(
                enablesExtendedGlob: enablesExtendedGlob,
                enablesWordSplitting: true
            )
        }
    }
}

extension MSPParsedWord {
    func mspMayNeedPathnameExpansionCandidates(
        enablesExtendedGlob: Bool,
        enablesWordSplitting: Bool
    ) -> Bool {
        guard enablesWordSplitting else {
            return false
        }
        return parts.contains { part in
            guard !part.isQuoted else {
                return false
            }
            if part.isExpandable, Self.mspContainsExpansionSyntax(part.text) {
                return true
            }
            return Self.mspContainsGlobSyntax(part.text, enablesExtendedGlob: enablesExtendedGlob)
        }
    }

    static func mspContainsExpansionSyntax(_ text: String) -> Bool {
        text.contains("$")
            || text.contains("`")
            || text.contains("<(")
            || text.contains(">(")
    }

    static func mspContainsGlobSyntax(_ text: String, enablesExtendedGlob: Bool) -> Bool {
        if text.contains("*") || text.contains("?") || text.contains("[") {
            return true
        }
        guard enablesExtendedGlob else {
            return false
        }
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if "@!+".contains(text[index]), next < text.endIndex, text[next] == "(" {
                return true
            }
            index = next
        }
        return false
    }
}
