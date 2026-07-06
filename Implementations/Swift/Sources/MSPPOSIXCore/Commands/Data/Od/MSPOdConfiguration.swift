import Foundation
import MSPCore

struct MSPOdConfiguration {
    var operands: [String]
    var addressRadix: MSPOdAddressRadix
    var formats: [MSPOdFormatSpec]
    var byteLimit: Int?
    var skipBytes: Int
    var requestedWidth: Int?
    var abbreviateDuplicateBlocks: Bool
    var endian: MSPOdEndian

    static func standardResult(for arguments: [String]) -> MSPCommandResult? {
        if arguments.contains("--help") {
            return .success(stdout: mspOdUsage)
        }
        if arguments.contains("--version") {
            return .success(stdout: "od (GNU coreutils) 9.1\n")
        }
        return nil
    }

    static func parse(_ arguments: [String]) throws -> Self {
        let parsed = try spec.parse(arguments)
        var addressRadix = MSPOdAddressRadix.octal
        var formats: [MSPOdFormatSpec] = []
        var byteLimit: Int?
        var skipBytes = 0
        var requestedWidth: Int?
        var abbreviateDuplicateBlocks = true
        var endian = MSPOdEndian.little

        for option in parsed.options {
            switch option.name {
            case .short("A"), .long("address-radix"):
                addressRadix = try MSPOdAddressRadix(option.value ?? "")
            case .short("t"), .long("format"):
                formats.append(contentsOf: try mspOdFormats(from: option.value ?? ""))
            case .short("a"):
                formats.append(.namedCharacter())
            case .short("b"):
                formats.append(.numeric(kind: .octal, size: 1))
            case .short("c"):
                formats.append(.character())
            case .short("d"):
                formats.append(.numeric(kind: .unsignedDecimal, size: 2))
            case .short("D"):
                formats.append(.numeric(kind: .unsignedDecimal, size: 4))
            case .short("h"), .short("x"):
                formats.append(.numeric(kind: .hexadecimal, size: 2))
            case .short("H"), .short("X"):
                formats.append(.numeric(kind: .hexadecimal, size: 4))
            case .short("i"):
                formats.append(.numeric(kind: .signedDecimal, size: 4))
            case .short("I"), .short("l"), .short("L"):
                formats.append(.numeric(kind: .signedDecimal, size: 8))
            case .short("o"), .short("B"):
                formats.append(.numeric(kind: .octal, size: 2))
            case .short("O"):
                formats.append(.numeric(kind: .octal, size: 4))
            case .short("s"):
                formats.append(.numeric(kind: .signedDecimal, size: 2))
            case .short("N"), .long("read-bytes"):
                byteLimit = try mspOdByteCount(
                    option.value,
                    optionName: MSPPOSIXOptionParser.optionDisplayName(option)
                )
            case .short("j"), .long("skip-bytes"):
                skipBytes = try mspOdByteCount(
                    option.value,
                    optionName: MSPPOSIXOptionParser.optionDisplayName(option)
                )
            case .short("w"), .long("width"):
                requestedWidth = try option.value.map {
                    try mspOdByteCount($0, optionName: MSPPOSIXOptionParser.optionDisplayName(option))
                } ?? 32
            case .short("v"), .long("output-duplicates"):
                abbreviateDuplicateBlocks = false
            case .long("endian"):
                endian = try MSPOdEndian(option.value ?? "")
            case .long("traditional"):
                continue
            default:
                continue
            }
        }

        if formats.isEmpty {
            formats = [.numeric(kind: .octal, size: 2)]
        }

        return Self(
            operands: parsed.operands,
            addressRadix: addressRadix,
            formats: formats,
            byteLimit: byteLimit,
            skipBytes: skipBytes,
            requestedWidth: requestedWidth,
            abbreviateDuplicateBlocks: abbreviateDuplicateBlocks,
            endian: endian
        )
    }

    private static let spec = MSPPOSIXCommandSpec(
        name: "od",
        allowedShortOptions: [
            "a", "b", "c", "d", "D", "h", "H", "i", "I", "l", "L",
            "o", "O", "s", "v", "x", "X", "B"
        ],
        allowedLongOptions: ["output-duplicates", "traditional", "help", "version"],
        shortOptionsRequiringValue: ["A", "N", "j", "t"],
        longOptionsRequiringValue: ["address-radix", "format", "read-bytes", "skip-bytes", "endian"],
        shortOptionsWithOptionalValue: ["w"],
        longOptionsWithOptionalValue: ["width"]
    )
}

let mspOdUsage = """
Usage: od [OPTION]... [FILE]...
Write an unambiguous representation, octal bytes by default, of FILE to standard output.

"""
