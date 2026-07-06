import Foundation

struct MSPPOSIXCRC32Result: Sendable, Equatable {
    var value: UInt32
    var byteCount: Int
}

func mspPOSIXCksum(_ data: Data) -> MSPPOSIXCRC32Result {
    var accumulator = MSPPOSIXCRC32Accumulator()
    accumulator.update(data)
    return accumulator.finalize()
}

struct MSPPOSIXCRC32Accumulator {
    var crc: UInt32 = 0
    var byteCount = 0

    mutating func update(_ data: Data) {
        byteCount += data.count
        for byte in data {
            let tableIndex = Int(((crc >> 24) ^ UInt32(byte)) & 0xff)
            crc = (crc << 8) ^ mspPOSIXCRC32Table[tableIndex]
        }
    }

    func finalize() -> MSPPOSIXCRC32Result {
        var finalizedCRC = crc
        var length = byteCount
        while length > 0 {
            let byte = UInt8(length & 0xff)
            let tableIndex = Int(((finalizedCRC >> 24) ^ UInt32(byte)) & 0xff)
            finalizedCRC = (finalizedCRC << 8) ^ mspPOSIXCRC32Table[tableIndex]
            length >>= 8
        }

        return MSPPOSIXCRC32Result(value: ~finalizedCRC, byteCount: byteCount)
    }
}

private let mspPOSIXCRC32Table: [UInt32] = {
    let polynomial: UInt32 = 0x04C11DB7
    return (0..<256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0..<8 {
            if (crc & 0x80000000) != 0 {
                crc = (crc << 1) ^ polynomial
            } else {
                crc <<= 1
            }
        }
        return crc
    }
}()

func mspPOSIXHexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
