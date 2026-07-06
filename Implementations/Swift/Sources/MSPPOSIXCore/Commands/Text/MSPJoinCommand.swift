import Foundation
import MSPCore

public struct MSPJoinCommand: MSPCommand {
    public let name = "join"
    public let summary: String? = "Join lines of two files on a common field."

    private let spec = MSPPOSIXCommandSpec(
        name: "join",
        allowedShortOptions: ["i", "z"],
        allowedLongOptions: ["ignore-case", "check-order", "nocheck-order", "header", "zero-terminated"],
        shortOptionsRequiringValue: ["t", "1", "2", "a", "e", "j", "o", "v"],
        longOptionsRequiringValue: ["field-separator"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspJoinHelp())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "join (GNU coreutils) 9.1\n")
        }

        let parsed = try spec.parse(invocation.arguments)
        try spec.requireOperandCount(parsed.operands, min: 2, max: 2)
        if parsed.operands == ["-", "-"] {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "join: both files cannot be standard input: No such file or directory\n"
            ))
        }

        let configuration = try MSPJoinConfiguration(options: parsed.options)
        var standardInputConsumed = false
        let firstData = try mspJoinDataOperand(
            parsed.operands[0],
            commandName: name,
            context: context,
            standardInputConsumed: &standardInputConsumed
        )
        let secondData = try mspJoinDataOperand(
            parsed.operands[1],
            commandName: name,
            context: context,
            standardInputConsumed: &standardInputConsumed
        )
        return MSPJoinEngine(
            configuration: configuration,
            firstOperand: parsed.operands[0],
            secondOperand: parsed.operands[1]
        )
        .run(firstData: firstData, secondData: secondData)
    }
}
