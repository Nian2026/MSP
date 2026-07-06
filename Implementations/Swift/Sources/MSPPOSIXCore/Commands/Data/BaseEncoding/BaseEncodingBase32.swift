import Foundation

func mspBaseEncodingBase32Value(_ byte: UInt8, alphabet: [UInt8]) -> UInt8? {
    alphabet.firstIndex(of: byte).map(UInt8.init)
}

func mspBaseEncodingBase32Encode(_ data: Data, alphabet: [UInt8]) -> String {
    guard !data.isEmpty else {
        return ""
    }
    let bytes = [UInt8](data)
    var output: [UInt8] = []
    var index = 0
    while index < bytes.count {
        let remaining = bytes.count - index
        let count = min(5, remaining)
        let chunk = Array(bytes[index..<(index + count)])
        var bitBuffer: UInt64 = 0
        for byte in chunk {
            bitBuffer = (bitBuffer << 8) | UInt64(byte)
        }
        let totalBits = count * 8
        let outputChars = (totalBits + 4) / 5
        let paddedBuffer = bitBuffer << UInt64(outputChars * 5 - totalBits)
        for position in 0..<outputChars {
            let shift = UInt64((outputChars - position - 1) * 5)
            output.append(alphabet[Int((paddedBuffer >> shift) & 0x1f)])
        }
        let padding = (8 - outputChars) % 8
        output.append(contentsOf: Array(repeating: UInt8(ascii: "="), count: padding))
        index += count
    }
    return String(decoding: output, as: UTF8.self)
}
