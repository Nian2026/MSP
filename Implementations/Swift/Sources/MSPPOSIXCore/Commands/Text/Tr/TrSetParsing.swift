import Foundation
import MSPCore

private enum MSPTrSetToken {
    case scalar(UnicodeScalar)
    case repeated(UnicodeScalar, Int)
    case indefiniteRepeat(UnicodeScalar)

    var fixedLength: Int {
        switch self {
        case .scalar:
            return 1
        case .repeated(_, let count):
            return count
        case .indefiniteRepeat:
            return 0
        }
    }
}

func mspTrValidateOperandCount(
    operands: [String],
    delete: Bool,
    squeeze: Bool
) throws {
    let minOperands = 1 + (delete == squeeze ? 1 : 0)
    let maxOperands = 1 + ((!delete || squeeze) ? 1 : 0)

    if operands.count < minOperands {
        if operands.isEmpty {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "tr: missing operand\nTry 'tr --help' for more information.\n"
            ))
        }
        let explanation = squeeze
            ? "Two strings must be given when both deleting and squeezing repeats."
            : "Two strings must be given when translating."
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "tr: missing operand after \(mspTrGNUQuoted(operands.last ?? ""))\n\(explanation)\nTry 'tr --help' for more information.\n"
        ))
    }

    if operands.count > maxOperands {
        var stderr = "tr: extra operand \(mspTrGNUQuoted(operands[maxOperands]))\n"
        if operands.count == 2 {
            stderr += "Only one string may be given when deleting without squeezing repeats.\n"
        }
        stderr += "Try 'tr --help' for more information.\n"
        throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: stderr))
    }
}

func mspTrParseSet(
    _ rawValue: String,
    role: MSPTrSetRole,
    sourceLength: Int?
) throws -> MSPPOSIXScalarSetExpression {
    let expanded = try mspTrExpandedSetString(rawValue, role: role, sourceLength: sourceLength)
    return try MSPPOSIXScalarSetExpression.parse(expanded)
}

func mspTrExpandedSetString(
    _ rawValue: String,
    role: MSPTrSetRole,
    sourceLength: Int?
) throws -> String {
    let scalars = Array(rawValue.unicodeScalars)
    var tokens: [MSPTrSetToken] = []
    var index = 0
    var indefiniteRepeatCount = 0

    while index < scalars.count {
        if scalars[index] == "[",
           let repeatToken = try mspTrConsumeRepeat(in: scalars, index: &index) {
            if case .indefiniteRepeat = repeatToken {
                indefiniteRepeatCount += 1
            }
            tokens.append(repeatToken)
            continue
        }
        tokens.append(.scalar(mspTrDecodeScalar(in: scalars, index: &index)))
    }

    if role == .source, indefiniteRepeatCount > 0 {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "tr: the [c*] repeat construct may not appear in string1\n"
        ))
    }
    if indefiniteRepeatCount > 1 {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "tr: only one [c*] repeat construct may appear in string2\n"
        ))
    }

    let fixedLength = tokens.reduce(0) { $0 + $1.fixedLength }
    let fillCount = max(0, (sourceLength ?? fixedLength) - fixedLength)
    var output = String.UnicodeScalarView()
    for token in tokens {
        switch token {
        case .scalar(let scalar):
            output.append(scalar)
        case .repeated(let scalar, let count):
            for _ in 0..<count {
                output.append(scalar)
            }
        case .indefiniteRepeat(let scalar):
            for _ in 0..<fillCount {
                output.append(scalar)
            }
        }
    }
    return String(output)
}

private func mspTrConsumeRepeat(
    in scalars: [UnicodeScalar],
    index: inout Int
) throws -> MSPTrSetToken? {
    let start = index
    var probe = start + 1
    guard probe < scalars.count else { return nil }
    let repeated = mspTrDecodeScalar(in: scalars, index: &probe)
    guard probe < scalars.count, scalars[probe] == "*" else {
        return nil
    }
    probe += 1
    let digitsStart = probe
    while probe < scalars.count, scalars[probe] != "]" {
        probe += 1
    }
    guard probe < scalars.count else {
        return nil
    }

    var digitView = String.UnicodeScalarView()
    for scalar in scalars[digitsStart..<probe] {
        digitView.append(scalar)
    }
    let digits = String(digitView)
    index = probe + 1
    guard !digits.isEmpty else {
        return .indefiniteRepeat(repeated)
    }
    let radix = digits.first == "0" ? 8 : 10
    guard let count = Int(digits, radix: radix) else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "tr: invalid repeat count \(mspTrGNUQuoted(digits)) in [c*n] construct\n"
        ))
    }
    if count == 0 {
        return .indefiniteRepeat(repeated)
    }
    return .repeated(repeated, count)
}

private func mspTrDecodeScalar(in scalars: [UnicodeScalar], index: inout Int) -> UnicodeScalar {
    let scalar = scalars[index]
    guard scalar == "\\", index + 1 < scalars.count else {
        index += 1
        return scalar
    }

    let next = scalars[index + 1]
    if mspTrIsOctalDigit(next) {
        var value = 0
        var probe = index + 1
        var consumed = 0
        while probe < scalars.count, consumed < 3, mspTrIsOctalDigit(scalars[probe]) {
            value = value * 8 + Int(scalars[probe].value - 48)
            probe += 1
            consumed += 1
        }
        index = probe
        return UnicodeScalar(UInt32(value & 0xff)) ?? "\0"
    }

    index += 2
    switch next {
    case "a":
        return "\u{07}"
    case "b":
        return "\u{08}"
    case "f":
        return "\u{0C}"
    case "n":
        return "\n"
    case "r":
        return "\r"
    case "t":
        return "\t"
    case "v":
        return "\u{0B}"
    case "\\":
        return "\\"
    default:
        return next
    }
}

private func mspTrIsOctalDigit(_ scalar: UnicodeScalar) -> Bool {
    scalar.value >= 48 && scalar.value <= 55
}

func mspTrGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}
