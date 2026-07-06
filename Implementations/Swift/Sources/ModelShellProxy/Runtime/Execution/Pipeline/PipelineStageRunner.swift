import Foundation
import MSPCore

enum ShellPipelineStageRunner {
    static func run(
        _ stage: MSPStreamingPipelineRunnableStage
    ) async -> MSPStreamingPipelineStageCompletion {
        var result: MSPCommandResult
        do {
            if !stage.commandSubstitutionStderr.isEmpty {
                try await stage.standardErrorStream.write(Data(stage.commandSubstitutionStderr.utf8))
            }
            result = try await stage.command.runStreaming(
                invocation: stage.invocation,
                context: stage.context
            )
        } catch MSPCommandStreamError.brokenPipe {
            if stage.pipeOutput != nil {
                result = .failure(exitCode: ShellPipelineStreams.brokenPipeExitCode, stderr: "")
            } else {
                result = .success()
            }
        } catch MSPCommandStreamError.writeError(let reason) {
            result = .failure(exitCode: 1, stderr: "\(stage.invocation.name): \(reason)\n")
        } catch let failure as MSPCommandFailure {
            result = failure.result
        } catch {
            result = .failure(stderr: "\(stage.invocation.name): \(error)\n")
        }
        if !result.stdoutData.isEmpty {
            do {
                try await stage.standardOutputStream.write(result.stdoutData)
            } catch MSPCommandStreamError.brokenPipe {
                result.stdoutData = Data()
                if stage.pipeOutput != nil, result.exitCode == 0 {
                    result.exitCode = ShellPipelineStreams.brokenPipeExitCode
                }
            } catch MSPCommandStreamError.writeError(let reason) {
                result = .failure(exitCode: 1, stderr: "\(stage.invocation.name): \(reason)\n")
            } catch {
                result = .failure(exitCode: 1, stderr: "\(stage.invocation.name): \(error)\n")
            }
            result.stdoutData = Data()
        }
        if !result.stderrData.isEmpty {
            try? await stage.standardErrorStream.write(result.stderrData)
            result.stderrData = Data()
        }
        if let pipeOutput = stage.pipeOutput,
           await pipeOutput.didBreakOnWrite,
           result.exitCode == 0 {
            result.exitCode = ShellPipelineStreams.brokenPipeExitCode
        }
        await stage.standardInputStream.closeRead()
        await stage.standardOutputStream.closeWrite()
        await stage.standardErrorStream.closeWrite()
        return MSPStreamingPipelineStageCompletion(
            index: stage.index,
            result: result,
            fileOutputs: stage.fileOutputs,
            parsed: stage.parsed,
            startedAt: stage.startedAt,
            processSubstitutionStartIndex: stage.processSubstitutionStartIndex
        )
    }
}
