import Foundation

extension MSPChatValidationRun {
    mutating func validateArtifactRef(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validateStandaloneArtifactRef(event, timelinePath: timelinePath)
    }

    mutating func validateCompactionCheckpoint(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        let payload = event.payload
        if dictionary(payload["source_event_range"]) == nil {
            error("compaction-source-range", "durable_compaction_checkpoint requires source_event_range.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(payload["source_fingerprint"]) == nil, string(payload["source_hash"]) == nil {
            error("compaction-source-fingerprint", "durable_compaction_checkpoint requires source_fingerprint or source_hash.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(payload["replacement_projection_id"]) == nil {
            error("compaction-replacement", "durable_compaction_checkpoint requires replacement_projection_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(payload["retained_count"]) == nil || int(payload["discarded_count"]) == nil {
            error("compaction-counts", "durable_compaction_checkpoint requires retained_count and discarded_count.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(payload["token_model"]) == nil, string(payload["size_model"]) == nil {
            error("compaction-token-model", "durable_compaction_checkpoint requires token_model or size_model.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateFork(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        if string(event.payload["source_package_id"]) == nil {
            error("fork-source-package", "conversation_fork requires source_package_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["source_event_id"]) == nil, int(event.payload["source_seq_boundary"]) == nil {
            error("fork-source-boundary", "conversation_fork requires source_event_id or source_seq_boundary.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["new_package_id"]) == nil {
            error("fork-new-package", "conversation_fork requires new_package_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateTurnSteered(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        if string(event.payload["turn_id"]) == nil {
            error("turn-steered-turn-id", "turn_steered requires turn_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["sequence"]) == nil {
            error("turn-steered-sequence", "turn_steered requires sequence.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validatePlanModeProposed(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validatePlanModeProposalIdentity(event, timelinePath: timelinePath, eventName: event.type)
        if string(event.payload["planning_turn_id"]) == nil {
            error("plan-mode-planning-turn-id", "\(event.type) requires planning_turn_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["content"]) == nil {
            error("plan-mode-content", "\(event.type) requires content.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validatePlanModeDecision(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validatePlanModeProposalIdentity(event, timelinePath: timelinePath, eventName: event.type)
        guard let decision = string(event.payload["decision"]) else {
            error("plan-mode-decision", "\(event.type) requires decision.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        let expected: String
        switch event.type {
        case "plan_mode_modified":
            expected = "modified"
        case "plan_mode_approved":
            expected = "approved"
        case "plan_mode_rejected":
            expected = "rejected"
        default:
            expected = decision
        }
        if decision != expected {
            error("plan-mode-decision-value", "\(event.type) decision must be \(expected).", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validatePlanModeHandoff(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validatePlanModeProposalIdentity(event, timelinePath: timelinePath, eventName: event.type)
        if string(event.payload["implementation_prompt"]) == nil {
            error("plan-mode-handoff-prompt", "plan_mode_handoff requires implementation_prompt.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["model_input_item_count"]) == nil {
            error("plan-mode-handoff-model-input-count", "plan_mode_handoff requires model_input_item_count.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateThreadGoalUpdated(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validateGoalIdentity(event, timelinePath: timelinePath, eventName: "thread_goal_updated")
        if string(event.payload["objective"]) == nil {
            error("thread-goal-objective", "thread_goal_updated requires objective.", path: timelinePath, line: event.line, eventID: event.id)
        }
        validateGoalStatus(event, timelinePath: timelinePath)
        if int(event.payload["tokens_used"]) == nil {
            error("thread-goal-tokens-used", "thread_goal_updated requires tokens_used.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["time_used_seconds"]) == nil {
            error("thread-goal-time-used", "thread_goal_updated requires time_used_seconds.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateThreadGoalCleared(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        if string(event.payload["thread_id"]) == nil {
            error("thread-goal-thread-id", "thread_goal_cleared requires thread_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if bool(event.payload["cleared"]) == nil {
            error("thread-goal-cleared", "thread_goal_cleared requires cleared.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateThreadGoalAccounted(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validateGoalIdentity(event, timelinePath: timelinePath, eventName: "thread_goal_accounted")
        if int(event.payload["token_delta"]) == nil {
            error("thread-goal-token-delta", "thread_goal_accounted requires token_delta.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["time_delta_seconds"]) == nil {
            error("thread-goal-time-delta", "thread_goal_accounted requires time_delta_seconds.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["tokens_used"]) == nil {
            error("thread-goal-accounted-tokens-used", "thread_goal_accounted requires tokens_used.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["time_used_seconds"]) == nil {
            error("thread-goal-accounted-time-used", "thread_goal_accounted requires time_used_seconds.", path: timelinePath, line: event.line, eventID: event.id)
        }
        validateGoalStatus(event, timelinePath: timelinePath)
    }

    mutating func validateRollback(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        if dictionary(event.payload["affected_event_range"]) == nil, stringArray(event.payload["affected_turn_ids"]) == nil {
            error("rollback-range", "timeline_rollback requires affected_event_range or affected_turn_ids.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["resulting_replay_boundary"]) == nil {
            warning("rollback-replay-boundary", "timeline_rollback should record resulting_replay_boundary.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateResumeEvent(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        if stringArray(event.payload["reasons"]) == nil, string(event.payload["reason"]) == nil {
            error("resume-reasons", "\(event.type) requires reason or reasons.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    mutating func validateLifecycle(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        guard let operation = string(event.payload["operation"]) else {
            error("lifecycle-operation", "conversation_lifecycle requires operation.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        if operation == "append",
           string(event.payload["previous_representation"]) == "compressed",
           bool(event.payload["materialized_before_append"]) != true {
            error("cold-history-materialize-before-append", "Appending to compressed cold history requires materialized_before_append=true.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    private mutating func validateGoalIdentity(
        _ event: MSPChatTimelineValidationEvent,
        timelinePath: String,
        eventName: String
    ) {
        if string(event.payload["thread_id"]) == nil {
            error("thread-goal-thread-id", "\(eventName) requires thread_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["goal_id"]) == nil {
            error("thread-goal-goal-id", "\(eventName) requires goal_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    private mutating func validatePlanModeProposalIdentity(
        _ event: MSPChatTimelineValidationEvent,
        timelinePath: String,
        eventName: String
    ) {
        if string(event.payload["thread_id"]) == nil {
            error("plan-mode-thread-id", "\(eventName) requires thread_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if string(event.payload["proposal_id"]) == nil {
            error("plan-mode-proposal-id", "\(eventName) requires proposal_id.", path: timelinePath, line: event.line, eventID: event.id)
        }
        if int(event.payload["proposal_version"]) == nil {
            error("plan-mode-proposal-version", "\(eventName) requires proposal_version.", path: timelinePath, line: event.line, eventID: event.id)
        }
    }

    private mutating func validateGoalStatus(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        guard let status = string(event.payload["status"]) else {
            error("thread-goal-status", "\(event.type) requires status.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        let knownStatuses = Set([
            "active",
            "paused",
            "blocked",
            "usageLimited",
            "budgetLimited",
            "complete"
        ])
        if !knownStatuses.contains(status) {
            error("thread-goal-status-value", "Unknown goal status \"\(status)\".", path: timelinePath, line: event.line, eventID: event.id)
        }
    }
}
