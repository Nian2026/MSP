extension MSPChatValidationRun {
    mutating func validateCommandCall(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        guard commandID(event) != nil else {
            error("command-id", "command_call requires payload.command_id.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        if string(event.payload["raw_command"]) == nil {
            error("command-raw", "command_call requires raw_command.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["parse_status"]) == nil {
            warning("command-parse-status", "command_call should include parse_status.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateCommandOutput(
        _ event: MSPChatTimelineValidationEvent,
        commandCalls: Set<String>,
        commandStages: Set<String>,
        streamSeq: inout [String: Int],
        timelinePath: String
    ) {
        guard let commandID = commandID(event) else {
            error("command-output-id", "\(event.type) requires command_id.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        if !commandCalls.contains(commandID) {
            error("command-output-before-call", "\(event.type) appears before matching command_call.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if event.type == "command_stage_output", let stageIndex = int(event.payload["stage_index"]) {
            let stageKey = "\(commandID):\(stageIndex)"
            if !commandStages.contains(stageKey) {
                error("command-stage-output-before-start", "command_stage_output appears before command_stage_started.", path: timelinePath, line: event.line, eventID: event.id)
            }
        }
        let stream = string(event.payload["stream"]) ?? "stdout"
        if !["stdout", "stderr"].contains(stream), !stream.hasPrefix("x-") {
            warning("command-output-stream", "Unknown command output stream \"\(stream)\".", path: timelinePath, line: event.line, eventID: event.id)
        }
        if let outputSeq = int(event.payload["seq"]) {
            let key = "\(commandID):\(stream)"
            if let previous = streamSeq[key], outputSeq <= previous {
                error("command-stream-order", "Command output seq must increase per command and stream.", path: timelinePath, line: event.line, eventID: event.id)
            }
            streamSeq[key] = outputSeq
        }
        if bool(event.payload["projection_only"]) == true {
            warning("command-output-projection-only", "command_output should preserve canonical raw output or reference it.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateCommandStage(_ event: MSPChatTimelineValidationEvent, commandCalls: Set<String>, timelinePath: String) {
        guard let commandID = commandID(event) else {
            error("command-stage-id", "\(event.type) requires command_id.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        if !commandCalls.contains(commandID) {
            error("command-stage-before-call", "\(event.type) appears before matching command_call.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["stage_index"]) == nil {
            error("command-stage-index", "\(event.type) requires stage_index.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if bool(event.payload["skipped"]) == true, string(event.payload["skip_reason"]) == nil {
            error("command-skipped-stage-reason", "Skipped command stages require skip_reason.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateCommandComplete(_ event: MSPChatTimelineValidationEvent, commandCalls: Set<String>, timelinePath: String) {
        validateCommandTerminal(event, commandCalls: commandCalls, timelinePath: timelinePath)

        guard let exitStatus = int(event.payload["exit_status"]) else {
            error("command-exit-status", "command_complete requires exit_status.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }

        guard let stageExitCodes = intArray(event.payload["stage_exit_codes"]), !stageExitCodes.isEmpty else {
            warning("command-stage-exit-codes", "command_complete should include non-empty stage_exit_codes.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }

        let pipefail = bool(event.payload["pipefail"]) ?? false
        let negated = bool(event.payload["negated"]) ?? false
        let baseExit: Int
        if pipefail {
            baseExit = stageExitCodes.reversed().first { $0 != 0 } ?? 0
        } else {
            baseExit = stageExitCodes.last ?? 0
        }
        let expected = negated ? (baseExit == 0 ? 1 : 0) : baseExit
        if exitStatus != expected {
            error(
                "command-exit-formula",
                "exit_status \(exitStatus) does not match stage_exit_codes \(stageExitCodes), pipefail=\(pipefail), negated=\(negated); expected \(expected).",
                path: timelinePath,
                line: event.line,
                eventID: event.id
            )
        }
    }

    mutating func validateCommandTerminal(_ event: MSPChatTimelineValidationEvent, commandCalls: Set<String>, timelinePath: String) {
        guard let commandID = commandID(event) else {
            error("command-terminal-id", "\(event.type) requires command_id.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        if !commandCalls.contains(commandID) {
            error("command-terminal-before-call", "\(event.type) appears before matching command_call.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }
}
