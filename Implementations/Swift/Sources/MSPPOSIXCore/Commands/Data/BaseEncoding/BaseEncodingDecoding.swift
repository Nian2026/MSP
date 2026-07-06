import Foundation

extension MSPBaseEncodingKind {
    func decodeBlock(_ block: [UInt8]) -> Data? {
        switch self {
        case .base64, .base64URL:
            return mspBaseEncodingDecodeBase64Block(block, kind: self)
        case .base32, .base32Hex:
            return mspBaseEncodingDecodeBase32Block(block, kind: self)
        case .base16:
            guard block.count == 2,
                  let high = value(for: block[0]),
                  let low = value(for: block[1]) else {
                return nil
            }
            return Data([(high << 4) | low])
        case .base2MSBF:
            guard block.count == 8 else {
                return nil
            }
            var byte: UInt8 = 0
            for bit in block {
                guard let value = value(for: bit) else {
                    return nil
                }
                byte = (byte << 1) | value
            }
            return Data([byte])
        case .base2LSBF:
            guard block.count == 8 else {
                return nil
            }
            var byte: UInt8 = 0
            for (index, bit) in block.enumerated() {
                guard let value = value(for: bit) else {
                    return nil
                }
                byte |= value << UInt8(index)
            }
            return Data([byte])
        }
    }

    func decodePartial(_ block: [UInt8]) -> Data? {
        switch self {
        case .base64, .base64URL:
            guard block.count >= 2 else {
                return Data()
            }
            var padded = block
            while padded.count < 4 {
                padded.append(UInt8(ascii: "="))
            }
            return decodeBlock(padded)
        case .base32, .base32Hex:
            var padded = block
            while padded.count < 8 {
                padded.append(UInt8(ascii: "="))
            }
            return decodeBlock(padded)
        case .base16, .base2MSBF, .base2LSBF:
            return nil
        }
    }
}

private func mspBaseEncodingDecodeBase64Block(_ block: [UInt8], kind: MSPBaseEncodingKind) -> Data? {
    guard block.count == 4,
          let first = kind.value(for: block[0]),
          let second = kind.value(for: block[1]) else {
        return nil
    }
    if block[2] == UInt8(ascii: "=") {
        guard block[3] == UInt8(ascii: "=") else {
            return nil
        }
        return Data([(first << 2) | (second >> 4)])
    }
    guard let third = kind.value(for: block[2]) else {
        return nil
    }
    if block[3] == UInt8(ascii: "=") {
        return Data([
            (first << 2) | (second >> 4),
            ((second & 0x0f) << 4) | (third >> 2)
        ])
    }
    guard let fourth = kind.value(for: block[3]) else {
        return nil
    }
    return Data([
        (first << 2) | (second >> 4),
        ((second & 0x0f) << 4) | (third >> 2),
        ((third & 0x03) << 6) | fourth
    ])
}

private func mspBaseEncodingDecodeBase32Block(_ block: [UInt8], kind: MSPBaseEncodingKind) -> Data? {
    guard block.count == 8 else {
        return nil
    }
    let paddingStart = block.firstIndex(of: UInt8(ascii: "=")) ?? block.count
    guard block[paddingStart...].allSatisfy({ $0 == UInt8(ascii: "=") }) else {
        return nil
    }
    let outputCount: Int
    switch block.count - paddingStart {
    case 0:
        outputCount = 5
    case 1:
        outputCount = 4
    case 3:
        outputCount = 3
    case 4:
        outputCount = 2
    case 6:
        outputCount = 1
    default:
        return nil
    }

    var bitBuffer: UInt64 = 0
    var bitCount = 0
    var output = Data()
    for byte in block.prefix(paddingStart) {
        guard let value = kind.value(for: byte) else {
            return nil
        }
        bitBuffer = (bitBuffer << 5) | UInt64(value)
        bitCount += 5
        while bitCount >= 8, output.count < outputCount {
            bitCount -= 8
            output.append(UInt8((bitBuffer >> UInt64(bitCount)) & 0xff))
        }
    }
    return output.count == outputCount ? output : nil
}

func mspBaseEncodingBase64Value(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"):
        return byte - UInt8(ascii: "A")
    case UInt8(ascii: "a")...UInt8(ascii: "z"):
        return byte - UInt8(ascii: "a") + 26
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return byte - UInt8(ascii: "0") + 52
    case UInt8(ascii: "+"):
        return 62
    case UInt8(ascii: "/"):
        return 63
    default:
        return nil
    }
}
