import Foundation

enum ShellAssignmentSyntax {
    static func assignment(in word: ShellWord) -> ShellAssignmentClause? {
        let raw = word.rawText
        guard let equalIndex = raw.firstIndex(of: "="),
              equalIndex != raw.startIndex else {
            return nil
        }
        let name = String(raw[..<equalIndex])
        guard mspShellVariableName(name) else { return nil }
        let prefix = name + "="
        guard word.hasUnquotedPrefix(prefix),
              let value = word.droppingUnquotedPrefix(prefix) else {
            return nil
        }
        return ShellAssignmentClause(name: name, value: value)
    }
}
