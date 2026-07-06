import Foundation

struct WcStreamingCounter {
    private(set) var counts = WcCounts()
    private var insideWord = false
    private var currentLineLength: Int64 = 0
    private var pendingUTF8Bytes: [UInt8] = []

    mutating func append(_ data: Data) {
        counts.bytes += Int64(data.count)
        counts.lines += Int64(data.reduce(into: 0) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        })
        processBytes(Array(data))
    }

    mutating func finish() {
        pendingUTF8Bytes.removeAll(keepingCapacity: false)
    }

    private mutating func processBytes(_ newBytes: [UInt8]) {
        var bytes = pendingUTF8Bytes
        bytes.append(contentsOf: newBytes)
        pendingUTF8Bytes.removeAll(keepingCapacity: true)

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                processScalar(UnicodeScalar(UInt32(byte))!)
                index += 1
                continue
            }

            guard let expectedLength = wcUTF8SequenceLength(leadByte: byte) else {
                index += 1
                continue
            }
            guard index + expectedLength <= bytes.count else {
                pendingUTF8Bytes = Array(bytes[index...])
                break
            }

            let sequence = Array(bytes[index..<(index + expectedLength)])
            guard let scalar = wcDecodeUTF8Scalar(sequence) else {
                index += 1
                continue
            }
            processScalar(scalar)
            index += expectedLength
        }
    }

    private mutating func processScalar(_ scalar: UnicodeScalar) {
        counts.characters += 1
        let character = Character(scalar)
        if character.isWhitespace {
            insideWord = false
        } else if wcCanStartOrContinueWord(scalar), !insideWord {
            counts.words += 1
            insideWord = true
        }

        switch scalar.value {
        case 0x0A:
            counts.maxLineLength = max(counts.maxLineLength, currentLineLength)
            currentLineLength = 0
        case 0x09:
            currentLineLength += 8 - (currentLineLength % 8)
        default:
            currentLineLength += Int64(wcDisplayWidth(scalar))
        }
        counts.maxLineLength = max(counts.maxLineLength, currentLineLength)
    }
}

func wcUTF8SequenceLength(leadByte: UInt8) -> Int? {
    switch leadByte {
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

func wcDecodeUTF8Scalar(_ bytes: [UInt8]) -> UnicodeScalar? {
    guard let first = bytes.first,
          let expectedLength = wcUTF8SequenceLength(leadByte: first),
          bytes.count == expectedLength
    else {
        return nil
    }
    for continuation in bytes.dropFirst() where continuation < 0x80 || continuation > 0xBF {
        return nil
    }

    switch first {
    case 0xE0 where bytes[1] < 0xA0:
        return nil
    case 0xED where bytes[1] > 0x9F:
        return nil
    case 0xF0 where bytes[1] < 0x90:
        return nil
    case 0xF4 where bytes[1] > 0x8F:
        return nil
    default:
        break
    }

    let value: UInt32
    switch expectedLength {
    case 2:
        value = (UInt32(first & 0x1F) << 6)
            | UInt32(bytes[1] & 0x3F)
    case 3:
        value = (UInt32(first & 0x0F) << 12)
            | (UInt32(bytes[1] & 0x3F) << 6)
            | UInt32(bytes[2] & 0x3F)
    case 4:
        value = (UInt32(first & 0x07) << 18)
            | (UInt32(bytes[1] & 0x3F) << 12)
            | (UInt32(bytes[2] & 0x3F) << 6)
            | UInt32(bytes[3] & 0x3F)
    default:
        return nil
    }
    return UnicodeScalar(value)
}

func wcCanStartOrContinueWord(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return value >= 0x20 && !(value >= 0x7F && value < 0xA0)
}
