extension MSPPOSIXSedRunner {
    struct StreamingProcessor {
        private let program: CompiledSedProgram
        private let suppressAutomaticPrint: Bool
        private var activeRanges: [Int: Bool] = [:]
        private var holdSpace = ""
        private var lineNumber = 0

        init(program: CompiledSedProgram, suppressAutomaticPrint: Bool) {
            self.program = program
            self.suppressAutomaticPrint = suppressAutomaticPrint
        }

        mutating func process(text: String, terminated: Bool, isLast: Bool) throws -> StreamingResult {
            lineNumber += 1
            var currentLine = text
            var currentLineTerminated = terminated
            var output: [SedOutputRecord] = []
            var appendAfter: [SedOutputRecord] = []
            var deleted = false
            var shouldQuit = false
            var quitAlreadyPrinted = false
            var substitutionHappened = false
            try MSPPOSIXSedRunner.executeProgramCommands(
                program,
                currentLine: &currentLine,
                currentLineTerminated: &currentLineTerminated,
                holdSpace: &holdSpace,
                substitutionHappened: &substitutionHappened,
                lineNumber: lineNumber,
                lineCount: isLast ? lineNumber : Int.max,
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
            return StreamingResult(output: joinedSedOutput(output), shouldQuit: shouldQuit)
        }
    }

    struct StreamingResult {
        var output: String
        var shouldQuit: Bool
    }
}
