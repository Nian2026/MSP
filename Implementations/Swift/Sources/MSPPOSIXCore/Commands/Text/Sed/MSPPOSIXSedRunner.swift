import Foundation

enum MSPPOSIXSedRunner {
    static func apply(
        scriptCommands: [String],
        text: String,
        suppressAutomaticPrint: Bool,
        extendedRegex: Bool
    ) throws -> String {
        let commands = try MSPPOSIXSedParser.parseProgramCommands(
            scriptCommands,
            extendedRegex: extendedRegex
        )
        return try applyProgram(
            commands,
            to: text,
            suppressAutomaticPrint: suppressAutomaticPrint
        )
    }

    static func makeStreamingProcessor(
        scriptCommands: [String],
        suppressAutomaticPrint: Bool,
        extendedRegex: Bool
    ) throws -> StreamingProcessor {
        let commands = try MSPPOSIXSedParser.parseProgramCommands(
            scriptCommands,
            extendedRegex: extendedRegex
        )
        return StreamingProcessor(
            program: try compileProgram(commands),
            suppressAutomaticPrint: suppressAutomaticPrint
        )
    }

    private static func applyProgram(
        _ commands: [MSPPOSIXSedProgramCommand],
        to text: String,
        suppressAutomaticPrint: Bool
    ) throws -> String {
        let compiled = try compileProgram(commands)
        let records = sedTextRecords(text)
        guard !records.isEmpty else { return "" }
        var output: [SedOutputRecord] = []
        var activeRanges: [Int: Bool] = [:]
        var holdSpace = ""
        for (lineIndex, record) in records.enumerated() {
            let lineNumber = lineIndex + 1
            var currentLine = record.text
            var currentLineTerminated = record.terminated
            var appendAfter: [SedOutputRecord] = []
            var deleted = false
            var shouldQuit = false
            var quitAlreadyPrinted = false
            var substitutionHappened = false
            try executeProgramCommands(
                compiled,
                currentLine: &currentLine,
                currentLineTerminated: &currentLineTerminated,
                holdSpace: &holdSpace,
                substitutionHappened: &substitutionHappened,
                lineNumber: lineNumber,
                lineCount: records.count,
                activeRanges: &activeRanges,
                output: &output,
                appendAfter: &appendAfter,
                deleted: &deleted,
                shouldQuit: &shouldQuit,
                quitAlreadyPrinted: &quitAlreadyPrinted,
                suppressAutomaticPrint: suppressAutomaticPrint
            )
            if !suppressAutomaticPrint, !deleted, !quitAlreadyPrinted {
                output.append(SedOutputRecord(text: currentLine, terminated: currentLineTerminated))
            }
            output.append(contentsOf: appendAfter)
            if shouldQuit {
                break
            }
        }
        return joinedSedOutput(output)
    }
}
