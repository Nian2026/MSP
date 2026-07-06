import Foundation

extension MSPChatValidationRun {
    mutating func validateTimeline() {
        let timelinePath = dictionary(manifest["timeline"]).flatMap { string($0["path"]) } ?? "timeline.ndjson"
        let timelineURL = packageURL.appendingPathComponent(timelinePath)
        guard fileManager.fileExists(atPath: timelineURL.path) else {
            error("missing-timeline", "timeline.ndjson is required.", path: relativePath(timelineURL))
            return
        }

        let objects = parseNDJSONObjects(at: timelineURL)
        var previousSeq: Int?
        var commandCalls = Set<String>()
        var commandTerminals = Set<String>()
        var commandStreamSeq: [String: Int] = [:]
        var commandStages = Set<String>()
        var toolCalls = Set<String>()
        var messageDeltas: [String: MSPChatTimelineValidationEvent] = [:]
        var messageDeltaTerminals = Set<String>()

        for (line, object) in objects {
            checkProductPrivateKeys(in: object, path: relativePath(timelineURL), line: line)

            guard let id = string(object["id"]), !id.isEmpty else {
                error("event-id", "Timeline event id is required.", path: relativePath(timelineURL), line: line)
                continue
            }
            guard let type = string(object["type"]), !type.isEmpty else {
                error("event-type", "Timeline event type is required.", path: relativePath(timelineURL), line: line, eventID: id)
                continue
            }
            guard let seq = int(object["seq"]) else {
                error("event-seq", "Timeline event seq must be an integer.", path: relativePath(timelineURL), line: line, eventID: id)
                continue
            }
            guard let createdAt = string(object["created_at"]), !createdAt.isEmpty else {
                error("event-created-at", "Timeline event created_at is required.", path: relativePath(timelineURL), line: line, eventID: id)
                continue
            }
            guard let durability = string(object["durability"]) else {
                error("event-durability", "Timeline event durability is required.", path: relativePath(timelineURL), line: line, eventID: id)
                continue
            }
            guard let payload = dictionary(object["payload"]) else {
                error("event-payload", "Timeline event payload object is required.", path: relativePath(timelineURL), line: line, eventID: id)
                continue
            }

            if eventIDs.contains(id) {
                error("duplicate-event-id", "Timeline event id must be unique.", path: relativePath(timelineURL), line: line, eventID: id)
            }
            eventIDs.insert(id)

            if let previousSeq, seq <= previousSeq {
                error("timeline-seq-order", "Timeline seq must be strictly increasing.", path: relativePath(timelineURL), line: line, eventID: id)
            }
            previousSeq = seq
            maxTimelineSeq = max(maxTimelineSeq, seq)
            if let commitSeq = int(object["commit_seq"]) {
                if commitSeq < seq {
                    error("commit-before-seq", "commit_seq must not be lower than seq.", path: relativePath(timelineURL), line: line, eventID: id)
                }
                maxTimelineCommitSeq = max(maxTimelineCommitSeq, commitSeq)
            }

            if !knownDurability.contains(durability) {
                error("unknown-durability", "Unknown durability \"\(durability)\".", path: relativePath(timelineURL), line: line, eventID: id)
            }

            if !knownEvents.contains(type) {
                if !capabilities.contains("preserve_unknown_events") && !capabilities.contains("lossless_edit") {
                    warning("unknown-event-preservation", "Unknown event type \"\(type)\" without a preservation capability claim.", path: relativePath(timelineURL), line: line, eventID: id)
                }
            }

            let event = MSPChatTimelineValidationEvent(
                id: id,
                type: type,
                seq: seq,
                createdAt: createdAt,
                durability: durability,
                payload: payload,
                envelope: object,
                line: line
            )
            timelineEvents.append(event)
            validateCorePayloadBoundaries(event, timelinePath: relativePath(timelineURL))
            validateEmbeddedArtifactBlobRefs(event, timelinePath: relativePath(timelineURL))

            switch type {
            case "message":
                validateMessage(event, timelinePath: relativePath(timelineURL))
            case "message_delta":
                if let key = messageAssociationKey(event) {
                    messageDeltas[key] = event
                } else {
                    error("message-delta-association", "message_delta must have correlation_id or payload.message_id.", path: relativePath(timelineURL), line: line, eventID: id)
                }
            case "message_commit", "message_aborted", "message_superseded":
                if let key = messageAssociationKey(event) {
                    messageDeltaTerminals.insert(key)
                } else {
                    error("message-terminal-association", "\(type) must identify the delta it commits, aborts, or supersedes.", path: relativePath(timelineURL), line: line, eventID: id)
                }
            case "tool_call":
                if let callID = callID(event) {
                    toolCalls.insert(callID)
                } else {
                    error("tool-call-id", "tool_call requires call_id.", path: relativePath(timelineURL), line: line, eventID: id)
                }
            case "tool_output":
                if let callID = callID(event) {
                    if !toolCalls.contains(callID) {
                        error("tool-output-before-call", "tool_output appears before matching tool_call.", path: relativePath(timelineURL), line: line, eventID: id)
                    }
                } else {
                    error("tool-output-id", "tool_output requires call_id.", path: relativePath(timelineURL), line: line, eventID: id)
                }
            case "command_call":
                validateCommandCall(event, timelinePath: relativePath(timelineURL))
                if let commandID = commandID(event) {
                    commandCalls.insert(commandID)
                }
            case "command_output", "command_stage_output":
                validateCommandOutput(event, commandCalls: commandCalls, commandStages: commandStages, streamSeq: &commandStreamSeq, timelinePath: relativePath(timelineURL))
            case "command_stage_started":
                validateCommandStage(event, commandCalls: commandCalls, timelinePath: relativePath(timelineURL))
                if let commandID = commandID(event), let stageIndex = int(event.payload["stage_index"]) {
                    commandStages.insert("\(commandID):\(stageIndex)")
                }
            case "command_stage_completed":
                validateCommandStage(event, commandCalls: commandCalls, timelinePath: relativePath(timelineURL))
                if let commandID = commandID(event), let stageIndex = int(event.payload["stage_index"]) {
                    let key = "\(commandID):\(stageIndex)"
                    if !commandStages.contains(key) {
                        error("command-stage-complete-before-start", "command_stage_completed appears before command_stage_started.", path: relativePath(timelineURL), line: line, eventID: id)
                    }
                }
            case "command_complete":
                validateCommandComplete(event, commandCalls: commandCalls, timelinePath: relativePath(timelineURL))
                if let commandID = commandID(event) {
                    commandTerminals.insert(commandID)
                }
            case "command_error":
                validateCommandTerminal(event, commandCalls: commandCalls, timelinePath: relativePath(timelineURL))
                if let commandID = commandID(event) {
                    commandTerminals.insert(commandID)
                }
            case "artifact_ref":
                validateArtifactRef(event, timelinePath: relativePath(timelineURL))
            case "durable_compaction_checkpoint":
                validateCompactionCheckpoint(event, timelinePath: relativePath(timelineURL))
            case "conversation_fork":
                validateFork(event, timelinePath: relativePath(timelineURL))
            case "turn_steered":
                validateTurnSteered(event, timelinePath: relativePath(timelineURL))
            case "plan_mode_proposed":
                validatePlanModeProposed(event, timelinePath: relativePath(timelineURL))
            case "plan_mode_modified", "plan_mode_approved", "plan_mode_rejected":
                validatePlanModeDecision(event, timelinePath: relativePath(timelineURL))
            case "plan_mode_handoff":
                validatePlanModeHandoff(event, timelinePath: relativePath(timelineURL))
            case "thread_goal_updated":
                validateThreadGoalUpdated(event, timelinePath: relativePath(timelineURL))
            case "thread_goal_cleared":
                validateThreadGoalCleared(event, timelinePath: relativePath(timelineURL))
            case "thread_goal_accounted":
                validateThreadGoalAccounted(event, timelinePath: relativePath(timelineURL))
            case "timeline_rollback":
                validateRollback(event, timelinePath: relativePath(timelineURL))
            case "resume_capability_assessment", "resume_degraded":
                validateResumeEvent(event, timelinePath: relativePath(timelineURL))
            case "conversation_lifecycle":
                validateLifecycle(event, timelinePath: relativePath(timelineURL))
            default:
                break
            }
        }

        for (key, delta) in messageDeltas where !messageDeltaTerminals.contains(key) {
            error("message-delta-uncommitted", "message_delta has no message_commit, message_aborted, or message_superseded terminal event.", path: relativePath(timelineURL), line: delta.line, eventID: delta.id)
        }

        for commandID in commandCalls where !commandTerminals.contains(commandID) {
            warning("command-span-open", "command_call has no command_complete or command_error in this timeline slice.", path: relativePath(timelineURL), eventID: commandID)
        }

        if timelineEvents.isEmpty {
            error("empty-timeline", "timeline.ndjson must contain at least one event.", path: relativePath(timelineURL))
        }
    }

    mutating func validateCorePayloadBoundaries(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        if event.payload["provider_continuation_handle"] != nil {
            error("continuation-handle-in-core", "Provider continuation handles belong in projection metadata, journal, or namespaced runtime state, not canonical timeline payload.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if bool(event.payload["lossy"]) == true {
            if string(event.payload["loss_reason"]) == nil && event.payload["loss_matrix"] == nil {
                error("event-lossy-marker-detail", "Lossy timeline events must include loss_reason or loss_matrix.", path: timelinePath, line: event.line, eventID: event.id)
            }
        }
    }

    mutating func validateMessage(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        guard let role = string(event.payload["role"]), !role.isEmpty else {
            error("message-role", "message payload requires role.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        if string(event.payload["content"]) == nil, event.payload["content_blocks"] == nil, event.payload["content_refs"] == nil {
            warning("message-content", "message payload should include content, content_blocks, or content_refs.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if role == "assistant", string(event.payload["phase"]) == nil {
            warning("assistant-message-phase", "assistant message should mark intermediate or final phase.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }
}
