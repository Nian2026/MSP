import Foundation

private let mspShellPrivateByteScalarBase = 0xE000
private let mspShellPrivateByteScalarEnd = mspShellPrivateByteScalarBase + 0xFF

let mspShellArrayAssignmentArgumentPrefix = "__MSP_ARRAY_ASSIGN__"
let mspShellArrayAssignmentFieldSeparator = "\u{1F}"

enum MSPShellDialect: Hashable, Sendable {
    case msp
    case sh
    case bash
    case zsh
}

struct ShellExit: Error, Sendable, Equatable, CustomStringConvertible {
    enum Stream: Sendable, Equatable {
        case stdout
        case stderr
    }

    var code: Int
    var message: String
    var stream: Stream
    var interruptsExecution: Bool

    init(
        code: Int,
        message: String,
        stream: Stream = .stderr,
        interruptsExecution: Bool = false
    ) {
        self.code = code
        self.message = message
        self.stream = stream
        self.interruptsExecution = interruptsExecution
    }

    var description: String {
        message
    }

    static func failure(_ message: String) -> ShellExit {
        ShellExit(code: 1, message: message)
    }

    static func usage(_ message: String) -> ShellExit {
        ShellExit(code: 2, message: message)
    }

    static func expansionFatal(_ message: String) -> ShellExit {
        ShellExit(
            code: 127,
            message: message.hasSuffix("\n") ? message : message + "\n",
            interruptsExecution: true
        )
    }
}

func mspShellVariableName(_ value: String) -> Bool {
    MSPShellExpansionScanner.isShellVariableName(value)
}

func mspShellDecodeAnsiCBackslashEscapes(_ value: String) -> String {
    MSPShellAnsiCQuote.decodeBackslashEscapes(value)
}

func mspShellPrivateByteScalar(_ byte: UInt8) -> UnicodeScalar {
    UnicodeScalar(mspShellPrivateByteScalarBase + Int(byte))!
}

func mspShellBytePreservingString(from data: Data) -> String {
    var output = ""
    var index = data.startIndex
    while index < data.endIndex {
        let byte = data[index]
        if byte < 0x80 {
            output.unicodeScalars.append(UnicodeScalar(Int(byte))!)
            index = data.index(after: index)
            continue
        }

        if let sequenceLength = mspUTF8SequenceLength(startByte: byte),
           data.distance(from: index, to: data.endIndex) >= sequenceLength {
            let end = data.index(index, offsetBy: sequenceLength)
            let candidate = data[index..<end]
            if candidate.dropFirst().allSatisfy(mspIsUTF8ContinuationByte),
               let decoded = String(data: candidate, encoding: .utf8) {
                output += decoded
                index = end
                continue
            }
        }

        output.unicodeScalars.append(mspShellPrivateByteScalar(byte))
        index = data.index(after: index)
    }
    return output
}

func mspShellData(fromBytePreservingString text: String) -> Data {
    var output = Data()
    for scalar in text.unicodeScalars {
        let value = Int(scalar.value)
        if (mspShellPrivateByteScalarBase...mspShellPrivateByteScalarEnd).contains(value) {
            output.append(UInt8(value - mspShellPrivateByteScalarBase))
        } else {
            output.append(contentsOf: String(scalar).utf8)
        }
    }
    return output
}

private func mspUTF8SequenceLength(startByte byte: UInt8) -> Int? {
    switch byte {
    case 0xC2...0xDF:
        return 2
    case 0xE0...0xEF:
        return 3
    case 0xF0...0xF4:
        return 4
    default:
        return nil
    }
}

private func mspIsUTF8ContinuationByte(_ byte: UInt8) -> Bool {
    (0x80...0xBF).contains(byte)
}

struct MSPShellProtectedHereDocumentEscapes {
    var text: String
    var tokens: [String: String]
}

enum MSPShellHereDocumentEscapes {
    static func protectExpandableEscapes(in text: String) -> MSPShellProtectedHereDocumentEscapes {
        let markerPrefix = "\u{E000}MSP_HEREDOC_ESC_"
        let markerSuffix = "_\u{E001}"
        var output = ""
        var tokens: [String: String] = [:]
        var tokenIndex = 0
        var index = text.startIndex

        func appendToken(_ value: String) {
            let token = "\(markerPrefix)\(tokenIndex)\(markerSuffix)"
            tokenIndex += 1
            tokens[token] = value
            output += token
        }

        while index < text.endIndex {
            let character = text[index]
            guard character == "\\" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }

            let next = text.index(after: index)
            guard next < text.endIndex else {
                output.append(character)
                index = next
                continue
            }

            switch text[next] {
            case "\\", "$", "`":
                appendToken(String(text[next]))
                index = text.index(after: next)
            case "\n":
                index = text.index(after: next)
            default:
                output.append(character)
                output.append(text[next])
                index = text.index(after: next)
            }
        }

        return MSPShellProtectedHereDocumentEscapes(text: output, tokens: tokens)
    }

    static func restoreExpandableEscapes(
        in text: String,
        tokens: [String: String]
    ) -> String {
        var output = text
        for (token, value) in tokens {
            output = output.replacingOccurrences(of: token, with: value)
        }
        return output
    }
}
