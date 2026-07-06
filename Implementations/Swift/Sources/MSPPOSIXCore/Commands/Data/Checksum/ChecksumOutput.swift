import Foundation

func mspPOSIXCksumOutputRow(
    _ checksum: MSPPOSIXCRC32Result,
    label: String?,
    delimiter: UInt8
) -> Data {
    let line = label.map {
        "\(checksum.value) \(checksum.byteCount) \($0)"
    } ?? "\(checksum.value) \(checksum.byteCount)"
    var data = Data(line.utf8)
    data.append(delimiter)
    return data
}

func mspPOSIXSumOutputRow(
    data: Data,
    label: String?,
    algorithm: MSPCksumSumAlgorithm,
    delimiter: UInt8
) -> Data {
    let line: String
    switch algorithm {
    case .bsd:
        let checksum = mspCksumBSDChecksum(data)
        let blocks = (UInt64(data.count) + 1023) / 1024
        let prefix = String(format: "%05u %5llu", checksum, blocks)
        line = label.map { "\(prefix) \($0)" } ?? prefix
    case .sysv:
        let checksum = mspCksumSysVChecksum(data)
        let blocks = (UInt64(data.count) + 511) / 512
        let prefix = "\(checksum) \(blocks)"
        line = label.map { "\(prefix) \($0)" } ?? prefix
    }
    var output = Data(line.utf8)
    output.append(delimiter)
    return output
}

private func mspCksumBSDChecksum(_ data: Data) -> UInt32 {
    var checksum: UInt32 = 0
    for byte in data {
        checksum = (checksum >> 1) + ((checksum & 1) << 15)
        checksum = (checksum + UInt32(byte)) & 0xffff
    }
    return checksum
}

private func mspCksumSysVChecksum(_ data: Data) -> UInt32 {
    var sum: UInt64 = 0
    for byte in data {
        sum += UInt64(byte)
    }
    let r = (sum & 0xffff) + ((sum & 0xffff_ffff) >> 16)
    return UInt32((r & 0xffff) + (r >> 16))
}

func mspPOSIXDigestOutputRow(
    hex: String,
    label: String,
    algorithm: MSPDigestAlgorithm,
    options: MSPDigestOptions
) -> Data {
    let needsEscape = options.delimiter == 0x0a && mspPOSIXChecksumFilenameNeedsEscaping(label)
    let displayLabel = needsEscape ? mspPOSIXChecksumEscapedFilename(label) : label
    let line: String
    if options.tagged {
        line = "\(needsEscape ? "\\" : "")\(algorithm.tagLabel) (\(displayLabel)) = \(hex)"
    } else {
        line = "\(needsEscape ? "\\" : "")\(hex) \(options.modeMarker)\(displayLabel)"
    }
    var data = Data(line.utf8)
    data.append(options.delimiter)
    return data
}

func mspPOSIXChecksumFilenameNeedsEscaping(_ filename: String) -> Bool {
    filename.contains("\\") || filename.contains("\n") || filename.contains("\r")
}

func mspPOSIXChecksumEscapedFilename(_ filename: String) -> String {
    var output = ""
    for character in filename {
        switch character {
        case "\\":
            output += "\\\\"
        case "\n":
            output += "\\n"
        case "\r":
            output += "\\r"
        default:
            output.append(character)
        }
    }
    return output
}
