import Foundation

struct TrByteProcessor {
    private var translation: [UInt8]
    private var deleteMembers: [Bool]
    private var squeezeMembers: [Bool]?
    private var delete: Bool
    private var previousOutputByte: UInt8?

    init?(configuration: MSPTrConfiguration) {
        guard configuration.byteEligible,
              let sourceBytes = mspTrBytes(from: configuration.sourceSet)
        else {
            return nil
        }
        let targetBytes: [UInt8]?
        if let targetSet = configuration.targetSet {
            guard let bytes = mspTrBytes(from: targetSet) else { return nil }
            targetBytes = bytes
        } else {
            targetBytes = nil
        }
        let squeezeBytes: [UInt8]?
        if let squeezeSet = configuration.squeezeSet {
            guard let bytes = mspTrBytes(from: squeezeSet) else { return nil }
            squeezeBytes = bytes
        } else {
            squeezeBytes = nil
        }

        let sourceMembers = mspTrMembershipTable(for: sourceBytes, complement: false)
        self.deleteMembers = mspTrMembershipTable(for: sourceBytes, complement: configuration.complement)
        self.squeezeMembers = configuration.squeezeSet == nil
            ? nil
            : mspTrMembershipTable(for: squeezeBytes ?? [], complement: configuration.squeezeComplement)
        self.delete = configuration.delete
        self.translation = (0...255).map(UInt8.init)

        guard !configuration.delete, let targetBytes else {
            return
        }
        if configuration.complement {
            var targetIndex = 0
            for value in 0...255 {
                guard !sourceMembers[value] else { continue }
                guard let replacement = mspTrReplacementByte(
                    at: targetIndex,
                    in: targetBytes,
                    truncate: configuration.truncateSet1
                ) else {
                    break
                }
                translation[value] = replacement
                targetIndex += 1
            }
        } else {
            for (offset, source) in sourceBytes.enumerated() {
                guard let replacement = mspTrReplacementByte(
                    at: offset,
                    in: targetBytes,
                    truncate: configuration.truncateSet1
                ) else {
                    break
                }
                translation[Int(source)] = replacement
            }
        }
    }

    mutating func process(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(input.count)
        for byte in input {
            if delete, deleteMembers[Int(byte)] {
                continue
            }
            let transformed = delete ? byte : translation[Int(byte)]
            if let squeezeMembers,
               transformed == previousOutputByte,
               squeezeMembers[Int(transformed)] {
                continue
            }
            output.append(transformed)
            previousOutputByte = transformed
        }
        return output
    }
}

private func mspTrBytes(from expression: MSPPOSIXScalarSetExpression) -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(expression.scalars.count)
    for scalar in expression.scalars {
        guard scalar.value <= 0xff else {
            return nil
        }
        bytes.append(UInt8(scalar.value))
    }
    return bytes
}

private func mspTrMembershipTable(for bytes: [UInt8], complement: Bool) -> [Bool] {
    var table = Array(repeating: false, count: 256)
    for byte in bytes {
        table[Int(byte)] = true
    }
    if complement {
        table = table.map { !$0 }
    }
    return table
}

private func mspTrReplacementByte(
    at index: Int,
    in targetBytes: [UInt8],
    truncate: Bool
) -> UInt8? {
    guard !targetBytes.isEmpty else {
        return nil
    }
    if index < targetBytes.count {
        return targetBytes[index]
    }
    return truncate ? nil : targetBytes[targetBytes.count - 1]
}
