import Foundation
import MSPCore

struct MSPBaseEncodingCommandRunner {
    var command: String
    var fixedKind: MSPBaseEncodingKind?

    func run(arguments: [String], context: MSPCommandContext) throws -> MSPCommandResult {
        let parsed = mspBaseEncodingParse(arguments: arguments, command: command, fixedKind: fixedKind)
        if let result = parsed.result {
            return result
        }
        guard let kind = parsed.kind else {
            return .failure(exitCode: 1, stderr: "\(command): missing encoding type\n" + mspBaseEncodingHelpHint(command))
        }
        guard parsed.operands.count <= 1 else {
            return .failure(
                exitCode: 1,
                stderr: "\(command): extra operand \(MSPPOSIXCommandSupport.gnuQuote(parsed.operands[1]))\n" + mspBaseEncodingHelpHint(command)
            )
        }

        if let operand = parsed.operands.first, operand != "-" {
            return try runFile(
                operand,
                kind: kind,
                decode: parsed.decode,
                ignoreGarbage: parsed.ignoreGarbage,
                wrapColumn: parsed.wrapColumn,
                context: context
            )
        }

        do {
            let input = try MSPPOSIXCommandSupport.standardInputData(from: context)
            if parsed.decode {
                let decoded = kind.decode(input, ignoreGarbage: parsed.ignoreGarbage)
                return MSPCommandResult(
                    stdoutData: decoded.data,
                    stderr: decoded.invalid ? "\(command): invalid input\n" : "",
                    exitCode: decoded.invalid ? 1 : 0
                )
            }
            var encoder = MSPBaseEncodingStreamingEncoder(kind: kind, wrapColumn: parsed.wrapColumn)
            return .success(stdout: encoder.encodedString(for: input))
        } catch {
            return .failure(
                exitCode: 1,
                stderr: "\(command): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            )
        }
    }

    private func runFile(
        _ operand: String,
        kind: MSPBaseEncodingKind,
        decode: Bool,
        ignoreGarbage: Bool,
        wrapColumn: Int,
        context: MSPCommandContext
    ) throws -> MSPCommandResult {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: command)
        do {
            if decode {
                var decoder = MSPBaseEncodingStreamingDecoder(kind: kind, ignoreGarbage: ignoreGarbage)
                try mspBaseEncodingReadFileChunks(fileSystem: fileSystem, path: operand, currentDirectory: context.currentDirectory) { chunk in
                    decoder.append(chunk)
                }
                let decoded = decoder.finalize()
                return MSPCommandResult(
                    stdoutData: decoded.data,
                    stderr: decoded.invalid ? "\(command): invalid input\n" : "",
                    exitCode: decoded.invalid ? 1 : 0
                )
            }

            var encoder = MSPBaseEncodingStreamingEncoder(kind: kind, wrapColumn: wrapColumn)
            try mspBaseEncodingReadFileChunks(fileSystem: fileSystem, path: operand, currentDirectory: context.currentDirectory) { chunk in
                encoder.append(chunk)
            }
            return .success(stdout: encoder.finalize())
        } catch {
            return .failure(
                exitCode: 1,
                stderr: "\(command): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            )
        }
    }
}
