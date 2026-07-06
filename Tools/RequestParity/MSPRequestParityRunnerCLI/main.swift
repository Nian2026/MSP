import Foundation
import ModelShellProxy

@main
struct MSPRequestParityRunner {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("msp-request-parity-runner error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = try requiredURL(
            environment["MSP_REQUEST_PARITY_MODEL_BASE_URL"]
                ?? environment["MSP_PLAYGROUND_MODEL_BASE_URL"],
            name: "MSP_REQUEST_PARITY_MODEL_BASE_URL"
        )
        let apiKey = environment["MSP_REQUEST_PARITY_API_KEY"]
            ?? environment["MSP_PLAYGROUND_MODEL_API_KEY"]
            ?? "capture-proxy-client"
        let model = try requiredString(
            environment["MSP_REQUEST_PARITY_MODEL"]
                ?? environment["MSP_PLAYGROUND_MODEL"]
                ?? environment["OPENAI_MODEL"],
            name: "MSP_REQUEST_PARITY_MODEL"
        )
        let prompts = try promptSequence(from: environment)
        let outDir = URL(fileURLWithPath: environment["MSP_REQUEST_PARITY_RUNNER_OUT_DIR"] ?? "/tmp/msp-request-parity-runner")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let workspaceURL = try workspaceURL(from: environment, outDir: outDir)
        let shell = try ModelShellProxy.iOS(workspaceURL: workspaceURL).enable(.posixCore)
        let runtime = MSPAgentRuntime(
            modelConfiguration: MSPAgentModelConfiguration(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model
            ),
            execCommandBridge: shell.execCommandBridge(),
            toolCallLimit: .maximum(8)
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: model,
                environmentNotes: [
                    "Execution surface: SwiftPM MSP request parity runner.",
                    "Workspace root visible to you: /"
                ]
            )
        )

        try emit([
            "event": "runner_started",
            "model": model,
            "base_url": baseURL.absoluteString,
            "workspace": workspaceURL.path,
            "prompt_count": prompts.count
        ], outDir: outDir)

        for (index, prompt) in prompts.enumerated() {
            try emit([
                "event": "prompt_started",
                "turn": index + 1,
                "prompt": prompt
            ], outDir: outDir)
            let result = try await conversation.send(prompt, onEvent: { event in
                do {
                    try emit(eventRecord(event, turn: index + 1), outDir: outDir)
                } catch {
                    fputs("failed to write event: \(error)\n", stderr)
                }
            })
            try emit([
                "event": "prompt_completed",
                "turn": index + 1,
                "final_answer": result.finalAnswer,
                "tool_result_count": result.toolResults.count,
                "was_cancelled": result.wasCancelled
            ], outDir: outDir)
        }

        try emit([
            "event": "runner_completed",
            "prompt_count": prompts.count
        ], outDir: outDir)
    }

    private static func workspaceURL(from environment: [String: String], outDir: URL) throws -> URL {
        let workspaceURL = URL(fileURLWithPath: environment["MSP_REQUEST_PARITY_WORKSPACE_DIR"] ?? outDir.appendingPathComponent("workspace").path)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try "alpha file\nbeta file\n".write(
            to: workspaceURL.appendingPathComponent("sample.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("notes"),
            withIntermediateDirectories: true
        )
        try "request parity workspace\n".write(
            to: workspaceURL.appendingPathComponent("notes/readme.md"),
            atomically: true,
            encoding: .utf8
        )
        return workspaceURL
    }

    private static func promptSequence(from environment: [String: String]) throws -> [String] {
        if let raw = environment["MSP_REQUEST_PARITY_PROMPT_SEQUENCE_JSON"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(raw.utf8)
            guard let prompts = try JSONSerialization.jsonObject(with: data) as? [String],
                  !prompts.isEmpty else {
                throw RunnerError.invalidEnvironment("MSP_REQUEST_PARITY_PROMPT_SEQUENCE_JSON must be a non-empty JSON string array.")
            }
            return prompts
        }
        return [
            "请先用工作区命令执行 `pwd`，再执行 `printf 'alpha\\nbeta\\n'`，然后只用两句话说明结果。",
            "继续。请先用工作区命令执行 `ls -la | sed -n '1,5p'`，并在回答里引用上一轮看到的一行输出。",
            "再继续。请先用工作区命令执行 `printf 'turn3-a\\nturn3-b\\n'`，然后总结前三轮工具结果是否按顺序可见。"
        ]
    }

    private static func requiredString(_ value: String?, name: String) throws -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            throw RunnerError.invalidEnvironment("missing \(name)")
        }
        return trimmed
    }

    private static func requiredURL(_ value: String?, name: String) throws -> URL {
        let string = try requiredString(value, name: name)
        guard let url = URL(string: string), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw RunnerError.invalidEnvironment("\(name) must be an http(s) URL")
        }
        return url
    }

    private static func eventRecord(_ event: MSPAgentEvent, turn: Int) -> [String: Any] {
        switch event {
        case .turnStarted(let event):
            return [
                "event": "turn_started",
                "turn": turn,
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "started_at_unix_ms": unixMilliseconds(event.startedAt)
            ]
        case .turnAborted(let event):
            var record: [String: Any] = [
                "event": "turn_aborted",
                "turn": turn,
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "reason": event.reason.rawValue,
                "completed_at_unix_ms": unixMilliseconds(event.completedAt)
            ]
            if let durationMilliseconds = event.durationMilliseconds {
                record["duration_milliseconds"] = durationMilliseconds
            }
            return record
        case .turnSteerAccepted(let event):
            var record: [String: Any] = [
                "event": "turn_steer_accepted",
                "turn": turn,
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "turn_started_at_unix_ms": unixMilliseconds(event.turnStartedAt),
                "sequence_number": event.sequenceNumber,
                "content_text": event.contentText,
                "requested_at_unix_ms": unixMilliseconds(event.requestedAt),
                "accepted_at_unix_ms": unixMilliseconds(event.acceptedAt)
            ]
            if let clientUserMessageID = event.clientUserMessageID {
                record["client_user_message_id"] = clientUserMessageID
            }
            return record
        case .turnSteerApplied(let event):
            var record: [String: Any] = [
                "event": "turn_steer_applied",
                "turn": turn,
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": event.sequenceNumber,
                "content_text": event.contentText,
                "requested_at_unix_ms": unixMilliseconds(event.requestedAt),
                "accepted_at_unix_ms": unixMilliseconds(event.acceptedAt),
                "applied_at_unix_ms": unixMilliseconds(event.appliedAt),
                "boundary": event.boundary.rawValue,
                "model_input_item_count": event.modelInputItemCount
            ]
            if let clientUserMessageID = event.clientUserMessageID {
                record["client_user_message_id"] = clientUserMessageID
            }
            return record
        case .assistantProgressSegmentStarted(let id):
            return ["event": "assistant_progress_segment_started", "turn": turn, "id": id.uuidString]
        case .assistantProgressDelta(let text):
            return ["event": "assistant_progress_delta", "turn": turn, "text": text]
        case .assistantProgress(let text):
            return ["event": "assistant_progress", "turn": turn, "text": text]
        case .toolPreparing(let name, let statusText):
            return ["event": "tool_preparing", "turn": turn, "name": name.rawValue, "status_text": statusText]
        case .toolStarted(let call, let statusText, let batchID):
            return [
                "event": "tool_started",
                "turn": turn,
                "call_id": call.id,
                "name": call.name.rawValue,
                "status_text": statusText,
                "batch_id": batchID.uuidString
            ]
        case .toolOutputDelta(let callID, let name, let stream, let text):
            return [
                "event": "tool_output_delta",
                "turn": turn,
                "call_id": callID,
                "name": name.rawValue,
                "stream": stream.rawValue,
                "text": text
            ]
        case .toolCompleted(let result, let batchID):
            return [
                "event": "tool_completed",
                "turn": turn,
                "call_id": result.callID,
                "name": result.name.rawValue,
                "ok": result.ok,
                "batch_id": batchID.uuidString
            ]
        case .finalAnswerStarted:
            return ["event": "final_answer_started", "turn": turn]
        case .finalAnswerDelta(let text):
            return ["event": "final_answer_delta", "turn": turn, "text": text]
        case .finalAnswer(let text):
            return ["event": "final_answer", "turn": turn, "text": text]
        case .contextUsageUpdated(let usage):
            var record: [String: Any] = [
                "event": "context_usage_updated",
                "turn": turn,
                "model": usage.modelID,
                "current_tokens": usage.currentTokens
            ]
            if let value = usage.serverInputTokens {
                record["server_input_tokens"] = value
            }
            if let value = usage.serverOutputTokens {
                record["server_output_tokens"] = value
            }
            if let value = usage.serverTotalTokens {
                record["server_total_tokens"] = value
            }
            return record
        case .modelStreamRetrying(let statusText):
            return ["event": "model_stream_retrying", "turn": turn, "status_text": statusText]
        case .compactTurnStarted(let id):
            return ["event": "compact_turn_started", "turn": turn, "turn_id": id.uuidString]
        case .contextCompactionStarted(let id):
            return ["event": "context_compaction_started", "turn": turn, "item_id": id]
        case .contextCompactionCompleted(let id):
            return ["event": "context_compaction_completed", "turn": turn, "item_id": id]
        case .contextCompactionFailed(let id, message: let message):
            return [
                "event": "context_compaction_failed",
                "turn": turn,
                "item_id": id,
                "message": message
            ]
        case .compactionWarning(let message):
            return ["event": "compaction_warning", "turn": turn, "message": message]
        case .modelRequestPreparing(let statusText):
            return ["event": "model_request_preparing", "turn": turn, "status_text": statusText]
        case .threadGoalUpdated(let event):
            var record: [String: Any] = [
                "event": "thread_goal_updated",
                "turn": turn,
                "thread_id": event.threadID,
                "goal_id": event.goal.goalID,
                "status": event.goal.status.rawValue,
                "source": event.source.rawValue,
                "reason": event.reason.rawValue,
                "event_id": event.eventID,
                "occurred_at_unix_ms": unixMilliseconds(event.occurredAt)
            ]
            if let turnID = event.turnID {
                record["turn_id"] = turnID
            }
            if let previousGoal = event.previousGoal {
                record["previous_goal_id"] = previousGoal.goalID
                record["previous_status"] = previousGoal.status.rawValue
            }
            return record
        case .threadGoalCleared(let event):
            var record: [String: Any] = [
                "event": "thread_goal_cleared",
                "turn": turn,
                "thread_id": event.threadID,
                "source": event.source.rawValue,
                "event_id": event.eventID,
                "occurred_at_unix_ms": unixMilliseconds(event.occurredAt)
            ]
            if let clearedGoal = event.clearedGoal {
                record["cleared_goal_id"] = clearedGoal.goalID
                record["cleared_status"] = clearedGoal.status.rawValue
            }
            return record
        case .threadGoalAccounted(let event):
            var record: [String: Any] = [
                "event": "thread_goal_accounted",
                "turn": turn,
                "thread_id": event.threadID,
                "goal_id": event.goalID,
                "token_delta": event.tokenDelta,
                "time_delta_seconds": event.timeDeltaSeconds,
                "tokens_used": event.tokensUsed,
                "time_used_seconds": event.timeUsedSeconds,
                "status": event.status.rawValue,
                "event_id": event.eventID,
                "occurred_at_unix_ms": unixMilliseconds(event.occurredAt)
            ]
            if let turnID = event.turnID {
                record["turn_id"] = turnID
            }
            return record
        case .planProgressUpdated(let event):
            var record: [String: Any] = [
                "event": "plan_progress_updated",
                "turn": turn,
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "event_id": event.eventID,
                "plan": event.plan.map { item in
                    [
                        "step": item.step,
                        "status": item.status.rawValue
                    ]
                }
            ]
            if let explanation = event.explanation {
                record["explanation"] = explanation
            }
            return record
        case .planModeProposalDelta(let event):
            return [
                "event": "plan_mode_proposal_delta",
                "turn": turn,
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "item_id": event.itemID,
                "delta": event.delta
            ]
        case .planModeProposed(let event):
            return [
                "event": "plan_mode_proposed",
                "turn": turn,
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "proposal_id": event.proposalID,
                "proposal_version": event.proposalVersion,
                "proposed_plan_content": event.proposedPlanContent,
                "source": event.source.rawValue,
                "event_id": event.eventID,
                "proposed_at_unix_ms": unixMilliseconds(event.proposedAt)
            ]
        case .planModeApproved(let event):
            return planModeDecisionRecord(
                event,
                eventName: "plan_mode_approved",
                turn: turn
            )
        case .planModeRejected(let event):
            return planModeDecisionRecord(
                event,
                eventName: "plan_mode_rejected",
                turn: turn
            )
        case .planModeModified(let event):
            return planModeDecisionRecord(
                event,
                eventName: "plan_mode_modified",
                turn: turn
            )
        case .planModeHandoff(let event):
            return [
                "event": "plan_mode_handoff",
                "turn": turn,
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": event.proposalVersion,
                "event_id": event.eventID,
                "handoff_at_unix_ms": unixMilliseconds(event.handoffAt),
                "implementation_prompt": event.implementationPrompt,
                "model_input_item_count": event.modelInputItemCount
            ]
        case .probe(let probe):
            return [
                "event": "probe",
                "turn": turn,
                "name": probe.name,
                "fields": probe.fields
            ]
        }
    }

    private static func planModeDecisionRecord(
        _ event: MSPPlanModeDecisionEvent,
        eventName: String,
        turn: Int
    ) -> [String: Any] {
        var record: [String: Any] = [
            "event": eventName,
            "turn": turn,
            "thread_id": event.threadID,
            "proposal_id": event.proposalID,
            "proposal_version": event.proposalVersion,
            "decision": event.decision.rawValue,
            "source": event.source.rawValue,
            "event_id": event.eventID,
            "decided_at_unix_ms": unixMilliseconds(event.decidedAt)
        ]
        if let reason = event.reason {
            record["reason"] = reason
        }
        return record
    }

    private static func unixMilliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func emit(_ object: [String: Any], outDir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: sanitizeJSON(object), options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        let eventLog = outDir.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: eventLog.path) {
            FileManager.default.createFile(atPath: eventLog.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: eventLog)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private static func sanitizeJSON(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(sanitizeJSON)
        case let array as [Any]:
            return array.map(sanitizeJSON)
        case is NSNull:
            return value
        default:
            return value
        }
    }
}

private enum RunnerError: Error, CustomStringConvertible {
    case invalidEnvironment(String)

    var description: String {
        switch self {
        case .invalidEnvironment(let message):
            return message
        }
    }
}
