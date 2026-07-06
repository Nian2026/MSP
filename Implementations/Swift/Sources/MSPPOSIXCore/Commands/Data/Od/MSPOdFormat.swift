import Foundation
import MSPCore

enum MSPOdAddressRadix: Equatable {
    case decimal
    case octal
    case hexadecimal
    case none

    init(_ rawValue: String) throws {
        guard let first = rawValue.first else {
            throw mspOdFailure("od: missing address radix\n")
        }
        switch first {
        case "d":
            self = .decimal
        case "o":
            self = .octal
        case "x":
            self = .hexadecimal
        case "n":
            self = .none
        default:
            throw mspOdFailure(
                "od: invalid output address radix '\(first)'; it must be one character from [doxn]\n"
            )
        }
    }

    var width: Int {
        switch self {
        case .decimal, .octal:
            return 7
        case .hexadecimal:
            return 6
        case .none:
            return 0
        }
    }

    func format(_ value: Int) -> String {
        switch self {
        case .decimal:
            return mspOdLeftPad(String(value), width: width, character: "0")
        case .octal:
            return mspOdLeftPad(String(value, radix: 8), width: width, character: "0")
        case .hexadecimal:
            return mspOdLeftPad(String(value, radix: 16), width: width, character: "0")
        case .none:
            return ""
        }
    }
}

enum MSPOdEndian {
    case big
    case little

    init(_ rawValue: String) throws {
        switch rawValue {
        case "big":
            self = .big
        case "little":
            self = .little
        default:
            throw mspOdFailure("od: invalid endian value \(rawValue)\n")
        }
    }
}

enum MSPOdNumericKind {
    case signedDecimal
    case octal
    case unsignedDecimal
    case hexadecimal
}

enum MSPOdFormatKind {
    case numeric(MSPOdNumericKind)
    case character
    case namedCharacter
}

struct MSPOdFormatSpec {
    var kind: MSPOdFormatKind
    var size: Int
    var hexlModeTrailer: Bool

    static func numeric(kind: MSPOdNumericKind, size: Int, hexlModeTrailer: Bool = false) -> Self {
        Self(kind: .numeric(kind), size: size, hexlModeTrailer: hexlModeTrailer)
    }

    static func character(hexlModeTrailer: Bool = false) -> Self {
        Self(kind: .character, size: 1, hexlModeTrailer: hexlModeTrailer)
    }

    static func namedCharacter(hexlModeTrailer: Bool = false) -> Self {
        Self(kind: .namedCharacter, size: 1, hexlModeTrailer: hexlModeTrailer)
    }

    var fieldWidth: Int {
        switch kind {
        case .numeric(.signedDecimal):
            return mspOdSignedDecimalDigits[size] ?? 1
        case .numeric(.octal):
            return mspOdOctalDigits[size] ?? 1
        case .numeric(.unsignedDecimal):
            return mspOdUnsignedDecimalDigits[size] ?? 1
        case .numeric(.hexadecimal):
            return mspOdHexDigits[size] ?? 1
        case .character, .namedCharacter:
            return 3
        }
    }

    func value(from bytes: ArraySlice<UInt8>, endian: MSPOdEndian) -> String {
        switch kind {
        case .numeric(let numericKind):
            let rawValue = mspOdUnsignedInteger(from: bytes, endian: endian)
            switch numericKind {
            case .signedDecimal:
                return String(mspOdSignedInteger(rawValue, byteCount: size))
            case .octal:
                return mspOdLeftPad(String(rawValue, radix: 8), width: fieldWidth, character: "0")
            case .unsignedDecimal:
                return String(rawValue)
            case .hexadecimal:
                return mspOdLeftPad(String(rawValue, radix: 16), width: fieldWidth, character: "0")
            }
        case .character:
            return mspOdCharacterDisplay(bytes.first ?? 0)
        case .namedCharacter:
            return mspOdNamedCharacterDisplay(bytes.first ?? 0)
        }
    }
}

private let mspOdOctalDigits = [1: 3, 2: 6, 4: 11, 8: 22]
private let mspOdSignedDecimalDigits = [1: 4, 2: 6, 4: 11, 8: 20]
private let mspOdUnsignedDecimalDigits = [1: 3, 2: 5, 4: 10, 8: 20]
private let mspOdHexDigits = [1: 2, 2: 4, 4: 8, 8: 16]

func mspOdFormats(from rawValue: String) throws -> [MSPOdFormatSpec] {
    guard !rawValue.isEmpty else {
        throw mspOdFailure("od: missing format type\n")
    }

    var formats: [MSPOdFormatSpec] = []
    var index = rawValue.startIndex
    while index < rawValue.endIndex {
        let kindCharacter = rawValue[index]
        rawValue.formIndex(after: &index)

        switch kindCharacter {
        case "d", "o", "u", "x":
            let size = try mspOdIntegralSize(in: rawValue, index: &index)
            let trailer = mspOdConsumeHexlTrailer(in: rawValue, index: &index)
            let kind: MSPOdNumericKind
            switch kindCharacter {
            case "d":
                kind = .signedDecimal
            case "o":
                kind = .octal
            case "u":
                kind = .unsignedDecimal
            default:
                kind = .hexadecimal
            }
            formats.append(.numeric(kind: kind, size: size, hexlModeTrailer: trailer))
        case "a":
            let trailer = mspOdConsumeHexlTrailer(in: rawValue, index: &index)
            formats.append(.namedCharacter(hexlModeTrailer: trailer))
        case "c":
            let trailer = mspOdConsumeHexlTrailer(in: rawValue, index: &index)
            formats.append(.character(hexlModeTrailer: trailer))
        default:
            throw mspOdFailure("od: unsupported format \(rawValue)\n")
        }
    }
    return formats
}

private func mspOdIntegralSize(in rawValue: String, index: inout String.Index) throws -> Int {
    if index < rawValue.endIndex {
        switch rawValue[index] {
        case "C":
            rawValue.formIndex(after: &index)
            return 1
        case "S":
            rawValue.formIndex(after: &index)
            return 2
        case "I":
            rawValue.formIndex(after: &index)
            return 4
        case "L":
            rawValue.formIndex(after: &index)
            return 8
        default:
            break
        }
    }

    let digitStart = index
    while index < rawValue.endIndex, rawValue[index].isNumber {
        rawValue.formIndex(after: &index)
    }
    if digitStart == index {
        return 4
    }
    let sizeText = String(rawValue[digitStart..<index])
    guard let size = Int(sizeText), [1, 2, 4, 8].contains(size) else {
        throw mspOdFailure("od: unsupported integral size \(sizeText)\n")
    }
    return size
}

private func mspOdConsumeHexlTrailer(in rawValue: String, index: inout String.Index) -> Bool {
    guard index < rawValue.endIndex, rawValue[index] == "z" else {
        return false
    }
    rawValue.formIndex(after: &index)
    return true
}

func mspOdByteCount(_ value: String?, optionName: String) throws -> Int {
    guard let value, !value.isEmpty else {
        throw mspOdFailure("od: invalid \(optionName) argument ''\n")
    }

    let suffixMultipliers: [(String, Int)] = [
        ("GB", 1_000_000_000), ("G", 1_073_741_824),
        ("MB", 1_000_000), ("M", 1_048_576),
        ("KB", 1_000), ("K", 1_024),
        ("b", 512)
    ]
    var numberText = value
    var multiplier = 1
    for (suffix, suffixMultiplier) in suffixMultipliers where numberText.hasSuffix(suffix) {
        numberText.removeLast(suffix.count)
        multiplier = suffixMultiplier
        break
    }

    let parsed: Int?
    if numberText.hasPrefix("0x") || numberText.hasPrefix("0X") {
        parsed = Int(numberText.dropFirst(2), radix: 16)
    } else if numberText.hasPrefix("0"), numberText.count > 1 {
        parsed = Int(numberText, radix: 8)
    } else {
        parsed = Int(numberText, radix: 10)
    }
    guard let parsed, parsed >= 0 else {
        throw mspOdFailure("od: invalid \(optionName) argument '\(value)'\n")
    }
    return parsed * multiplier
}

func mspOdFailure(_ message: String) -> MSPCommandFailure {
    MSPCommandFailure(result: .failure(exitCode: 1, stderr: message))
}
