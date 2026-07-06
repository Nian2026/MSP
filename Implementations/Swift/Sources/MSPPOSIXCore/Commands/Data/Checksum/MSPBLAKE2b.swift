import Foundation

struct MSPBLAKE2b {
    private static let blockByteCount = 128
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3]
    ]

    private let outputByteCount: Int
    private var h: [UInt64]
    private var buffer: [UInt8] = []
    private var compressedByteCount: UInt128Compat = .zero

    init(outputByteCount: Int) {
        self.outputByteCount = outputByteCount
        self.h = Self.iv
        self.h[0] ^= 0x01010000 ^ UInt64(outputByteCount)
    }

    mutating func update(_ data: Data) {
        update([UInt8](data))
    }

    private mutating func update(_ bytes: [UInt8]) {
        var index = 0
        if !buffer.isEmpty {
            let needed = Self.blockByteCount - buffer.count
            if bytes.count > needed {
                buffer.append(contentsOf: bytes[index..<(index + needed)])
                incrementCompressedByteCount(by: Self.blockByteCount)
                compress(buffer, isLast: false)
                buffer.removeAll(keepingCapacity: true)
                index += needed
            }
        }

        while bytes.count - index > Self.blockByteCount {
            let block = Array(bytes[index..<(index + Self.blockByteCount)])
            incrementCompressedByteCount(by: Self.blockByteCount)
            compress(block, isLast: false)
            index += Self.blockByteCount
        }

        if index < bytes.count {
            buffer.append(contentsOf: bytes[index..<bytes.count])
        }
    }

    mutating func finalize() -> [UInt8] {
        incrementCompressedByteCount(by: buffer.count)
        var finalBlock = buffer
        finalBlock.append(contentsOf: repeatElement(UInt8(0), count: Self.blockByteCount - finalBlock.count))
        compress(finalBlock, isLast: true)

        var output: [UInt8] = []
        output.reserveCapacity(64)
        for word in h {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { rawBuffer in
                output.append(contentsOf: rawBuffer)
            }
        }
        return Array(output.prefix(outputByteCount))
    }

    private mutating func incrementCompressedByteCount(by count: Int) {
        compressedByteCount.add(UInt64(count))
    }

    private mutating func compress(_ block: [UInt8], isLast: Bool) {
        var m = Array(repeating: UInt64(0), count: 16)
        for i in 0..<16 {
            let start = i * 8
            var word: UInt64 = 0
            for offset in 0..<8 {
                word |= UInt64(block[start + offset]) << UInt64(offset * 8)
            }
            m[i] = word
        }

        var v = Array(repeating: UInt64(0), count: 16)
        for i in 0..<8 {
            v[i] = h[i]
            v[i + 8] = Self.iv[i]
        }
        v[12] ^= compressedByteCount.low
        v[13] ^= compressedByteCount.high
        if isLast {
            v[14] = ~v[14]
        }

        for round in 0..<12 {
            let s = Self.sigma[round]
            mspBLAKE2bG(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            mspBLAKE2bG(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            mspBLAKE2bG(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            mspBLAKE2bG(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            mspBLAKE2bG(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            mspBLAKE2bG(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mspBLAKE2bG(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            mspBLAKE2bG(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }
}

private struct UInt128Compat {
    var low: UInt64
    var high: UInt64

    static let zero = UInt128Compat(low: 0, high: 0)

    mutating func add(_ value: UInt64) {
        let (newLow, overflow) = low.addingReportingOverflow(value)
        low = newLow
        if overflow {
            high &+= 1
        }
    }
}

private func mspBLAKE2bG(
    _ v: inout [UInt64],
    _ a: Int,
    _ b: Int,
    _ c: Int,
    _ d: Int,
    _ x: UInt64,
    _ y: UInt64
) {
    v[a] = v[a] &+ v[b] &+ x
    v[d] = (v[d] ^ v[a]).rotatedRight(32)
    v[c] = v[c] &+ v[d]
    v[b] = (v[b] ^ v[c]).rotatedRight(24)
    v[a] = v[a] &+ v[b] &+ y
    v[d] = (v[d] ^ v[a]).rotatedRight(16)
    v[c] = v[c] &+ v[d]
    v[b] = (v[b] ^ v[c]).rotatedRight(63)
}

private extension UInt64 {
    func rotatedRight(_ count: UInt64) -> UInt64 {
        (self >> count) | (self << (64 - count))
    }
}
