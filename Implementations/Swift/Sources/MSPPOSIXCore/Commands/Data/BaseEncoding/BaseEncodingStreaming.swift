import Foundation

struct MSPBaseEncodingStreamingEncoder {
    var kind: MSPBaseEncodingKind
    var wrapColumn: Int
    private var carry = Data()
    private var output = ""
    private var currentColumn = 0

    init(kind: MSPBaseEncodingKind, wrapColumn: Int) {
        self.kind = kind
        self.wrapColumn = wrapColumn
    }

    mutating func append(_ data: Data) {
        var buffer = carry
        buffer.append(data)
        let groupSize = kind.inputGroupSize
        let encodableCount = (buffer.count / groupSize) * groupSize
        guard encodableCount > 0 else {
            carry = buffer
            return
        }
        appendEncoded(kind.encode(buffer.prefix(encodableCount)))
        carry = buffer.count > encodableCount ? Data(buffer.dropFirst(encodableCount)) : Data()
    }

    mutating func finalize() -> String {
        if !carry.isEmpty {
            appendEncoded(kind.encode(carry))
            carry.removeAll()
        }
        if wrapColumn > 0, !output.isEmpty, !output.hasSuffix("\n") {
            output.append("\n")
        }
        return output
    }

    mutating func encodedString(for data: Data) -> String {
        append(data)
        return finalize()
    }

    private mutating func appendEncoded(_ encoded: String) {
        guard wrapColumn > 0 else {
            output.append(encoded)
            return
        }
        for character in encoded {
            output.append(character)
            currentColumn += 1
            if currentColumn == wrapColumn {
                output.append("\n")
                currentColumn = 0
            }
        }
    }
}

struct MSPBaseEncodingStreamingDecoder {
    var kind: MSPBaseEncodingKind
    var ignoreGarbage: Bool
    private var significant: [UInt8] = []
    private var decoded = Data()
    private var invalid = false
    private var sawPadding = false

    init(kind: MSPBaseEncodingKind, ignoreGarbage: Bool) {
        self.kind = kind
        self.ignoreGarbage = ignoreGarbage
    }

    mutating func append(_ data: Data) {
        guard !invalid else {
            return
        }
        for byte in data {
            if kind.value(for: byte) != nil || (kind.allowsPadding && byte == UInt8(ascii: "=")) {
                significant.append(byte)
                processCompleteBlocks()
            } else if byte == 0x0a || ignoreGarbage {
                continue
            } else {
                invalid = true
                return
            }
            if invalid {
                return
            }
        }
    }

    mutating func finalize() -> MSPBaseEncodingDecodeResult {
        if !significant.isEmpty {
            if sawPadding {
                invalid = true
            } else if let partial = kind.decodePartial(significant) {
                decoded.append(partial)
                invalid = true
            } else {
                invalid = true
            }
        }
        return MSPBaseEncodingDecodeResult(data: decoded, invalid: invalid)
    }

    private mutating func processCompleteBlocks() {
        while significant.count >= kind.decodeBlockSize {
            if sawPadding {
                invalid = true
                return
            }
            let block = Array(significant.prefix(kind.decodeBlockSize))
            significant.removeFirst(kind.decodeBlockSize)
            guard let bytes = kind.decodeBlock(block) else {
                invalid = true
                return
            }
            decoded.append(bytes)
            sawPadding = block.contains(UInt8(ascii: "="))
        }
    }
}

struct MSPBaseEncodingDecodeResult {
    var data: Data
    var invalid: Bool
}
