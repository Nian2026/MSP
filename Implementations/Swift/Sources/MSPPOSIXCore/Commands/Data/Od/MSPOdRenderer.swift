import Foundation

struct MSPOdRenderer {
    var configuration: MSPOdConfiguration

    func render(data: Data) -> String {
        let bytes = [UInt8](data)
        let leastCommonMultiple = configuration.formats.map(\.size).reduce(1, mspOdLCM)
        let bytesPerLine = mspOdBytesPerLine(
            configuration.requestedWidth,
            leastCommonMultiple: leastCommonMultiple
        )
        let widthPerBlock = configuration.formats.map { format in
            let fieldsPerBlock = bytesPerLine / format.size
            return (format.fieldWidth + 1) * fieldsPerBlock
        }.max() ?? bytesPerLine

        var lines: [String] = []
        var offset = 0
        var previousFullBlock: [UInt8]?
        var duplicateBlockAlreadyPrinted = false

        while offset < bytes.count {
            let end = min(offset + bytesPerLine, bytes.count)
            let chunk = Array(bytes[offset..<end])
            if configuration.abbreviateDuplicateBlocks,
               chunk.count == bytesPerLine,
               let previousFullBlock,
               previousFullBlock == chunk {
                if !duplicateBlockAlreadyPrinted {
                    lines.append("*")
                    duplicateBlockAlreadyPrinted = true
                }
                offset += bytesPerLine
                continue
            }

            duplicateBlockAlreadyPrinted = false
            if chunk.count == bytesPerLine {
                previousFullBlock = chunk
            }

            lines.append(contentsOf: mspOdFormattedLines(
                chunk: chunk,
                offset: offset + configuration.skipBytes,
                bytesPerLine: bytesPerLine,
                widthPerBlock: widthPerBlock,
                formats: configuration.formats,
                addressRadix: configuration.addressRadix,
                endian: configuration.endian
            ))
            offset += bytesPerLine
        }

        if configuration.addressRadix != .none {
            lines.append(configuration.addressRadix.format(bytes.count + configuration.skipBytes))
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

private func mspOdBytesPerLine(_ requestedWidth: Int?, leastCommonMultiple: Int) -> Int {
    if let requestedWidth, requestedWidth > 0, requestedWidth % leastCommonMultiple == 0 {
        return requestedWidth
    }
    if let requestedWidth, requestedWidth > 0 {
        return leastCommonMultiple
    }
    if leastCommonMultiple < 16 {
        return leastCommonMultiple * (16 / leastCommonMultiple)
    }
    return leastCommonMultiple
}

private func mspOdFormattedLines(
    chunk: [UInt8],
    offset: Int,
    bytesPerLine: Int,
    widthPerBlock: Int,
    formats: [MSPOdFormatSpec],
    addressRadix: MSPOdAddressRadix,
    endian: MSPOdEndian
) -> [String] {
    let paddedChunk = chunk + Array(repeating: 0, count: max(0, bytesPerLine - chunk.count))
    return formats.enumerated().map { formatIndex, format in
        let prefix: String
        if addressRadix == .none {
            prefix = ""
        } else if formatIndex == 0 {
            prefix = addressRadix.format(offset)
        } else {
            prefix = String(repeating: " ", count: addressRadix.width)
        }

        let fields = mspOdFields(
            paddedChunk: paddedChunk,
            actualByteCount: chunk.count,
            bytesPerLine: bytesPerLine,
            widthPerBlock: widthPerBlock,
            format: format,
            endian: endian
        )
        if format.hexlModeTrailer {
            return prefix + fields.text + fields.trailerPadding + mspOdHexlTrailer(chunk)
        }
        return prefix + fields.text
    }
}

private func mspOdFields(
    paddedChunk: [UInt8],
    actualByteCount: Int,
    bytesPerLine: Int,
    widthPerBlock: Int,
    format: MSPOdFormatSpec,
    endian: MSPOdEndian
) -> (text: String, trailerPadding: String) {
    let fieldsPerBlock = bytesPerLine / format.size
    let fieldsToPrint = (actualByteCount + format.size - 1) / format.size
    let padWidth = widthPerBlock - format.fieldWidth * fieldsPerBlock
    var padRemaining = padWidth
    var text = ""

    for fieldIndex in 0..<fieldsToPrint {
        let remainingFields = fieldsPerBlock - fieldIndex
        let nextPad = padWidth * (remainingFields - 1) / fieldsPerBlock
        let adjustedWidth = padRemaining - nextPad + format.fieldWidth
        let start = fieldIndex * format.size
        let end = start + format.size
        let value = format.value(from: paddedChunk[start..<end], endian: endian)
        text += mspOdLeftPad(value, width: adjustedWidth, character: " ")
        padRemaining = nextPad
    }

    let trailerPadding = String(repeating: " ", count: max(0, widthPerBlock - text.count))
    return (text, trailerPadding)
}

func mspOdUnsignedInteger(from bytes: ArraySlice<UInt8>, endian: MSPOdEndian) -> UInt64 {
    var value: UInt64 = 0
    switch endian {
    case .little:
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
    case .big:
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
    }
    return value
}

func mspOdSignedInteger(_ value: UInt64, byteCount: Int) -> Int64 {
    if byteCount == 8 {
        return Int64(bitPattern: value)
    }
    let bitCount = UInt64(byteCount * 8)
    let signBit = UInt64(1) << (bitCount - 1)
    guard (value & signBit) != 0 else {
        return Int64(value)
    }
    return Int64(value) - Int64(UInt64(1) << bitCount)
}

private func mspOdHexlTrailer(_ bytes: [UInt8]) -> String {
    let printable = bytes.map { byte -> String in
        (32...126).contains(byte) ? String(UnicodeScalar(byte)) : "."
    }.joined()
    return "  >\(printable)<"
}

func mspOdCharacterDisplay(_ byte: UInt8) -> String {
    switch byte {
    case 0:
        return "\\0"
    case 7:
        return "\\a"
    case 8:
        return "\\b"
    case 9:
        return "\\t"
    case 10:
        return "\\n"
    case 11:
        return "\\v"
    case 12:
        return "\\f"
    case 13:
        return "\\r"
    case 32...126:
        return String(UnicodeScalar(byte))
    default:
        return mspOdLeftPad(String(byte, radix: 8), width: 3, character: "0")
    }
}

func mspOdNamedCharacterDisplay(_ byte: UInt8) -> String {
    let masked = Int(byte & 0x7f)
    if masked == 127 {
        return "del"
    }
    if masked <= 32 {
        return mspOdCharacterNames[masked]
    }
    return String(UnicodeScalar(UInt8(masked)))
}

private let mspOdCharacterNames = [
    "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel",
    "bs", "ht", "nl", "vt", "ff", "cr", "so", "si",
    "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb",
    "can", "em", "sub", "esc", "fs", "gs", "rs", "us",
    "sp"
]

private func mspOdLCM(_ lhs: Int, _ rhs: Int) -> Int {
    lhs / mspOdGCD(lhs, rhs) * rhs
}

private func mspOdGCD(_ lhs: Int, _ rhs: Int) -> Int {
    var a = lhs
    var b = rhs
    while b != 0 {
        let next = a % b
        a = b
        b = next
    }
    return a
}

func mspOdLeftPad(_ value: String, width: Int, character: Character) -> String {
    String(repeating: String(character), count: max(0, width - value.count)) + value
}
