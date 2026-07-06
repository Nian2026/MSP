import Foundation
import MSPCore

func mspJoinDataOperand(
    _ operand: String,
    commandName: String,
    context: MSPCommandContext,
    standardInputConsumed: inout Bool
) throws -> Data {
    if operand == "-" {
        defer { standardInputConsumed = true }
        return standardInputConsumed ? Data() : context.standardInput
    }
    let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: commandName)
    do {
        return try fileSystem.readFile(operand, from: context.currentDirectory)
    } catch let failure as MSPCommandFailure {
        throw failure
    } catch {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "join: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
        ))
    }
}
