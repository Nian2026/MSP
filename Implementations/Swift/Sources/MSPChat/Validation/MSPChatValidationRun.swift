import Foundation

struct MSPChatTimelineValidationEvent {
    var id: String
    var type: String
    var seq: Int
    var createdAt: String
    var durability: String
    var payload: [String: Any]
    var envelope: [String: Any]
    var line: Int
}

struct MSPChatValidationRun {
    let packageURL: URL
    let fileManager = FileManager.default

    var diagnostics: [MSPChatDiagnostic] = []
    var manifest: [String: Any] = [:]
    var profiles: [String] = []
    var capabilities: [String] = []
    var timelineEvents: [MSPChatTimelineValidationEvent] = []
    var eventIDs = Set<String>()
    var maxTimelineSeq = 0
    var maxTimelineCommitSeq = 0
    var projectionRecordCount = 0
    var journalEntryCount = 0
    var indexRecordCount = 0

    let knownProfiles: Set<String> = [
        "core-timeline",
        "agent-timeline",
        "command-timeline",
        "projection-cache",
        "resumable-context",
        "runtime-journal"
    ]

    let knownCapabilities: Set<String> = [
        "read_core",
        "write_core",
        "read_command_timeline",
        "write_command_timeline",
        "execute_msp_commands",
        "generate_projection",
        "replay_journal",
        "lossless_edit",
        "preserve_unknown_events"
    ]

    let knownDurability: Set<String> = [
        "durable_replay",
        "live_stream",
        "projection_only",
        "runtime_journal"
    ]

    let knownEvents: Set<String> = [
        "message",
        "message_delta",
        "message_commit",
        "message_aborted",
        "message_superseded",
        "turn_started",
        "turn_completed",
        "turn_aborted",
        "turn_steered",
        "plan_mode_proposed",
        "plan_mode_modified",
        "plan_mode_approved",
        "plan_mode_rejected",
        "plan_mode_handoff",
        "thread_goal_updated",
        "thread_goal_cleared",
        "thread_goal_accounted",
        "status_changed",
        "command_call",
        "command_input",
        "command_output",
        "command_stage_started",
        "command_stage_output",
        "command_stage_completed",
        "command_complete",
        "command_error",
        "policy_request",
        "policy_decision",
        "tool_call",
        "tool_output",
        "artifact_ref",
        "turn_context_snapshot",
        "runtime_context_snapshot",
        "agent_model_context_item",
        "agent_model_context_snapshot",
        "application_state_snapshot",
        "permission_snapshot",
        "environment_snapshot",
        "model_context_projection",
        "projection_created",
        "projection_invalidated",
        "durable_compaction_checkpoint",
        "live_compaction_progress",
        "context_window_lineage",
        "state_snapshot",
        "state_patch",
        "conversation_fork",
        "timeline_rollback",
        "resume_capability_assessment",
        "resume_degraded",
        "conversation_lifecycle",
        "active_turn_overlay",
        "live_attachment_snapshot",
        "error"
    ]

    let knownProjectionKinds: Set<String> = [
        "chat-read.machine",
        "chat-read.markdown",
        "ui-timeline",
        "model-context",
        "audit"
    ]

    mutating func validate() {
        validatePackageShape()
        validateManifest()
        validateTimeline()
        validateProjectionFiles()
        validateJournal()
        validateDeclaredPackageLayers()
    }

    func report() -> MSPChatValidationReport {
        MSPChatValidationReport(
            packagePath: packageURL.path,
            validatorVersion: MSPChatValidator.version,
            checkedProfiles: profiles.sorted(),
            checkedCapabilities: capabilities.sorted(),
            timelineEventCount: timelineEvents.count,
            projectionRecordCount: projectionRecordCount,
            journalEntryCount: journalEntryCount,
            indexRecordCount: indexRecordCount,
            diagnostics: diagnostics
        )
    }

    mutating func validatePackageShape() {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error("package-not-directory", "Package path must be an existing .chat directory.", path: packageURL.path)
            return
        }

        if !packageURL.lastPathComponent.hasSuffix(".chat") {
            warning("package-extension", "Directory package should use the .chat extension.", path: packageURL.path)
        }
    }

    mutating func validateDeclaredPackageLayers() {
        if profiles.contains("projection-cache") {
            var isDirectory: ObjCBool = false
            let projectionsURL = packageURL.appendingPathComponent("projections")
            if !fileManager.fileExists(atPath: projectionsURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                error("declared-projection-cache-missing", "projection-cache profile requires projections/ data or a manifest declaration explaining absence.", path: relativePath(projectionsURL))
            }
        }

        if profiles.contains("runtime-journal") {
            let journalURL = packageURL.appendingPathComponent("journal.ndjson")
            if !fileManager.fileExists(atPath: journalURL.path) {
                error("declared-runtime-journal-missing", "runtime-journal profile requires journal.ndjson.", path: relativePath(journalURL))
            }
        }

        if profiles.contains("projection-cache") {
            let indexesURL = packageURL.appendingPathComponent("indexes")
            if fileManager.fileExists(atPath: indexesURL.path) {
                validateIndexes()
            }
        } else {
            validateIndexes()
        }

        let hasCommandEvents = timelineEvents.contains {
            $0.type.hasPrefix("command_") || $0.type == "policy_request" || $0.type == "policy_decision"
        }
        if hasCommandEvents, !profiles.contains("command-timeline") {
            error("command-events-without-profile", "Command events require the command-timeline profile.", path: relativePath(packageURL))
        }
    }
}
