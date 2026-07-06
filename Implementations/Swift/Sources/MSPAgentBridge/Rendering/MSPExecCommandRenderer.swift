import Foundation
import MSPCore

public struct MSPExecCommandRenderOptions: Hashable, Sendable {
    public var chunkID: String
    public var wallTimeSeconds: Double
    public var exitCode: Int32?
    public var runningSessionID: Int?
    public var maxOutputTokens: Int?

    public init(
        chunkID: String = "",
        wallTimeSeconds: Double = 0,
        exitCode: Int32? = nil,
        runningSessionID: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.chunkID = chunkID
        self.wallTimeSeconds = max(0, wallTimeSeconds)
        self.exitCode = exitCode
        self.runningSessionID = runningSessionID
        self.maxOutputTokens = maxOutputTokens
    }
}

public enum MSPExecCommandRenderer {
    public static func rawOutputText(from result: MSPCommandResult) -> String {
        if result.stderr.isEmpty {
            return result.stdout
        }
        if result.stdout.isEmpty {
            return result.stderr
        }
        return result.stdout + result.stderr
    }

    public static func renderAgentText(
        from result: MSPCommandResult,
        options: MSPExecCommandRenderOptions = MSPExecCommandRenderOptions()
    ) -> String {
        let output = MSPTerminalDisplayNormalizer.normalize(rawOutputText(from: result))
        let tokenBudget = options.maxOutputTokens ?? MSPExecCommandOutputTruncation.defaultMaxOutputTokens
        var sections: [String] = []

        if !options.chunkID.isEmpty {
            sections.append("Chunk ID: \(options.chunkID)")
        }
        sections.append(String(
            format: "Wall time: %.4f seconds",
            locale: Locale(identifier: "en_US_POSIX"),
            options.wallTimeSeconds
        ))
        let exitCode: Int32?
        if let explicitExitCode = options.exitCode {
            exitCode = explicitExitCode
        } else if options.runningSessionID == nil {
            exitCode = result.exitCode
        } else {
            exitCode = nil
        }
        if let exitCode {
            sections.append("Process exited with code \(exitCode)")
        }
        if let runningSessionID = options.runningSessionID {
            sections.append("Process running with session ID \(runningSessionID)")
        }
        sections.append("Output:")
        sections.append(MSPExecCommandOutputTruncation.formattedTruncateText(
            output,
            maxOutputTokens: tokenBudget
        ))
        return sections.joined(separator: "\n")
    }

    public static func renderAgentText(
        from read: MSPExecCommandSessionRead,
        options: MSPExecCommandRenderOptions = MSPExecCommandRenderOptions()
    ) -> String {
        renderAgentText(
            from: read.result,
            options: MSPExecCommandRenderOptions(
                chunkID: options.chunkID,
                wallTimeSeconds: read.wallTimeSeconds,
                exitCode: read.exitCode,
                runningSessionID: read.runningSessionID,
                maxOutputTokens: options.maxOutputTokens
            )
        )
    }
}
