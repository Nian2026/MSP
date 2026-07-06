import Foundation

struct MSPFmtPhysicalLine {
    var bytes: [UInt8]
    var indentColumns: Int
    var firstTextIndex: Int
    var isBlank: Bool
}

struct MSPFmtWord {
    var bytes: [UInt8]
    var space: Int
    var paren: Bool
    var period: Bool
    var punct: Bool
    var final: Bool

    var length: Int { bytes.count }
}

func mspFmtPhysicalLines(_ data: Data) -> [MSPFmtPhysicalLine] {
    var lines: [MSPFmtPhysicalLine] = []
    var current: [UInt8] = []
    for byte in data {
        if byte == 0x0a {
            lines.append(mspFmtPhysicalLine(current))
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(byte)
        }
    }
    if !current.isEmpty || data.last != 0x0a {
        lines.append(mspFmtPhysicalLine(current))
    }
    return lines
}

func mspFmtPhysicalLine(_ bytes: [UInt8]) -> MSPFmtPhysicalLine {
    var index = 0
    var columns = 0
    while index < bytes.count {
        if bytes[index] == 0x20 {
            columns += 1
        } else if bytes[index] == 0x09 {
            columns = (columns / 8 + 1) * 8
        } else {
            break
        }
        index += 1
    }
    let blank = bytes[index...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    return MSPFmtPhysicalLine(bytes: bytes, indentColumns: columns, firstTextIndex: index, isBlank: blank)
}

func mspFmtWords(in bytes: [UInt8], start: Int, uniformSpacing: Bool) -> [MSPFmtWord] {
    var index = start
    var words: [MSPFmtWord] = []
    while index < bytes.count {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 {
            index += 1
        }
        guard index < bytes.count else {
            break
        }
        let wordStart = index
        while index < bytes.count, bytes[index] != 0x20, bytes[index] != 0x09 {
            index += 1
        }
        let wordBytes = Array(bytes[wordStart..<index])
        var space = 0
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 {
            if bytes[index] == 0x09 {
                space = (space / 8 + 1) * 8
            } else {
                space += 1
            }
            index += 1
        }
        let punctuation = mspFmtPunctuation(wordBytes)
        let endedLine = index >= bytes.count
        var word = MSPFmtWord(
            bytes: wordBytes,
            space: uniformSpacing || endedLine ? (punctuation.period ? 2 : 1) : max(1, space),
            paren: punctuation.paren,
            period: punctuation.period,
            punct: punctuation.punct,
            final: punctuation.period && (endedLine || space > 1)
        )
        if endedLine, !word.period {
            word.space = 1
        }
        words.append(word)
    }
    if !words.isEmpty {
        words[words.count - 1].period = true
        words[words.count - 1].final = true
    }
    return words
}

func mspFmtPunctuation(_ bytes: [UInt8]) -> (paren: Bool, period: Bool, punct: Bool) {
    guard let first = bytes.first, !bytes.isEmpty else {
        return (false, false, false)
    }
    let paren = [UInt8]("(['`\"".utf8).contains(first)
    let punct = mspFmtIsPunct(bytes[bytes.count - 1])
    var cursor = bytes.count - 1
    while cursor > 0, [UInt8](")]'\"".utf8).contains(bytes[cursor]) {
        cursor -= 1
    }
    let period = [UInt8](".?!".utf8).contains(bytes[cursor])
    return (paren, period, punct)
}

func mspFmtIsPunct(_ byte: UInt8) -> Bool {
    (0x21...0x2f).contains(byte)
        || (0x3a...0x40).contains(byte)
        || (0x5b...0x60).contains(byte)
        || (0x7b...0x7e).contains(byte)
}
