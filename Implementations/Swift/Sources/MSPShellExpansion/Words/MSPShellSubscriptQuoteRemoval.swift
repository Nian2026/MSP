import Foundation

func mspShellQuoteRemovedSubscriptText(_ text: String) -> String {
    var output = ""
    var index = text.startIndex
    var quote: Character?
    while index < text.endIndex {
        let character = text[index]
        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
                index = text.index(after: index)
                continue
            }
            if activeQuote == "\"", character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    output.append(text[next])
                    index = text.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            output.append(character)
            index = text.index(after: index)
            continue
        }

        if character == "'" || character == "\"" {
            quote = character
            index = text.index(after: index)
            continue
        }
        if character == "\\" {
            let next = text.index(after: index)
            if next < text.endIndex {
                output.append(text[next])
                index = text.index(after: next)
            } else {
                index = next
            }
            continue
        }
        output.append(character)
        index = text.index(after: index)
    }
    return output
}
