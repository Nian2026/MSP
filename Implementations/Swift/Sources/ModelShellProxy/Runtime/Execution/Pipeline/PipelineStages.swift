import Foundation
import MSPCore
import MSPShell

enum MSPStreamingPipelineStagePreparation {
    case fallback
    case result(MSPStreamingPipelinePreparationResult)
    case stage(MSPStreamingPipelineStage)
}

struct MSPStreamingPipelinePreparationResult {
    var result: MSPCommandResult
    var parsed: MSPParsedCommandLine
    var commandSubstitutionStderr: String
    var expansionState: MSPShellExpansionState?
    var startedAt: Date
}

struct MSPStreamingPipelineStage {
    var command: any MSPStreamingCommand
    var invocation: MSPCommandInvocation
    var parsed: MSPParsedCommandLine
    var commandContextSeed: ShellPipelineCommandContextSeed
    var routing: MSPRedirectionRouting
    var usesPipeInput: Bool
    var assignments: [MSPParsedAssignment]
    var commandSubstitutionStderr: String
    var expansionState: MSPShellExpansionState
    var startedAt: Date
    var processSubstitutionStartIndex: Int
}

enum MSPStreamingPipelinePreparedStage {
    case command(MSPStreamingPipelineStage)
    case result(MSPStreamingPipelinePreparedResultStage)
}

struct MSPStreamingPipelinePreparedResultStage {
    var result: MSPCommandResult
    var parsed: MSPParsedCommandLine
    var startedAt: Date
}

struct MSPStreamingPipelineRunnableStage {
    var index: Int
    var command: any MSPStreamingCommand
    var invocation: MSPCommandInvocation
    var context: MSPCommandContext
    var standardInputStream: any MSPCommandInputStream
    var standardOutputStream: any MSPCommandOutputStream
    var standardErrorStream: any MSPCommandOutputStream
    var pipeOutput: MSPStreamingPipelinePipe?
    var fileOutputs: [MSPStreamingPipelineFileOutput]
    var commandSubstitutionStderr: String
    var parsed: MSPParsedCommandLine
    var startedAt: Date
    var processSubstitutionStartIndex: Int
}

struct MSPStreamingPipelineRunnableResultStage {
    var index: Int
    var result: MSPCommandResult
    var pipeInput: MSPStreamingPipelinePipe?
    var standardOutputStream: any MSPCommandOutputStream
    var standardErrorStream: any MSPCommandOutputStream
    var pipeOutput: MSPStreamingPipelinePipe?
    var parsed: MSPParsedCommandLine
    var startedAt: Date
}

struct MSPStreamingPipelineStageCompletion {
    var index: Int
    var result: MSPCommandResult
    var fileOutputs: [MSPStreamingPipelineFileOutput]
    var parsed: MSPParsedCommandLine
    var startedAt: Date
    var processSubstitutionStartIndex: Int?
}

struct MSPStreamingPipelineFileOutput {
    var binding: MSPRedirectionOutputBinding
    var buffer = MSPCommandOutputBuffer()
}
