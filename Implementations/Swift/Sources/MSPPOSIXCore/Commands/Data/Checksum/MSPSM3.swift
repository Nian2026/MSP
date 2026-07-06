import Foundation

struct MSPSM3 {
    private static let blockByteCount = 64
    private var h: [UInt32] = [
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    mutating func update(_ data: Data) {
        let bytes = [UInt8](data)
        byteCount &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        while buffer.count >= Self.blockByteCount {
            let block = Array(buffer.prefix(Self.blockByteCount))
            compress(block)
            buffer.removeFirst(Self.blockByteCount)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % Self.blockByteCount != 56 {
            buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= Self.blockByteCount {
            let block = Array(buffer.prefix(Self.blockByteCount))
            compress(block)
            buffer.removeFirst(Self.blockByteCount)
        }
        return h.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = Array(repeating: UInt32(0), count: 68)
        var w1 = Array(repeating: UInt32(0), count: 64)
        for i in 0..<16 {
            let start = i * 4
            w[i] = (UInt32(block[start]) << 24)
                | (UInt32(block[start + 1]) << 16)
                | (UInt32(block[start + 2]) << 8)
                | UInt32(block[start + 3])
        }
        for i in 16..<68 {
            w[i] = sm3P1(w[i - 16] ^ w[i - 9] ^ mspChecksumRotateLeft(w[i - 3], 15))
                ^ mspChecksumRotateLeft(w[i - 13], 7)
                ^ w[i - 6]
        }
        for i in 0..<64 {
            w1[i] = w[i] ^ w[i + 4]
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for j in 0..<64 {
            let t: UInt32 = j < 16 ? 0x79cc4519 : 0x7a879d8a
            let ss1 = mspChecksumRotateLeft(
                mspChecksumRotateLeft(a, 12) &+ e &+ mspChecksumRotateLeft(t, UInt32(j)),
                7
            )
            let ss2 = ss1 ^ mspChecksumRotateLeft(a, 12)
            let tt1 = sm3FF(a, b, c, round: j) &+ d &+ ss2 &+ w1[j]
            let tt2 = sm3GG(e, f, g, round: j) &+ hh &+ ss1 &+ w[j]
            d = c
            c = mspChecksumRotateLeft(b, 9)
            b = a
            a = tt1
            hh = g
            g = mspChecksumRotateLeft(f, 19)
            f = e
            e = sm3P0(tt2)
        }

        h[0] ^= a
        h[1] ^= b
        h[2] ^= c
        h[3] ^= d
        h[4] ^= e
        h[5] ^= f
        h[6] ^= g
        h[7] ^= hh
    }

    private func sm3FF(_ x: UInt32, _ y: UInt32, _ z: UInt32, round: Int) -> UInt32 {
        round < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z))
    }

    private func sm3GG(_ x: UInt32, _ y: UInt32, _ z: UInt32, round: Int) -> UInt32 {
        round < 16 ? (x ^ y ^ z) : ((x & y) | ((~x) & z))
    }

    private func sm3P0(_ x: UInt32) -> UInt32 {
        x ^ mspChecksumRotateLeft(x, 9) ^ mspChecksumRotateLeft(x, 17)
    }

    private func sm3P1(_ x: UInt32) -> UInt32 {
        x ^ mspChecksumRotateLeft(x, 15) ^ mspChecksumRotateLeft(x, 23)
    }
}
