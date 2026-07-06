import Foundation

enum MSPShellAnsiCQuote {
    static func quotedText(
        in text: String,
        startingAt dollarIndex: String.Index
    ) throws -> (text: String, nextIndex: String.Index) {
        let openIndex = text.index(after: dollarIndex)
        var raw = ""
        var index = text.index(after: openIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else {
                    raw.append(character)
                    index = next
                    continue
                }
                raw.append(character)
                raw.append(text[next])
                index = text.index(after: next)
                continue
            }
            if character == "'" {
                return (decodeBackslashEscapes(raw), text.index(after: index))
            }
            raw.append(character)
            index = text.index(after: index)
        }
        throw ShellExit.usage("$': unterminated quoted string")
    }

    static func decodeBackslashEscapes(_ value: String) -> String {
        var output = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "\\", index + 1 < characters.count else {
                output.append(character)
                index += 1
                continue
            }
            let next = characters[index + 1]
            switch next {
            case "a":
                output.append("\u{7}")
                index += 2
            case "b":
                output.append("\u{8}")
                index += 2
            case "e", "E":
                output.append("\u{1B}")
                index += 2
            case "f":
                output.append("\u{c}")
                index += 2
            case "n":
                output.append("\n")
                index += 2
            case "r":
                output.append("\r")
                index += 2
            case "t":
                output.append("\t")
                index += 2
            case "v":
                output.append("\u{b}")
                index += 2
            case "\\":
                output.append("\\")
                index += 2
            case "'":
                output.append("'")
                index += 2
            case "\"":
                output.append("\"")
                index += 2
            case "?":
                output.append("?")
                index += 2
            case "0"..."7":
                var digits = ""
                var cursor = index + 1
                while cursor < characters.count,
                      digits.count < 3,
                      ("0"..."7").contains(characters[cursor]) {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                appendByte(from: digits, radix: 8, to: &output)
                index = cursor
            case "x":
                let parsed = hexadecimalDigits(in: characters, startingAt: index + 2, maxCount: 2)
                if parsed.digits.isEmpty {
                    output.append("\\x")
                    index += 2
                } else {
                    appendByte(from: parsed.digits, radix: 16, to: &output)
                    index = parsed.nextIndex
                }
            case "u":
                let parsed = hexadecimalDigits(in: characters, startingAt: index + 2, maxCount: 4)
                if parsed.digits.isEmpty {
                    output.append("\\u")
                    index += 2
                } else {
                    appendUnicodeScalar(from: parsed.digits, radix: 16, to: &output)
                    index = parsed.nextIndex
                }
            case "U":
                let parsed = hexadecimalDigits(in: characters, startingAt: index + 2, maxCount: 8)
                if parsed.digits.isEmpty {
                    output.append("\\U")
                    index += 2
                } else {
                    appendUnicodeScalar(from: parsed.digits, radix: 16, to: &output)
                    index = parsed.nextIndex
                }
            case "c":
                if index + 2 < characters.count,
                   let ascii = characters[index + 2].asciiValue {
                    output.append(Character(Unicode.Scalar(ascii & 0x1F)))
                    index += 3
                } else {
                    output.append("\\c")
                    index += 2
                }
            default:
                output.append("\\")
                output.append(next)
                index += 2
            }
        }
        return output
    }

    private static func hexadecimalDigits(
        in characters: [Character],
        startingAt startIndex: Int,
        maxCount: Int
    ) -> (digits: String, nextIndex: Int) {
        var digits = ""
        var index = startIndex
        while index < characters.count,
              digits.count < maxCount,
              characters[index].isHexDigit {
            digits.append(characters[index])
            index += 1
        }
        return (digits, index)
    }

    private static func appendUnicodeScalar(
        from digits: String,
        radix: Int,
        to output: inout String
    ) {
        guard let value = UInt32(digits, radix: radix),
              let scalar = Unicode.Scalar(value) else { return }
        output.unicodeScalars.append(scalar)
    }

    private static func appendByte(
        from digits: String,
        radix: Int,
        to output: inout String
    ) {
        guard let value = UInt32(digits, radix: radix) else { return }
        let byte = UInt8(truncatingIfNeeded: value)
        if byte < 0x80 {
            output.unicodeScalars.append(UnicodeScalar(Int(byte))!)
        } else {
            output.unicodeScalars.append(mspShellPrivateByteScalar(byte))
        }
    }
}
