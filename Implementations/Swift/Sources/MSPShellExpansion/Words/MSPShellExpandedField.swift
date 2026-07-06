import Foundation

struct MSPShellExpandedField {
    struct Part {
        var text: String
        var globActive: Bool
    }

    var parts: [Part] = []
    var forceKeep = false
    var acceptsContinuation = true

    var text: String {
        parts.map(\.text).joined()
    }

    var isEmpty: Bool {
        text.isEmpty
    }

    mutating func append(_ text: String, globActive: Bool) {
        guard !text.isEmpty else {
            return
        }
        if let last = parts.last, last.globActive == globActive {
            parts.removeLast()
            parts.append(Part(text: last.text + text, globActive: globActive))
        } else {
            parts.append(Part(text: text, globActive: globActive))
        }
    }

    func containsActiveGlob(extendedGlob: Bool = false) -> Bool {
        var openBracket = false
        for part in parts {
            guard part.globActive else {
                openBracket = false
                continue
            }
            var index = part.text.startIndex
            while index < part.text.endIndex {
                let character = part.text[index]
                switch character {
                case "*", "?":
                    return true
                case "[":
                    openBracket = true
                case "]":
                    if openBracket {
                        return true
                    }
                case "/":
                    openBracket = false
                case "\\":
                    let next = part.text.index(after: index)
                    guard next < part.text.endIndex else {
                        return false
                    }
                    index = next
                default:
                    if extendedGlob,
                       "@!+".contains(character),
                       containsActiveExtendedGlobOperator(in: part.text, startingAt: index) {
                        return true
                    }
                }
                index = part.text.index(after: index)
            }
        }
        return false
    }

    private func containsActiveExtendedGlobOperator(
        in text: String,
        startingAt index: String.Index
    ) -> Bool {
        guard "@!+*?".contains(text[index]) else {
            return false
        }
        let next = text.index(after: index)
        return next < text.endIndex && text[next] == "("
    }
}
