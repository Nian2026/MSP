import Foundation

public enum MSPWorkspaceDirectoryOrdering: Sendable, Equatable {
    case name
    case linuxExt4HalfMD4(seed: [UInt32])

    public static let debian12OracleExt4Seed: [UInt32] = [
        0x7239_051f,
        0x5c48_1c3d,
        0xe2ee_53be,
        0x2f8f_b3ff
    ]

    public static var debian12OracleExt4: MSPWorkspaceDirectoryOrdering {
        .linuxExt4HalfMD4(seed: debian12OracleExt4Seed)
    }

    public func ordered(_ entries: [MSPDirectoryEntry]) -> [MSPDirectoryEntry] {
        switch self {
        case .name:
            return entries.sorted { $0.name < $1.name }
        case .linuxExt4HalfMD4(let seed):
            return entries.enumerated().sorted { lhs, rhs in
                let lhsHash = MSPExt4HalfMD4DirectoryHash.hash(lhs.element.name, seed: seed)
                let rhsHash = MSPExt4HalfMD4DirectoryHash.hash(rhs.element.name, seed: seed)
                if lhsHash.major != rhsHash.major {
                    return lhsHash.major < rhsHash.major
                }
                if lhsHash.minor != rhsHash.minor {
                    return lhsHash.minor < rhsHash.minor
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }
}

private enum MSPExt4HalfMD4DirectoryHash {
    private static let mask = UInt32.max
    private static let k1: UInt32 = 0
    private static let k2: UInt32 = 0x5a82_7999
    private static let k3: UInt32 = 0x6ed9_eba1

    static func hash(_ name: String, seed: [UInt32]) -> (major: UInt32, minor: UInt32) {
        let bytes = Array(name.utf8)
        var buffer = [
            UInt32(0x6745_2301),
            UInt32(0xefcd_ab89),
            UInt32(0x98ba_dcfe),
            UInt32(0x1032_5476)
        ]
        if seed.count >= 4, seed.prefix(4).contains(where: { $0 != 0 }) {
            buffer = Array(seed.prefix(4))
        }

        var offset = 0
        while offset < bytes.count {
            let chunkLength = min(32, bytes.count - offset)
            let chunk = Array(bytes[offset..<(offset + chunkLength)])
            let input = str2hashbufSigned(chunk, originalLength: bytes.count - offset, words: 8)
            halfMD4Transform(buffer: &buffer, input: input)
            offset += 32
        }
        return (major: buffer[1], minor: buffer[2])
    }

    private static func str2hashbufSigned(
        _ bytes: [UInt8],
        originalLength: Int,
        words: Int
    ) -> [UInt32] {
        var remainingWords = words
        let paddedLength = UInt32(originalLength)
        let pad = paddedLength
            | (paddedLength << 8)
            | (paddedLength << 16)
            | (paddedLength << 24)
        var value = pad
        var output: [UInt32] = []
        let count = min(bytes.count, words * 4)

        for index in 0..<count {
            let signed = Int32(Int8(bitPattern: bytes[index]))
            value = UInt32(bitPattern: signed) &+ (value << 8)
            if index % 4 == 3 {
                output.append(value)
                value = pad
                remainingWords -= 1
            }
        }

        remainingWords -= 1
        if remainingWords >= 0 {
            output.append(value)
        }
        while remainingWords > 0 {
            remainingWords -= 1
            output.append(pad)
        }
        if output.count < words {
            output.append(contentsOf: Array(repeating: pad, count: words - output.count))
        }
        return Array(output.prefix(words))
    }

    private static func halfMD4Transform(buffer: inout [UInt32], input: [UInt32]) {
        var a = buffer[0]
        var b = buffer[1]
        var c = buffer[2]
        var d = buffer[3]

        round(MSPExt4HalfMD4DirectoryHash.f, &a, b, c, d, input[0] &+ k1, 3)
        round(MSPExt4HalfMD4DirectoryHash.f, &d, a, b, c, input[1] &+ k1, 7)
        round(MSPExt4HalfMD4DirectoryHash.f, &c, d, a, b, input[2] &+ k1, 11)
        round(MSPExt4HalfMD4DirectoryHash.f, &b, c, d, a, input[3] &+ k1, 19)
        round(MSPExt4HalfMD4DirectoryHash.f, &a, b, c, d, input[4] &+ k1, 3)
        round(MSPExt4HalfMD4DirectoryHash.f, &d, a, b, c, input[5] &+ k1, 7)
        round(MSPExt4HalfMD4DirectoryHash.f, &c, d, a, b, input[6] &+ k1, 11)
        round(MSPExt4HalfMD4DirectoryHash.f, &b, c, d, a, input[7] &+ k1, 19)

        round(MSPExt4HalfMD4DirectoryHash.g, &a, b, c, d, input[1] &+ k2, 3)
        round(MSPExt4HalfMD4DirectoryHash.g, &d, a, b, c, input[3] &+ k2, 5)
        round(MSPExt4HalfMD4DirectoryHash.g, &c, d, a, b, input[5] &+ k2, 9)
        round(MSPExt4HalfMD4DirectoryHash.g, &b, c, d, a, input[7] &+ k2, 13)
        round(MSPExt4HalfMD4DirectoryHash.g, &a, b, c, d, input[0] &+ k2, 3)
        round(MSPExt4HalfMD4DirectoryHash.g, &d, a, b, c, input[2] &+ k2, 5)
        round(MSPExt4HalfMD4DirectoryHash.g, &c, d, a, b, input[4] &+ k2, 9)
        round(MSPExt4HalfMD4DirectoryHash.g, &b, c, d, a, input[6] &+ k2, 13)

        round(MSPExt4HalfMD4DirectoryHash.h, &a, b, c, d, input[3] &+ k3, 3)
        round(MSPExt4HalfMD4DirectoryHash.h, &d, a, b, c, input[7] &+ k3, 9)
        round(MSPExt4HalfMD4DirectoryHash.h, &c, d, a, b, input[2] &+ k3, 11)
        round(MSPExt4HalfMD4DirectoryHash.h, &b, c, d, a, input[6] &+ k3, 15)
        round(MSPExt4HalfMD4DirectoryHash.h, &a, b, c, d, input[1] &+ k3, 3)
        round(MSPExt4HalfMD4DirectoryHash.h, &d, a, b, c, input[5] &+ k3, 9)
        round(MSPExt4HalfMD4DirectoryHash.h, &c, d, a, b, input[0] &+ k3, 11)
        round(MSPExt4HalfMD4DirectoryHash.h, &b, c, d, a, input[4] &+ k3, 15)

        buffer[0] = buffer[0] &+ a
        buffer[1] = buffer[1] &+ b
        buffer[2] = buffer[2] &+ c
        buffer[3] = buffer[3] &+ d
    }

    private static func round(
        _ function: (UInt32, UInt32, UInt32) -> UInt32,
        _ a: inout UInt32,
        _ b: UInt32,
        _ c: UInt32,
        _ d: UInt32,
        _ x: UInt32,
        _ shift: UInt32
    ) {
        a = (a &+ function(b, c, d) &+ x).rotatedLeft(by: shift)
    }

    private static func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        z ^ (x & (y ^ z))
    }

    private static func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) &+ ((x ^ y) & z)
    }

    private static func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        x ^ y ^ z
    }
}

private extension UInt32 {
    func rotatedLeft(by shift: UInt32) -> UInt32 {
        (self << shift) | (self >> (32 - shift))
    }
}
