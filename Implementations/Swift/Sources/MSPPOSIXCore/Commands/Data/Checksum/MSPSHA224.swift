import Foundation

struct MSPSHA224 {
    private static let blockByteCount = 64
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var h: [UInt32] = [
        0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939,
        0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4
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
        return h.prefix(7).flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = Array(repeating: UInt32(0), count: 64)
        for i in 0..<16 {
            let start = i * 4
            w[i] = (UInt32(block[start]) << 24)
                | (UInt32(block[start + 1]) << 16)
                | (UInt32(block[start + 2]) << 8)
                | UInt32(block[start + 3])
        }
        for i in 16..<64 {
            let s0 = mspChecksumRotateRight(w[i - 15], 7) ^ mspChecksumRotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = mspChecksumRotateRight(w[i - 2], 17) ^ mspChecksumRotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for i in 0..<64 {
            let s1 = mspChecksumRotateRight(e, 6) ^ mspChecksumRotateRight(e, 11) ^ mspChecksumRotateRight(e, 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = mspChecksumRotateRight(a, 2) ^ mspChecksumRotateRight(a, 13) ^ mspChecksumRotateRight(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
        h[5] &+= f
        h[6] &+= g
        h[7] &+= hh
    }
}
