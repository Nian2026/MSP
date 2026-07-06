func mspChecksumRotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
    let normalized = count & 31
    guard normalized != 0 else {
        return value
    }
    return (value << normalized) | (value >> (32 - normalized))
}

func mspChecksumRotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
    let normalized = count & 31
    guard normalized != 0 else {
        return value
    }
    return (value >> normalized) | (value << (32 - normalized))
}
