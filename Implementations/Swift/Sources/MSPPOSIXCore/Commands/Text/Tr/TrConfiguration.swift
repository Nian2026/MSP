import Foundation
import MSPCore

struct MSPTrConfiguration: Sendable {
    var sourceSet: MSPPOSIXScalarSetExpression
    var targetSet: MSPPOSIXScalarSetExpression?
    var complement: Bool
    var delete: Bool
    var squeezeSet: MSPPOSIXScalarSetExpression?
    var squeezeComplement: Bool
    var truncateSet1: Bool
    var byteEligible: Bool
}

enum MSPTrSetRole {
    case source
    case translationTarget
    case squeezeTarget
}

func mspTrParseConfiguration(_ parsed: MSPPOSIXParsedArguments) throws -> MSPTrConfiguration {
    let complement = parsed.options.contains {
        $0.matches(short: "c", long: "complement") || $0.matches(short: "C")
    }
    let delete = parsed.options.contains { $0.matches(short: "d", long: "delete") }
    let squeeze = parsed.options.contains { $0.matches(short: "s", long: "squeeze-repeats") }
    let truncateSet1 = parsed.options.contains { $0.matches(short: "t", long: "truncate-set1") }

    try mspTrValidateOperandCount(
        operands: parsed.operands,
        delete: delete,
        squeeze: squeeze
    )

    let sourceSet = try mspTrParseSet(parsed.operands[0], role: .source, sourceLength: nil)
    let translating = parsed.operands.count == 2 && !delete
    let targetSet = parsed.operands.count == 2
        ? try mspTrParseSet(
            parsed.operands[1],
            role: translating ? .translationTarget : .squeezeTarget,
            sourceLength: translating ? sourceSet.scalars.count : nil
        )
        : nil

    if translating,
       !truncateSet1,
       !sourceSet.scalars.isEmpty,
       targetSet?.scalars.isEmpty == true {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "tr: when not truncating set1, string2 must be non-empty\n"
        ))
    }

    let byteEligible = parsed.operands.allSatisfy { operand in
        operand.unicodeScalars.allSatisfy { $0.value <= 0x7f }
    }

    return MSPTrConfiguration(
        sourceSet: sourceSet,
        targetSet: targetSet,
        complement: complement,
        delete: delete,
        squeezeSet: squeeze ? (targetSet ?? sourceSet) : nil,
        squeezeComplement: squeeze && targetSet == nil ? complement : false,
        truncateSet1: truncateSet1,
        byteEligible: byteEligible
    )
}
