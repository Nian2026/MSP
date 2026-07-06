import MSPCore

public struct MSPEchoCommand: MSPCommand {
    public let name = "echo"
    public let summary: String? = "Write arguments to standard output."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var omitTrailingNewline = false
        var interpretEscapes = false
        var operandStart = 0

        while operandStart < invocation.arguments.count {
            let argument = invocation.arguments[operandStart]
            guard argument.hasPrefix("-"), argument.count > 1 else {
                break
            }
            let optionCharacters = argument.dropFirst()
            guard optionCharacters.allSatisfy({ $0 == "n" || $0 == "e" || $0 == "E" }) else {
                break
            }
            for option in optionCharacters {
                switch option {
                case "n":
                    omitTrailingNewline = true
                case "e":
                    interpretEscapes = true
                case "E":
                    interpretEscapes = false
                default:
                    continue
                }
            }
            operandStart += 1
        }

        let values = Array(invocation.arguments.dropFirst(operandStart))
        var text = values.joined(separator: " ")
        var stopOutput = false
        if interpretEscapes {
            let decoded = mspEchoDecodeEscapes(text)
            text = decoded.text
            stopOutput = decoded.stopOutput
        }
        return .success(stdout: omitTrailingNewline || stopOutput ? text : text + "\n")
    }
}

private func mspEchoDecodeEscapes(_ text: String) -> (text: String, stopOutput: Bool) {
    var output = ""
    var index = text.startIndex
    while index < text.endIndex {
        guard text[index] == "\\" else {
            output.append(text[index])
            text.formIndex(after: &index)
            continue
        }
        let result = mspEchoDecodeEscape(in: text, at: index)
        output += result.text
        index = result.nextIndex
        if result.stopOutput {
            return (output, true)
        }
    }
    return (output, false)
}

private func mspEchoDecodeEscape(
    in text: String,
    at index: String.Index
) -> (text: String, nextIndex: String.Index, stopOutput: Bool) {
    let next = text.index(after: index)
    guard next < text.endIndex else {
        return ("\\", next, false)
    }
    switch text[next] {
    case "0":
        var digits = ""
        var cursor = text.index(after: next)
        while cursor < text.endIndex, digits.count < 3, ("0"..."7").contains(text[cursor]) {
            digits.append(text[cursor])
            text.formIndex(after: &cursor)
        }
        let value = UInt32(digits, radix: 8) ?? 0
        return (UnicodeScalar(value).map(String.init) ?? "", cursor, false)
    case "a":
        return ("\u{7}", text.index(after: next), false)
    case "b":
        return ("\u{8}", text.index(after: next), false)
    case "c":
        return ("", text.index(after: next), true)
    case "e", "E":
        return ("\u{1b}", text.index(after: next), false)
    case "f":
        return ("\u{c}", text.index(after: next), false)
    case "n":
        return ("\n", text.index(after: next), false)
    case "r":
        return ("\r", text.index(after: next), false)
    case "t":
        return ("\t", text.index(after: next), false)
    case "v":
        return ("\u{b}", text.index(after: next), false)
    case "x":
        return mspEchoDecodeVariableWidthScalar(in: text, after: next, maxDigits: 2, radix: 16)
    case "u":
        return mspEchoDecodeFixedWidthScalar(in: text, after: next, digits: 4)
    case "U":
        return mspEchoDecodeFixedWidthScalar(in: text, after: next, digits: 8)
    case "\\":
        return ("\\", text.index(after: next), false)
    default:
        return ("\\" + String(text[next]), text.index(after: next), false)
    }
}

private func mspEchoDecodeVariableWidthScalar(
    in text: String,
    after marker: String.Index,
    maxDigits: Int,
    radix: Int
) -> (text: String, nextIndex: String.Index, stopOutput: Bool) {
    var digits = ""
    var cursor = text.index(after: marker)
    while cursor < text.endIndex,
          digits.count < maxDigits,
          text[cursor].isHexDigit {
        digits.append(text[cursor])
        text.formIndex(after: &cursor)
    }
    guard !digits.isEmpty,
          let value = UInt32(digits, radix: radix),
          let scalar = UnicodeScalar(value) else {
        return ("\\" + String(text[marker]), text.index(after: marker), false)
    }
    return (String(scalar), cursor, false)
}

private func mspEchoDecodeFixedWidthScalar(
    in text: String,
    after marker: String.Index,
    digits count: Int
) -> (text: String, nextIndex: String.Index, stopOutput: Bool) {
    var digits = ""
    var cursor = text.index(after: marker)
    while cursor < text.endIndex,
          digits.count < count,
          text[cursor].isHexDigit {
        digits.append(text[cursor])
        text.formIndex(after: &cursor)
    }
    guard digits.count == count,
          let value = UInt32(digits, radix: 16),
          let scalar = UnicodeScalar(value) else {
        return ("\\" + String(text[marker]), text.index(after: marker), false)
    }
    return (String(scalar), cursor, false)
}

private extension Character {
    var isHexDigit: Bool {
        unicodeScalars.count == 1 && (
            ("0"..."9").contains(self)
                || ("a"..."f").contains(self)
                || ("A"..."F").contains(self)
        )
    }
}
