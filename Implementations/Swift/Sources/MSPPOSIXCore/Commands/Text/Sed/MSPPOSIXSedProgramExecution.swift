extension MSPPOSIXSedRunner {
    @discardableResult
    static func executeProgramCommands(
        _ program: CompiledSedProgram,
        currentLine: inout String,
        currentLineTerminated: inout Bool,
        holdSpace: inout String,
        substitutionHappened: inout Bool,
        lineNumber: Int,
        lineCount: Int,
        activeRanges: inout [Int: Bool],
        output: inout [SedOutputRecord],
        appendAfter: inout [SedOutputRecord],
        deleted: inout Bool,
        shouldQuit: inout Bool,
        quitAlreadyPrinted: inout Bool,
        suppressAutomaticPrint: Bool
    ) throws -> Bool {
        let commands = program.commands
        let labels = program.labels
        var index = 0
        var iterations = 0
        var addressMatchCache: [Int: Bool] = [:]
        while index < commands.count {
            iterations += 1
            if iterations > 10_000 {
                throw MSPPOSIXSedError.failure("sed: command execution exceeded iteration limit")
            }
            let command = commands[index]
            var gatesMatched = true
            for gate in command.gates {
                if let cached = addressMatchCache[gate.id] {
                    gatesMatched = cached
                } else {
                    let matched = try programCommand(
                        gate.command,
                        matches: currentLine,
                        lineNumber: lineNumber,
                        lineCount: lineCount,
                        activeRanges: &activeRanges,
                        commandID: gate.id
                    )
                    addressMatchCache[gate.id] = matched
                    gatesMatched = matched
                }
                if !gatesMatched {
                    break
                }
            }
            guard gatesMatched else {
                index += 1
                continue
            }
            guard try programCommand(
                command.command,
                matches: currentLine,
                lineNumber: lineNumber,
                lineCount: lineCount,
                activeRanges: &activeRanges,
                commandID: command.id
            ) else {
                index += 1
                continue
            }
            switch command.kind {
            case .substitution(let substitution, let regex):
                if applySubstitution(
                    substitution,
                    regex: regex,
                    to: &currentLine,
                    currentLineTerminated: currentLineTerminated,
                    output: &output
                ) {
                    substitutionHappened = true
                }
            case .print:
                output.append(SedOutputRecord(text: currentLine, terminated: currentLineTerminated))
            case .list:
                output.append(SedOutputRecord(text: listEscapedLine(currentLine), terminated: true))
            case .quit:
                if !suppressAutomaticPrint, !deleted {
                    output.append(SedOutputRecord(text: currentLine, terminated: currentLineTerminated))
                    quitAlreadyPrinted = true
                }
                shouldQuit = true
            case .delete:
                deleted = true
            case .append(let text):
                appendAfter.append(SedOutputRecord(text: text, terminated: true))
            case .insert(let text):
                output.append(SedOutputRecord(text: text, terminated: true))
            case .change(let text):
                currentLine = text
                currentLineTerminated = true
                deleted = false
            case .hold:
                holdSpace = currentLine
            case .holdAppend:
                holdSpace += "\n" + currentLine
            case .get:
                currentLine = holdSpace
            case .getAppend:
                currentLine += "\n" + holdSpace
            case .exchange:
                swap(&currentLine, &holdSpace)
            case .label:
                break
            case .branch(let label):
                guard let label else { return false }
                if let target = labels[label] {
                    index = target
                    continue
                }
                throw MSPPOSIXSedError.usage("sed: undefined label '\(label)'")
            case .branchIfSubstitution(let label):
                guard substitutionHappened else {
                    index += 1
                    continue
                }
                substitutionHappened = false
                guard let label else { return false }
                if let target = labels[label] {
                    index = target
                    continue
                }
                throw MSPPOSIXSedError.usage("sed: undefined label '\(label)'")
            }
            if deleted { return false }
            if shouldQuit { return false }
            index += 1
        }
        return true
    }

    private static func programCommand(
        _ command: MSPPOSIXSedProgramCommand,
        matches line: String,
        lineNumber: Int,
        lineCount: Int,
        activeRanges: inout [Int: Bool],
        commandID: Int
    ) throws -> Bool {
        func applyNegation(_ value: Bool) -> Bool {
            command.negated ? !value : value
        }
        guard let start = command.start else { return !command.negated }
        if let end = command.end {
            if activeRanges[commandID] == true {
                if try MSPPOSIXSedAddressing.address(end, matches: line, lineNumber: lineNumber, lineCount: lineCount) {
                    activeRanges[commandID] = false
                }
                return applyNegation(true)
            }
            guard try MSPPOSIXSedAddressing.address(start, matches: line, lineNumber: lineNumber, lineCount: lineCount) else {
                return applyNegation(false)
            }
            activeRanges[commandID] = true
            if try MSPPOSIXSedAddressing.address(end, matches: line, lineNumber: lineNumber, lineCount: lineCount) {
                activeRanges[commandID] = false
            }
            return applyNegation(true)
        }
        return applyNegation(try MSPPOSIXSedAddressing.address(start, matches: line, lineNumber: lineNumber, lineCount: lineCount))
    }
}
