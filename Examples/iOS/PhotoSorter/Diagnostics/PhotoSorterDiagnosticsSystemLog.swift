import Foundation
import os

enum PhotoSorterDiagnosticsSystemLog {
    static let subsystem = "com.modelshellproxy.photosorter"

    private static let diagnosticsLogger = Logger(
        subsystem: subsystem,
        category: "Diagnostics"
    )
    private static let signposter = OSSignposter(
        subsystem: subsystem,
        category: "Performance"
    )

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    static func record(_ event: String, fields: [String: String]) {
        guard shouldMirror(event) else {
            return
        }
        let summary = fieldSummary(fields)
        if isErrorEvent(event) {
            diagnosticsLogger.error(
                "event=\(event, privacy: .public) fields=\(summary, privacy: .public)"
            )
        } else {
            diagnosticsLogger.notice(
                "event=\(event, privacy: .public) fields=\(summary, privacy: .public)"
            )
        }
    }

    static func beginInterval(
        _ name: StaticString,
        fields: [String: String] = [:]
    ) -> Interval {
        let state = signposter.beginInterval(
            name,
            "\(fieldSummary(fields), privacy: .public)"
        )
        return Interval(name: name, state: state)
    }

    static func endInterval(
        _ interval: Interval,
        fields: [String: String] = [:]
    ) {
        signposter.endInterval(
            interval.name,
            interval.state,
            "\(fieldSummary(fields), privacy: .public)"
        )
    }

    private static let mirroredEvents: Set<String> = [
        "agent_runtime_invalid_base_url",
        "agent_runtime_missing_configuration",
        "agent_runtime_send_error",
        "agent_runtime_send_finish",
        "agent_runtime_send_start",
        "agent_turn_finished",
        "agent_turn_not_started",
        "agent_turn_runtime_returned",
        "agent_turn_start",
        "app_start",
        "diagnostics_log_created_for_export",
        "diagnostics_log_exported",
        "model_stream_retrying",
        "photo_library_change_notification_fallback",
        "photo_library_change_notification_resolved",
        "photo_library_index_persistent_change_incremental_refresh",
        "photo_library_index_persistent_change_unavailable",
        "photo_library_index_persistent_change_verified",
        "photo_library_index_verified_cache_hit",
        "photo_library_ocr_preheat_finish",
        "photo_library_ocr_preheat_start",
        "photo_library_ocr_tiled_image",
        "runtime_error",
        "shell_command_finish",
        "shell_command_start",
        "shell_diagnostic_finished",
        "shell_diagnostic_start",
        "shell_direct_run_finish",
        "shell_direct_run_start",
        "startup_error",
        "startup_workspace_ready",
        "tool_completed_event",
        "tool_started",
        "user_submit"
    ]

    private static func shouldMirror(_ event: String) -> Bool {
        mirroredEvents.contains(event)
    }

    private static func isErrorEvent(_ event: String) -> Bool {
        event.contains("_error")
            || event.contains("_failed")
            || event.contains("_unavailable")
            || event.hasSuffix("_not_started")
    }

    private static func fieldSummary(_ fields: [String: String]) -> String {
        let mirrored = fields.keys.sorted().compactMap { key -> String? in
            guard shouldMirrorField(key) else {
                return nil
            }
            let value = fields[key] ?? ""
            return "\(key)=\(truncated(value, limit: valueLimit(for: key)))"
        }
        guard !mirrored.isEmpty else {
            return "-"
        }
        return truncated(mirrored.joined(separator: " "), limit: 1_500)
    }

    private static func shouldMirrorField(_ key: String) -> Bool {
        let normalized = key
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        if normalized.contains("preview") {
            return false
        }
        if normalized.hasSuffix("_current_path") || normalized == "current_path" {
            return false
        }
        if normalized.contains("api_key")
            || normalized.contains("apikey")
            || normalized.contains("authorization")
            || normalized.contains("access_token")
            || normalized.contains("refresh_token")
            || normalized.contains("id_token")
            || normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("password")
            || normalized.contains("bearer") {
            return false
        }
        return true
    }

    private static func valueLimit(for key: String) -> Int {
        key == "cmd" ? 500 : 160
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return "\(value.prefix(limit))...[truncated \(value.count - limit) chars]"
    }
}
