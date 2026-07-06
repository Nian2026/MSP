import Foundation
import CryptoKit
import MSPAgentBridge
import MSPCore
import SwiftUI

@MainActor
final class MSPPlaygroundViewModel: ObservableObject {
    @Published var transcript: [MSPAgentTimelineItem] = []
    @Published var composerText: String = ""
    @Published var fileTreeState: WorkspaceFileTreeState = .loading
    @Published var isRunningAgent = false
    @Published var modelConfiguration: MSPModelConfiguration
    @Published var modelConfigurationSaveError: String?
    @Published var codexOAuthConfiguration: MSPCodexOAuthConfiguration
    @Published var codexOAuthQuota: MSPCodexOAuthQuotaResult?
    @Published var isStartingCodexOAuthLogin = false
    @Published var isRefreshingCodexOAuthQuota = false
    @Published var lastRequestBody: MSPAgentRequestBody?
    @Published var expandsTranscriptToolDetailsForTesting = MSPPlaygroundViewModel.transcriptToolDetailExpansionEnabled()
    @Published var workspaceQuickLookURL: URL?

    private var runtime: MSPPlaygroundShellRuntime?
    private var agentRuntime: MSPPlaygroundAgentRuntime?
    private var hasStarted = false
    private var streamingAssistantProgressItemID: UUID?
    private var streamingFinalItemID: UUID?
    private var pendingFinalAnswerProvenanceFields: [String: String]?
    private var pendingToolPreparationItemIDs: [UUID] = []
    private var activeToolStartedAtMillisecondsByCallID: [String: Int] = [:]
    private var applyPatchOperationIDByCallID: [String: UUID] = [:]
    private var applyPatchOperationsByID: [UUID: ApplyPatchWriteOperation] = [:]
    private var currentTurnStartedAtMilliseconds: Int?
    private var scenePhaseHistory: [String] = []
    private var codexOAuthQuotaRefreshToken: UUID?
    private let codexOAuthLoginService = MSPCodexOAuthWebLoginService()
    private let codexOAuthQuotaService = MSPCodexOAuthQuotaService()
    private let e2eEventLog = MSPPlaygroundE2EEventLog.configured()
    private let loadModelConfiguration: () -> MSPModelConfiguration
    private let saveModelConfigurationHandler: (MSPModelConfiguration) throws -> Void

    private struct ApplyPatchFileSnapshot: Equatable {
        var path: String
        var existedBefore: Bool
        var existsAfter: Bool
        var beforeText: String?
        var afterText: String?
    }

    private struct ApplyPatchWriteOperation: Equatable {
        var id: UUID
        var callID: String
        var path: String
        var documentName: String
        var turnDiff: String
        var linesAdded: Int
        var linesRemoved: Int
        var snapshots: [ApplyPatchFileSnapshot]
        var createdAtMilliseconds: Int
        var undoneAtMilliseconds: Int?

        var canUndo: Bool {
            undoneAtMilliseconds == nil
        }

        var canRedo: Bool {
            undoneAtMilliseconds != nil
        }

        var referenceObject: [String: ExampleChatJSONValue] {
            [
                "id": .string(id.uuidString),
                "tool_name": .string("apply_patch"),
                "action": .string("apply_patch"),
                "p": .string(path),
                "document_name": .string(documentName),
                "can_undo": .bool(canUndo),
                "can_redo": .bool(canRedo)
            ]
        }
    }

    init(
        loadModelConfiguration: @escaping () -> MSPModelConfiguration = {
            MSPModelConfigurationStore.load()
        },
        saveModelConfiguration: @escaping (MSPModelConfiguration) throws -> Void = {
            try MSPModelConfigurationStore.save($0)
        },
        loadCodexOAuthConfiguration: @escaping () -> MSPCodexOAuthConfiguration = {
            MSPCodexOAuthConfigurationStore.load()
        }
    ) {
        self.loadModelConfiguration = loadModelConfiguration
        self.saveModelConfigurationHandler = saveModelConfiguration
        self.modelConfiguration = loadModelConfiguration()
        self.codexOAuthConfiguration = loadCodexOAuthConfiguration()
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        do {
            let arguments = ProcessInfo.processInfo.arguments
            let environment = ProcessInfo.processInfo.environment
            let workspaceProfile = MSPPlaygroundWorkspaceProfile.configured(
                arguments: arguments,
                environment: environment
            )
            let workspaceURL = try MSPPlaygroundWorkspaceBootstrap.prepareWorkspace(
                profile: workspaceProfile
            )
            let runtime = try MSPPlaygroundShellRuntime(
                workspaceURL: workspaceURL,
                workspaceProfile: workspaceProfile,
                arguments: arguments,
                environment: environment
            )
            self.runtime = runtime
            self.agentRuntime = MSPPlaygroundAgentRuntime(shellRuntime: runtime)
            e2eEventLog?.record("startup", fields: [
                "workspace_path": workspaceURL.path,
                "workspace_profile": workspaceProfile.rawValue
            ])
            if Self.launchShellDiagnosticRequested() {
                await runShellDiagnostic(runtime)
            }
            if let oracleURL = Self.launchShellOracleURLIfRequested() {
                await runShellOracle(fixtureURL: oracleURL)
            }
            if let fixture = Self.launchTranscriptFixtureIfRequested() {
                transcript = fixture.items
                isRunningAgent = fixture.isGenerating
                e2eEventLog?.record("fixture_loaded", fields: [
                    "variant": fixture.variant.rawValue,
                    "is_generating": "\(fixture.isGenerating)"
                ])
                await refreshWorkspace()
                return
            }

            transcript = []
            await refreshWorkspace()
            if let prompts = Self.launchAutoSubmitPromptSequenceIfRequested() {
                e2eEventLog?.record("auto_submit_sequence_loaded", fields: [
                    "prompt_count": "\(prompts.count)",
                    "prompt_hash_algorithm": "sha256-utf8",
                    "prompt_sha256s": prompts.map(Self.sha256Hex).joined(separator: ",")
                ])
                for (index, prompt) in prompts.enumerated() {
                    await runAutoSubmittedPrompt(
                        prompt,
                        index: index + 1,
                        count: prompts.count
                    )
                }
            } else if let prompt = Self.launchAutoSubmitPromptIfRequested() {
                await runAutoSubmittedPrompt(prompt, index: 1, count: 1)
            }
            refreshCodexOAuthQuota(isAutomatic: true)
        } catch {
            fileTreeState = .failed(error.localizedDescription)
            transcript = [
                MSPAgentTimelineItem(
                    kind: .error,
                    title: "Startup",
                    body: error.localizedDescription
                )
            ]
            e2eEventLog?.record("startup_error", fields: [
                "message": error.localizedDescription
            ])
        }
    }

    private func runAutoSubmittedPrompt(
        _ prompt: String,
        index: Int,
        count: Int
    ) async {
        let turnStartedAtMilliseconds = Self.currentMillisecondsSince1970()
        transcript.append(
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: prompt,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
        )
        e2eEventLog?.record("auto_submit", fields: [
            "prompt_length": "\(prompt.count)",
            "prompt_index": "\(index)",
            "prompt_count": "\(count)",
            "prompt_hash_algorithm": "sha256-utf8",
            "prompt_sha256": Self.sha256Hex(prompt)
        ])
        await runAgentTurn(prompt, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
    }

    func submitMessage() {
        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isRunningAgent else {
            return
        }

        composerText = ""
        let turnStartedAtMilliseconds = Self.currentMillisecondsSince1970()
        transcript.append(
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: message,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
        )
        e2eEventLog?.record("user_submit", fields: [
            "prompt_length": "\(message.count)"
        ])

        Task {
            await runAgentTurn(message, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
        }
    }

    func refreshWorkspace() {
        Task {
            await refreshWorkspace()
        }
    }

    func openWorkspaceFile(_ node: WorkspaceFileNode) {
        guard !node.isDirectory else {
            return
        }
        e2eEventLog?.record("workspace_file_open_requested", fields: [
            "path": node.path,
            "name": node.name
        ])

        Task {
            guard let runtime else {
                e2eEventLog?.record("workspace_file_preview_failed", fields: [
                    "path": node.path,
                    "reason": "runtime_unavailable"
                ])
                return
            }

            do {
                let previewURL = try runtime.quickLookURL(for: node.path)
                workspaceQuickLookURL = previewURL
                e2eEventLog?.record("workspace_file_quicklook_opened", fields: [
                    "path": node.path,
                    "file_url": previewURL.path
                ])
            } catch {
                e2eEventLog?.record("workspace_file_preview_failed", fields: [
                    "path": node.path,
                    "reason": error.localizedDescription
                ])
            }
        }
    }

    func recordScenePhase(_ phase: ScenePhase) {
        let name = Self.scenePhaseName(phase)
        scenePhaseHistory.append(name)
        e2eEventLog?.record("scene_phase", fields: [
            "phase": name,
            "index": "\(scenePhaseHistory.count - 1)"
        ])
    }

    private func runShellDiagnostic(_ runtime: MSPPlaygroundShellRuntime) async {
        e2eEventLog?.record("shell_diagnostic_started")
        let commands = [
            "printf 'ios-shell-ok\\n'",
            "python3 -c 'print(42)'"
        ]
        for command in commands {
            let result = await runtime.run(command)
            e2eEventLog?.record("shell_diagnostic_command", fields: [
                "command": command,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exit_code": "\(result.exitCode)"
            ])
        }
        await runShellPTYDiagnostic(runtime)
        if Self.launchShellLifecycleDiagnosticRequested() {
            await runShellLifecycleDiagnostic(runtime)
        }
        e2eEventLog?.record("shell_diagnostic_finished")
    }

    private func runShellPTYDiagnostic(_ runtime: MSPPlaygroundShellRuntime) async {
        let command = "printf 'ios-pty-ok\\n'"
        let bridge = runtime.execCommandBridge()
        let initialRead = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 250
        ))
        let finalRead: MSPExecCommandSessionRead
        var didPoll = false
        if let sessionID = initialRead.runningSessionID {
            didPoll = true
            let pollRead = await bridge.writeStdin(MSPWriteStdinCall(
                sessionID: sessionID,
                chars: "",
                yieldTimeMilliseconds: 5_000
            ))
            finalRead = MSPExecCommandSessionRead(
                result: MSPCommandResult(
                    stdoutData: initialRead.result.stdoutData + pollRead.result.stdoutData,
                    stderrData: initialRead.result.stderrData + pollRead.result.stderrData,
                    exitCode: pollRead.result.exitCode
                ),
                wallTimeSeconds: initialRead.wallTimeSeconds + pollRead.wallTimeSeconds,
                runningSessionID: pollRead.runningSessionID,
                exitCode: pollRead.exitCode,
                signal: pollRead.signal
            )
        } else {
            finalRead = initialRead
        }
        e2eEventLog?.record("shell_diagnostic_exec_session", fields: [
            "name": "pty_smoke",
            "command": command,
            "tty": "true",
            "did_poll": "\(didPoll)",
            "initial_running_session_id": initialRead.runningSessionID.map(String.init) ?? "",
            "final_running_session_id": finalRead.runningSessionID.map(String.init) ?? "",
            "stdout": finalRead.result.stdout,
            "stderr": finalRead.result.stderr,
            "exit_code": "\(finalRead.exitCode ?? finalRead.result.exitCode)",
            "signal": finalRead.signal.map(String.init) ?? "",
            "wall_time_seconds": String(format: "%.4f", finalRead.wallTimeSeconds)
        ])
    }

    private func runShellLifecycleDiagnostic(_ runtime: MSPPlaygroundShellRuntime) async {
        let command = "printf 'lifecycle-session-start\\n'; sleep 2; printf 'lifecycle-session-end\\n'"
        let bridge = runtime.execCommandBridge()
        let initialRead = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 250
        ))
        guard let sessionID = initialRead.runningSessionID else {
            e2eEventLog?.record("shell_diagnostic_exec_session", fields: [
                "name": "app_lifecycle_session",
                "command": command,
                "tty": "true",
                "initial_running_session_id": "",
                "final_running_session_id": "",
                "stdout": initialRead.result.stdout,
                "stderr": initialRead.result.stderr,
                "exit_code": "\(initialRead.exitCode ?? initialRead.result.exitCode)",
                "signal": initialRead.signal.map(String.init) ?? "",
                "background_observed": "false",
                "foreground_observed": "false",
                "wall_time_seconds": String(format: "%.4f", initialRead.wallTimeSeconds)
            ])
            return
        }

        let waitStartIndex = scenePhaseHistory.count - 1
        e2eEventLog?.record("shell_diagnostic_lifecycle_waiting_for_background", fields: [
            "session_id": "\(sessionID)",
            "scene_phase_start_index": "\(waitStartIndex)"
        ])
        let backgroundIndex = await waitForScenePhase(
            "background",
            after: waitStartIndex,
            timeoutSeconds: 10
        )
        let foreground: (index: Int, phase: String)?
        if let backgroundIndex {
            foreground = await waitForScenePhase(
                matching: ["active", "inactive"],
                after: backgroundIndex,
                timeoutSeconds: 10
            )
        } else {
            foreground = nil
        }

        let pollRead = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "",
            yieldTimeMilliseconds: 5_000
        ))
        let combinedRead = MSPExecCommandSessionRead(
            result: MSPCommandResult(
                stdoutData: initialRead.result.stdoutData + pollRead.result.stdoutData,
                stderrData: initialRead.result.stderrData + pollRead.result.stderrData,
                exitCode: pollRead.result.exitCode
            ),
            wallTimeSeconds: initialRead.wallTimeSeconds + pollRead.wallTimeSeconds,
            runningSessionID: pollRead.runningSessionID,
            exitCode: pollRead.exitCode,
            signal: pollRead.signal
        )
        e2eEventLog?.record("shell_diagnostic_exec_session", fields: [
            "name": "app_lifecycle_session",
            "command": command,
            "tty": "true",
            "initial_running_session_id": "\(sessionID)",
            "final_running_session_id": combinedRead.runningSessionID.map(String.init) ?? "",
            "stdout": combinedRead.result.stdout,
            "stderr": combinedRead.result.stderr,
            "exit_code": "\(combinedRead.exitCode ?? combinedRead.result.exitCode)",
            "signal": combinedRead.signal.map(String.init) ?? "",
            "background_observed": "\(backgroundIndex != nil)",
            "foreground_observed": "\(foreground != nil)",
            "background_scene_phase_index": backgroundIndex.map(String.init) ?? "",
            "foreground_scene_phase_index": foreground.map { String($0.index) } ?? "",
            "foreground_scene_phase": foreground?.phase ?? "",
            "wall_time_seconds": String(format: "%.4f", combinedRead.wallTimeSeconds)
        ])
    }

    private func waitForScenePhase(
        _ expectedPhase: String,
        after index: Int,
        timeoutSeconds: TimeInterval
    ) async -> Int? {
        let match = await waitForScenePhase(
            matching: [expectedPhase],
            after: index,
            timeoutSeconds: timeoutSeconds
        )
        return match?.index
    }

    private func waitForScenePhase(
        matching expectedPhases: [String],
        after index: Int,
        timeoutSeconds: TimeInterval
    ) async -> (index: Int, phase: String)? {
        let expected = Set(expectedPhases)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let match = scenePhaseHistory.enumerated().first(where: { pair in
                pair.offset > index && expected.contains(pair.element)
            }) {
                return (match.offset, match.element)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func runShellOracle(fixtureURL: URL) async {
        let casesDirectoryURL = fixtureURL
            .deletingLastPathComponent()
            .appendingPathComponent("Cases", isDirectory: true)
        let runner = MSPPlaygroundShellOracleRunner(
            fixtureURL: fixtureURL,
            casesDirectoryURL: casesDirectoryURL,
            eventLog: e2eEventLog
        )
        _ = await runner.runPythonOracle()
    }

    @discardableResult
    func reloadModelConfiguration() -> MSPModelConfiguration {
        let loadedConfiguration = loadModelConfiguration()
        modelConfiguration = loadedConfiguration
        return loadedConfiguration
    }

    @discardableResult
    func saveModelConfiguration() -> Bool {
        let normalized = modelConfiguration.normalized()
        do {
            try saveModelConfigurationHandler(normalized)
            modelConfiguration = loadModelConfiguration()
            modelConfigurationSaveError = nil
            return true
        } catch {
            modelConfiguration = normalized
            modelConfigurationSaveError = error.localizedDescription
            return false
        }
    }

    func saveCodexOAuthConfiguration() {
        codexOAuthConfiguration = codexOAuthConfiguration.applyingTokenMetadata()
        MSPCodexOAuthConfigurationStore.save(codexOAuthConfiguration)
        if !codexOAuthConfiguration.hasStoredCredential {
            codexOAuthQuota = nil
        }
    }

    func recordTranscriptRenderedProbe(_ probe: ExampleChatTranscriptVisibleTextProbe) {
        guard Self.transcriptVisibleTextProbeEnabled() else {
            return
        }
        let normalizedText = probe.normalizedVisibleText
        let fullTextContainsShellJSONKeys = Self.containsStructuredShellJSONLeak(in: normalizedText)
        let containsToolStdoutSentinel = normalizedText.contains("MSP_HIDDEN_TOOL_STDOUT_SENTINEL")
        let containsToolStderrSentinel = normalizedText.contains("MSP_HIDDEN_TOOL_STDERR_SENTINEL")
        let mainFlowText = probe.mainFlowNormalizedText
        let mainFlowContainsToolStdoutSentinel = mainFlowText.contains("MSP_HIDDEN_TOOL_STDOUT_SENTINEL")
        let mainFlowContainsToolStderrSentinel = mainFlowText.contains("MSP_HIDDEN_TOOL_STDERR_SENTINEL")
        let mainFlowContainsCommandNotFound = mainFlowText.contains("command not found")
        let shellOutputText = probe.shellExecutionOutputNormalizedText
        let shellOutputContainsToolStdoutSentinel = shellOutputText.contains("MSP_HIDDEN_TOOL_STDOUT_SENTINEL")
        let shellOutputContainsToolStderrSentinel = shellOutputText.contains("MSP_HIDDEN_TOOL_STDERR_SENTINEL")
        let shellOutputContainsCommandNotFound = shellOutputText.contains("command not found")
        let shellOutputContainsShellJSONKeys = Self.containsStructuredShellJSONLeak(in: shellOutputText)
        let normalizedTextExcludingUserMessages = normalizedProbeTextExcludingUserMessages(normalizedText)
        let containsExecCommandOutsideUserMessages = normalizedTextExcludingUserMessages.contains("exec_command")
        let internalToolTitleText = Self.normalizedProbeText([
            probe.chatSupportLineTitles.joined(separator: " "),
            probe.chatTerminalSupportLineTitles.joined(separator: " "),
            probe.chatToolActivityItemTitles.joined(separator: " "),
            probe.chatApplyPatchActivityTitles.joined(separator: " "),
            probe.chatProcessingTitles.joined(separator: " "),
            probe.chatToolActivityTitles.joined(separator: " ")
        ].joined(separator: " "))
        let containsInternalShellToolName = internalToolTitleText.contains("workspace.shell")
            || internalToolTitleText.contains("readex.shell")
            || internalToolTitleText.contains("exec_command")
            || normalizedTextExcludingUserMessages.contains("workspace.shell")
            || normalizedTextExcludingUserMessages.contains("readex.shell")
        let snippetLimit = 700
        let snippet = normalizedText.count > snippetLimit
            ? String(normalizedText.prefix(snippetLimit))
            : normalizedText
        e2eEventLog?.record("transcript_visible_text_probe", fields: [
            "text_length": "\(probe.visibleText.count)",
            "normalized_text_length": "\(normalizedText.count)",
            "normalized_text_excluding_user_messages_length": "\(normalizedTextExcludingUserMessages.count)",
            "contains_exec_command": "\(normalizedText.contains("exec_command"))",
            "contains_exec_command_outside_user_messages": "\(containsExecCommandOutsideUserMessages)",
            "contains_command_not_found": "\(normalizedText.contains("command not found"))",
            "contains_shell_json_keys": "\(shellOutputContainsShellJSONKeys)",
            "full_text_contains_shell_json_keys": "\(fullTextContainsShellJSONKeys)",
            "contains_tool_stdout_sentinel": "\(containsToolStdoutSentinel)",
            "contains_tool_stderr_sentinel": "\(containsToolStderrSentinel)",
            "main_flow_contains_tool_stdout_sentinel": "\(mainFlowContainsToolStdoutSentinel)",
            "main_flow_contains_tool_stderr_sentinel": "\(mainFlowContainsToolStderrSentinel)",
            "main_flow_contains_command_not_found": "\(mainFlowContainsCommandNotFound)",
            "shell_output_contains_tool_stdout_sentinel": "\(shellOutputContainsToolStdoutSentinel)",
            "shell_output_contains_tool_stderr_sentinel": "\(shellOutputContainsToolStderrSentinel)",
            "shell_output_contains_command_not_found": "\(shellOutputContainsCommandNotFound)",
            "contains_internal_shell_tool_name": "\(containsInternalShellToolName)",
            "chat_transcript_theme": probe.chatTranscriptTheme,
            "message_roles": probe.messageLayouts
                .map(\.role)
                .joined(separator: ","),
            "message_layouts": Self.messageLayoutProbeText(probe.messageLayouts),
            "visible_message_role_texts": probe.visibleMessageRoleTexts.joined(separator: " | "),
            "chat_support_line_titles": probe.chatSupportLineTitles.joined(separator: " | "),
            "chat_terminal_support_line_titles": probe.chatTerminalSupportLineTitles.joined(separator: " | "),
            "chat_tool_activity_item_titles": probe.chatToolActivityItemTitles.joined(separator: " | "),
            "chat_apply_patch_activity_titles": probe.chatApplyPatchActivityTitles.joined(separator: " | "),
            "chat_processing_titles": probe.chatProcessingTitles.joined(separator: " | "),
            "internal_tool_title_text": internalToolTitleText,
            "chat_processing_class_names": probe.chatProcessingClassNames.joined(separator: " | "),
            "chat_processing_duration_texts": probe.chatProcessingDurationTexts.joined(separator: " | "),
            "chat_processing_duration_seconds": probe.chatProcessingDurationSeconds
                .map(String.init)
                .joined(separator: ","),
            "chat_tool_activity_titles": probe.chatToolActivityTitles.joined(separator: " | "),
            "live_chat_processing_block_count": "\(probe.liveExampleChatProcessingBlockCount)",
            "terminal_command_icon_count": "\(probe.terminalCommandIconCount)",
            "tool_activity_details_count": "\(probe.toolActivityDetailsCount)",
            "tool_activity_disclosure_count": "\(probe.toolActivityDisclosureCount)",
            "shell_execution_disclosure_count": "\(probe.shellExecutionDisclosureCount)",
            "shell_execution_output_block_count": "\(probe.shellExecutionOutputBlockCount)",
            "katex_element_count": "\(probe.katexElementCount)",
            "highlighted_code_element_count": "\(probe.highlightedCodeElementCount)",
            "markdown_code_block_count": "\(probe.markdownCodeBlockCount)",
            "chat_apply_patch_diff_card_count": "\(probe.chatApplyPatchDiffCardCount)",
            "captured_at_milliseconds": probe.capturedAtMilliseconds.map(String.init) ?? "",
            "snippet": snippet
        ])
    }

    private func normalizedProbeTextExcludingUserMessages(_ text: String) -> String {
        var remainingText = text
        for item in transcript where item.kind == .user {
            let userText = Self.normalizedProbeText(item.body)
            guard !userText.isEmpty else {
                continue
            }
            remainingText = remainingText.replacingOccurrences(of: userText, with: " ")
        }
        return Self.normalizedProbeText(remainingText)
    }

    nonisolated static func containsStructuredShellJSONLeak(in text: String) -> Bool {
        let normalizedText = normalizedProbeText(text)
        guard normalizedText.contains("\"stdout\""),
              normalizedText.contains("\"stderr\"") else {
            return false
        }
        return normalizedText.contains("\"exit_code\"")
            || normalizedText.contains("\"exitCode\"")
            || normalizedText.contains("\"internal_exit_code\"")
    }

    private nonisolated static func normalizedProbeText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func messageLayoutProbeText(
        _ layouts: [ExampleChatTranscriptVisibleTextProbe.MessageLayout]
    ) -> String {
        layouts
            .map { layout in
                [
                    layout.role,
                    layout.dataRole,
                    Self.roundedProbeNumber(layout.left),
                    Self.roundedProbeNumber(layout.right),
                    Self.roundedProbeNumber(layout.width),
                    Self.roundedProbeNumber(layout.centerX)
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    private static func roundedProbeNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    func startCodexOAuthLogin() {
        guard !isStartingCodexOAuthLogin else {
            return
        }
        codexOAuthQuotaRefreshToken = nil
        isRefreshingCodexOAuthQuota = false
        isStartingCodexOAuthLogin = true
        codexOAuthQuota = nil
        codexOAuthConfiguration.lastLoginStatus = .signingIn
        codexOAuthConfiguration.lastStatusMessage = "正在打开 Codex OAuth 登录页面…"
        codexOAuthConfiguration.lastCheckedAt = .now

        Task {
            let result = await codexOAuthLoginService.startLogin(preserving: codexOAuthConfiguration)
            applyCodexOAuthLoginResult(result)
            isStartingCodexOAuthLogin = false
            if result.configuration.lastLoginStatus == .signedIn {
                refreshCodexOAuthQuota(isAutomatic: true)
            }
        }
    }

    func clearCodexOAuthSession() {
        codexOAuthLoginService.cancelLogin()
        codexOAuthQuotaRefreshToken = nil
        isStartingCodexOAuthLogin = false
        isRefreshingCodexOAuthQuota = false
        codexOAuthConfiguration = .empty
        codexOAuthQuota = nil
        MSPCodexOAuthConfigurationStore.clear()
    }

    func refreshCodexOAuthQuota(isAutomatic: Bool = false) {
        saveCodexOAuthConfiguration()
        let configuration = codexOAuthConfiguration.normalized()
        guard configuration.hasStoredCredential else {
            if !isAutomatic {
                codexOAuthQuota = MSPCodexOAuthQuotaResult(
                    status: .signedOut,
                    message: "请先登录 Codex，再刷新额度。",
                    email: nil,
                    planType: nil,
                    windows: [],
                    checkedAt: .now
                )
            }
            return
        }

        codexOAuthQuotaRefreshToken = UUID()
        let refreshToken = codexOAuthQuotaRefreshToken
        isRefreshingCodexOAuthQuota = true

        Task {
            let freshConfiguration = await codexOAuthLoginService.refreshAccessToken(using: configuration)
            if freshConfiguration != codexOAuthConfiguration.normalized() {
                codexOAuthConfiguration = freshConfiguration
                MSPCodexOAuthConfigurationStore.save(freshConfiguration)
            }
            guard freshConfiguration.lastLoginStatus != .failed else {
                guard codexOAuthQuotaRefreshToken == refreshToken else { return }
                codexOAuthQuota = MSPCodexOAuthQuotaResult(
                    status: .failed,
                    message: freshConfiguration.lastStatusMessage,
                    email: Self.nilIfEmpty(freshConfiguration.email),
                    planType: Self.nilIfEmpty(freshConfiguration.planType),
                    windows: [],
                    checkedAt: .now
                )
                isRefreshingCodexOAuthQuota = false
                codexOAuthQuotaRefreshToken = nil
                return
            }

            let result = await codexOAuthQuotaService.refreshQuota(using: freshConfiguration)
            guard codexOAuthQuotaRefreshToken == refreshToken else { return }
            applyCodexOAuthQuotaResult(result)
            isRefreshingCodexOAuthQuota = false
            codexOAuthQuotaRefreshToken = nil
        }
    }

    private func runAgentTurn(
        _ message: String,
        turnStartedAtMilliseconds: Int
    ) async {
        guard let agentRuntime else {
            return
        }

        isRunningAgent = true
        streamingAssistantProgressItemID = nil
        streamingFinalItemID = nil
        pendingFinalAnswerProvenanceFields = nil
        pendingToolPreparationItemIDs.removeAll(keepingCapacity: true)
        activeToolStartedAtMillisecondsByCallID.removeAll(keepingCapacity: true)
        currentTurnStartedAtMilliseconds = turnStartedAtMilliseconds
        await refreshCodexOAuthCredentialForAgentTurnIfNeeded()
        await agentRuntime.runTurn(
            userMessage: message,
            configuration: modelConfiguration,
            codexOAuthConfiguration: codexOAuthConfiguration,
            onRequestBuilt: { [weak self] requestBody in
                self?.handleModelRequestBuilt(requestBody)
            },
            onEvent: { [weak self] event in
                self?.handle(event)
            },
            onRuntimeError: { [weak self] text in
                self?.handleRuntimeError(text)
            }
        )
        finishCurrentTurn()
        isRunningAgent = false
        streamingAssistantProgressItemID = nil
        streamingFinalItemID = nil
        pendingFinalAnswerProvenanceFields = nil
        pendingToolPreparationItemIDs.removeAll(keepingCapacity: true)
        activeToolStartedAtMillisecondsByCallID.removeAll(keepingCapacity: true)
        currentTurnStartedAtMilliseconds = nil
        await refreshWorkspace()
    }

    private func refreshCodexOAuthCredentialForAgentTurnIfNeeded() async {
        let normalized = codexOAuthConfiguration.normalized()
        guard normalized.hasRefreshToken else {
            return
        }

        let metadata = MSPCodexOAuthJWTMetadata(
            idToken: Self.nilIfEmpty(normalized.idToken),
            accessToken: Self.nilIfEmpty(normalized.accessToken)
        )
        if let expiresAt = metadata.accessTokenExpiresAt,
           expiresAt > Date().addingTimeInterval(120) {
            return
        }

        let refreshed = await codexOAuthLoginService.refreshAccessToken(using: normalized)
        guard refreshed != normalized else {
            return
        }
        codexOAuthConfiguration = refreshed
        MSPCodexOAuthConfigurationStore.save(refreshed)
    }

    private func handleModelRequestBuilt(_ requestBody: MSPAgentRequestBody) {
        lastRequestBody = requestBody
        let userInputTexts = Self.requestUserInputTexts(requestBody)
        e2eEventLog?.record("model_request_built", fields: [
            "request_layer": "app_turn_submission",
            "model": requestBody.model,
            "input_count": "\(requestBody.input.count)",
            "request_user_input_count": "\(userInputTexts.count)",
            "request_user_input_hash_algorithm": "sha256-utf8",
            "request_user_input_sha256s": userInputTexts.map(Self.sha256Hex).joined(separator: ","),
            "request_last_user_input_sha256": userInputTexts.last.map(Self.sha256Hex) ?? "",
            "tool_count": "\(requestBody.tools.count)",
            "stream": "\(requestBody.stream)"
        ])
    }

    private static func requestUserInputTexts(_ requestBody: MSPAgentRequestBody) -> [String] {
        requestBody.input
            .filter { $0.role == "user" }
            .map { message in
                message.content
                    .filter { $0.type == "input_text" }
                    .map(\.text)
                    .joined(separator: "\n")
            }
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func handleRuntimeError(_ text: String) {
        e2eEventLog?.record("runtime_error", fields: [
            "message": text
        ])
        appendTimeline(kind: .error, title: "Error", body: text)
    }

    private func handle(_ event: MSPAgentEvent) {
        switch event {
        case .turnStarted(let event):
            e2eEventLog?.record("turn_started", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID
            ])

        case .turnAborted(let event):
            e2eEventLog?.record("turn_aborted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "reason": event.reason.rawValue
            ])

        case .turnSteerAccepted(let event):
            e2eEventLog?.record("turn_steer_accepted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": "\(event.sequenceNumber)",
                "content_length": "\(event.contentText.count)",
                "client_user_message_id": event.clientUserMessageID ?? ""
            ])

        case .turnSteerApplied(let event):
            e2eEventLog?.record("turn_steer_applied", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": "\(event.sequenceNumber)",
                "content_length": "\(event.contentText.count)",
                "client_user_message_id": event.clientUserMessageID ?? "",
                "boundary": event.boundary.rawValue,
                "model_input_item_count": "\(event.modelInputItemCount)"
            ])

        case .threadGoalUpdated(let event):
            e2eEventLog?.record("thread_goal_updated", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "reason": event.reason.rawValue,
                "goal_id": event.goal.goalID,
                "status": event.goal.status.rawValue
            ])

        case .threadGoalCleared(let event):
            e2eEventLog?.record("thread_goal_cleared", fields: [
                "thread_id": event.threadID,
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "goal_id": event.clearedGoal?.goalID ?? "",
                "status": event.clearedGoal?.status.rawValue ?? ""
            ])

        case .threadGoalAccounted(let event):
            e2eEventLog?.record("thread_goal_accounted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "event_id": event.eventID,
                "goal_id": event.goalID,
                "token_delta": "\(event.tokenDelta)",
                "time_delta_seconds": "\(event.timeDeltaSeconds)",
                "tokens_used": "\(event.tokensUsed)",
                "time_used_seconds": "\(event.timeUsedSeconds)",
                "status": event.status.rawValue
            ])

        case .planProgressUpdated(let event):
            e2eEventLog?.record("plan_progress_updated", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "event_id": event.eventID,
                "plan_count": "\(event.plan.count)",
                "explanation": event.explanation ?? ""
            ])

        case .planModeProposalDelta(let event):
            e2eEventLog?.record("plan_mode_proposal_delta", fields: [
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "item_id": event.itemID,
                "delta_length": "\(event.delta.count)"
            ])

        case .planModeProposed(let event):
            e2eEventLog?.record("plan_mode_proposed", fields: [
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "content_length": "\(event.proposedPlanContent.count)"
            ])

        case .planModeApproved(let event):
            e2eEventLog?.record("plan_mode_approved", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])

        case .planModeRejected(let event):
            e2eEventLog?.record("plan_mode_rejected", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])

        case .planModeModified(let event):
            e2eEventLog?.record("plan_mode_modified", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])

        case .planModeHandoff(let event):
            e2eEventLog?.record("plan_mode_handoff", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "implementation_prompt_length": "\(event.implementationPrompt.count)",
                "model_input_item_count": "\(event.modelInputItemCount)"
            ])

        case .compactTurnStarted(let id):
            e2eEventLog?.record("compact_turn_started", fields: [
                "turn_id": id.uuidString
            ])

        case .contextCompactionStarted(let id):
            e2eEventLog?.record("context_compaction_started", fields: [
                "item_id": id
            ])

        case .contextCompactionCompleted(let id):
            e2eEventLog?.record("context_compaction_completed", fields: [
                "item_id": id
            ])

        case .contextCompactionFailed(let id, message: let message):
            e2eEventLog?.record("context_compaction_failed", fields: [
                "item_id": id,
                "message": message
            ])

        case .compactionWarning(let message):
            e2eEventLog?.record("compaction_warning", fields: [
                "message": message
            ])

        case .modelRequestPreparing(let statusText):
            e2eEventLog?.record("model_request_preparing", fields: [
                "status_text": statusText
            ])

        case .probe(let probe):
            e2eEventLog?.record(probe.name, fields: probe.fields)
            if probe.name == "model_final_answer_provenance" {
                pendingFinalAnswerProvenanceFields = probe.fields
            }

        case .assistantProgressSegmentStarted(let id):
            streamingAssistantProgressItemID = nil
            e2eEventLog?.record("assistant_progress_segment_started", fields: [
                "segment_id": id.uuidString
            ])

        case .assistantProgress(let text):
            e2eEventLog?.record("assistant_progress", fields: [
                "text_length": "\(text.count)",
                "text": text
            ])
            replaceOrAppendAssistantProgress(text)

        case .assistantProgressDelta(let text):
            e2eEventLog?.record("assistant_progress_delta", fields: [
                "text_length": "\(text.count)",
                "text": text
            ])
            appendAssistantProgressDelta(text)

        case .toolPreparing(let name, let statusText):
            e2eEventLog?.record("tool_preparing", fields: [
                "name": name.rawValue,
                "status_text": statusText
            ])
            streamingAssistantProgressItemID = nil
            beginToolPreparation(name: name, statusText: statusText)

        case .toolStarted(let call, let statusText, let batchID):
            e2eEventLog?.record("tool_started", fields: [
                "name": call.name.rawValue,
                "cmd": call.arguments["cmd"]?.stringValue ?? "",
                "input_length": "\(call.input?.count ?? 0)",
                "status_text": statusText
            ])
            streamingAssistantProgressItemID = nil
            beginOrUpdateToolCall(call, statusText: statusText, batchID: batchID)

        case .toolOutputDelta(let callID, let name, let stream, let text):
            e2eEventLog?.record("tool_output_delta", fields: [
                "call_id": callID,
                "name": name.rawValue,
                "stream": stream.rawValue,
                "text_length": "\(text.count)",
                "text": text
            ])
            appendToolOutputDelta(callID: callID, name: name, stream: stream, text: text)

        case .toolCompleted(let result, _):
            e2eEventLog?.record("tool_completed", fields: toolCompletedLogFields(result))
            completeToolCall(result)

        case .finalAnswerStarted:
            e2eEventLog?.record("final_answer_started")
            streamingAssistantProgressItemID = nil
            ensureStreamingFinalItem()

        case .finalAnswerDelta(let text):
            e2eEventLog?.record("final_answer_delta", fields: [
                "text_length": "\(text.count)",
                "text": text
            ])
            appendFinalDelta(text)

        case .finalAnswer(let text):
            e2eEventLog?.record("final_answer", fields: finalAnswerLogFields(text))
            pendingFinalAnswerProvenanceFields = nil
            replaceOrAppendFinalAnswer(text)

        case .contextUsageUpdated:
            break

        case .modelStreamRetrying(let statusText):
            e2eEventLog?.record("model_stream_retrying", fields: [
                "status_text": statusText
            ])
            replaceOrAppendAssistantProgress(statusText)
        }
    }

    private func finalAnswerLogFields(_ text: String) -> [String: String] {
        var fields = [
            "text_length": "\(text.count)",
            "text_hash_algorithm": "sha256-utf8",
            "text_sha256": Self.sha256Hex(text),
            "text": text,
            "response_id": "",
            "response_completed": "false",
            "source": ""
        ]
        if let provenance = pendingFinalAnswerProvenanceFields {
            fields["response_id"] = provenance["response_id"] ?? ""
            fields["response_completed"] = provenance["response_completed"] ?? "false"
            fields["source"] = provenance["source"] ?? ""
            fields["provenance_event"] = "model_final_answer_provenance"
            fields["provenance_text_length"] = provenance["text_length"] ?? ""
            fields["provenance_text_hash_algorithm"] = provenance["text_hash_algorithm"] ?? ""
            fields["provenance_text_sha256"] = provenance["text_sha256"] ?? ""
            fields["model_request_layer"] = provenance["model_request_layer"] ?? ""
            fields["model_request_run_id"] = provenance["model_request_run_id"] ?? ""
            fields["model_request_sequence"] = provenance["model_request_sequence"] ?? ""
            fields["model_request_model"] = provenance["model_request_model"] ?? ""
            fields["request_user_input_hash_algorithm"] = provenance["request_user_input_hash_algorithm"] ?? ""
            fields["request_user_input_sha256s"] = provenance["request_user_input_sha256s"] ?? ""
            fields["request_last_user_input_sha256"] = provenance["request_last_user_input_sha256"] ?? ""
        }
        return fields
    }


    private func appendTimeline(
        kind: MSPAgentTimelineItem.Kind,
        title: String,
        body: String,
        detail: String? = nil,
        callID: String? = nil,
        batchID: UUID? = nil,
        toolName: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        exitCode: Int? = nil,
        status: String? = nil,
        previewItems: [AssistantSupportPreviewItem] = [],
        startedAtMilliseconds: Int? = nil,
        completedAtMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        transcript.append(
            MSPAgentTimelineItem(
                kind: kind,
                title: title,
                body: body,
                detail: detail,
                callID: callID,
                batchID: batchID,
                toolName: toolName,
                command: command,
                cwd: cwd,
                stdout: stdout,
                stderr: stderr,
                exitCode: exitCode,
                status: status,
                previewItems: previewItems,
                startedAtMilliseconds: startedAtMilliseconds,
                completedAtMilliseconds: completedAtMilliseconds,
                durationMilliseconds: durationMilliseconds,
                turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
            )
        )
    }

    private func beginToolPreparation(name: MSPAgentToolName, statusText: String) {
        let presentation = toolPresentation(for: name)
        let item = MSPAgentTimelineItem(
            kind: .toolCall,
            title: presentation.title,
            body: statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? presentation.runningBody
                : statusText,
            detail: nil,
            toolName: name.rawValue,
            status: "inProgress",
            startedAtMilliseconds: Self.currentMillisecondsSince1970(),
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        pendingToolPreparationItemIDs.append(item.id)
        transcript.append(item)
    }

    private func beginOrUpdateToolCall(
        _ call: MSPAgentToolCall,
        statusText: String,
        batchID: UUID?
    ) {
        let startedAt = Self.currentMillisecondsSince1970()
        let presentation = toolPresentation(for: call.name)
        let command = call.name == .applyPatch
            ? (call.input ?? call.rawArguments ?? "")
            : (call.arguments["cmd"]?.stringValue ?? "")
        let body = statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? presentation.runningBody
            : statusText
        let detail = toolCallDetail(call, statusText: body)

        while !pendingToolPreparationItemIDs.isEmpty {
            let pendingToolPreparationItemID = pendingToolPreparationItemIDs.removeFirst()
            guard let index = transcript.firstIndex(where: { $0.id == pendingToolPreparationItemID }) else {
                continue
            }
            transcript[index].callID = call.id
            transcript[index].batchID = batchID
            transcript[index].toolName = call.name.rawValue
            transcript[index].command = command
            transcript[index].cwd = "/"
            transcript[index].body = body
            transcript[index].detail = detail
            transcript[index].status = "inProgress"
            transcript[index].startedAtMilliseconds = transcript[index].startedAtMilliseconds ?? startedAt
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            activeToolStartedAtMillisecondsByCallID[call.id] = transcript[index].startedAtMilliseconds ?? startedAt
            return
        }

        activeToolStartedAtMillisecondsByCallID[call.id] = startedAt
        appendTimeline(
            kind: .toolCall,
            title: presentation.title,
            body: body,
            detail: detail,
            callID: call.id,
            batchID: batchID,
            toolName: call.name.rawValue,
            command: command,
            cwd: "/",
            status: "inProgress",
            startedAtMilliseconds: startedAt
        )
    }

    private func completeToolCall(_ result: MSPAgentToolResult) {
        let completedAt = Self.currentMillisecondsSince1970()
        let object = result.internalContent?.objectValue
        let command = object?["cmd"]?.stringValue
        let stdout = object?["stdout"]?.stringValue
        let stderr = object?["stderr"]?.stringValue
        let exitCode = object?["exit_code"]?.intValue ?? (result.ok ? 0 : 1)
        let startedAt = activeToolStartedAtMillisecondsByCallID[result.callID]
        let duration = max(100, completedAt - (startedAt ?? completedAt))
        let presentation = toolPresentation(for: result.name)
        let existingPatchInput = result.name == .applyPatch
            ? transcript.first(where: { $0.callID == result.callID })?.command
            : nil
        let operation = registerApplyPatchOperationIfNeeded(
            result,
            completedAt: completedAt,
            patchInput: existingPatchInput
        )
        let previewItems = applyPatchPreviewItems(
            for: result,
            operation: operation,
            patchInput: existingPatchInput
        )
        let body = toolResultTimelineBody(result, presentation: presentation, operation: operation)
        let detail = toolResultDetail(result)

        if let index = transcript.firstIndex(where: { $0.callID == result.callID }) {
            transcript[index].body = body
            transcript[index].detail = detail
            transcript[index].toolName = result.name.rawValue
            transcript[index].command = command ?? transcript[index].command
            transcript[index].stdout = stdout
            transcript[index].stderr = stderr
            transcript[index].exitCode = exitCode
            transcript[index].status = result.ok ? "completed" : "failed"
            transcript[index].previewItems = previewItems
            transcript[index].completedAtMilliseconds = completedAt
            transcript[index].durationMilliseconds = duration
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
        } else {
            appendTimeline(
                kind: .toolResult,
                title: presentation.title,
                body: body,
                detail: detail,
                callID: result.callID,
                toolName: result.name.rawValue,
                command: command,
                cwd: "/",
                stdout: stdout,
                stderr: stderr,
                exitCode: exitCode,
                status: result.ok ? "completed" : "failed",
                previewItems: previewItems,
                startedAtMilliseconds: startedAt,
                completedAtMilliseconds: completedAt,
                durationMilliseconds: duration
            )
        }
        activeToolStartedAtMillisecondsByCallID[result.callID] = nil
    }

    func handleExampleChatWriteOperationAction(operationID: UUID, direction: String) {
        guard var operation = applyPatchOperationsByID[operationID],
              let runtime else {
            e2eEventLog?.record("apply_patch_write_operation_missing", fields: [
                "operation_id": operationID.uuidString,
                "direction": direction
            ])
            return
        }

        let isRedo = direction.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "redo"
        do {
            if isRedo {
                guard operation.canRedo else {
                    refreshApplyPatchPreview(for: operation)
                    return
                }
                try validateApplyPatchSnapshots(
                    operation.snapshots,
                    runtime: runtime,
                    targetIsAfterState: false
                )
                try restoreApplyPatchSnapshots(
                    operation.snapshots,
                    runtime: runtime,
                    targetIsAfterState: true
                )
                operation.undoneAtMilliseconds = nil
            } else {
                guard operation.canUndo else {
                    refreshApplyPatchPreview(for: operation)
                    return
                }
                try validateApplyPatchSnapshots(
                    operation.snapshots,
                    runtime: runtime,
                    targetIsAfterState: true
                )
                try restoreApplyPatchSnapshots(
                    operation.snapshots.reversed(),
                    runtime: runtime,
                    targetIsAfterState: false
                )
                operation.undoneAtMilliseconds = Self.currentMillisecondsSince1970()
            }
            applyPatchOperationsByID[operation.id] = operation
            refreshApplyPatchPreview(for: operation)
            refreshWorkspace()
            e2eEventLog?.record("apply_patch_write_operation_applied", fields: [
                "operation_id": operation.id.uuidString,
                "direction": isRedo ? "redo" : "undo",
                "can_undo": "\(operation.canUndo)",
                "can_redo": "\(operation.canRedo)"
            ])
        } catch {
            e2eEventLog?.record("apply_patch_write_operation_failed", fields: [
                "operation_id": operation.id.uuidString,
                "direction": isRedo ? "redo" : "undo",
                "message": error.localizedDescription
            ])
        }
    }

    private func registerApplyPatchOperationIfNeeded(
        _ result: MSPAgentToolResult,
        completedAt: Int,
        patchInput: String? = nil
    ) -> ApplyPatchWriteOperation? {
        guard result.name == .applyPatch,
              result.ok,
              let object = result.internalContent?.objectValue else {
            return nil
        }
        if let existingID = applyPatchOperationIDByCallID[result.callID],
           let existing = applyPatchOperationsByID[existingID] {
            return existing
        }

        let snapshots = Self.applyPatchFileSnapshots(from: object)
        guard !snapshots.isEmpty else {
            return nil
        }
        let changedPaths = Self.applyPatchChangedPaths(from: object)
        guard let turnDiff = Self.applyPatchPayloadString(object, keys: ["turn_diff", "diff"])
                ?? Self.applyPatchDiffPreviewText(fromPatchInput: patchInput, changedPaths: changedPaths),
              !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let path = snapshots.first?.path ?? changedPaths.first ?? "文本文件"
        let documentName = Self.applyPatchDocumentName(for: path)
        let stats = Self.applyPatchStats(from: object, diff: turnDiff)
        let operation = ApplyPatchWriteOperation(
            id: UUID(),
            callID: result.callID,
            path: path,
            documentName: documentName,
            turnDiff: turnDiff,
            linesAdded: stats.added,
            linesRemoved: stats.removed,
            snapshots: snapshots,
            createdAtMilliseconds: completedAt,
            undoneAtMilliseconds: nil
        )
        applyPatchOperationIDByCallID[result.callID] = operation.id
        applyPatchOperationsByID[operation.id] = operation
        return operation
    }

    private func applyPatchPreviewItems(
        for result: MSPAgentToolResult,
        operation: ApplyPatchWriteOperation?,
        patchInput: String? = nil
    ) -> [AssistantSupportPreviewItem] {
        guard result.name == .applyPatch,
              let object = result.internalContent?.objectValue else {
            return []
        }

        let changedPaths = Self.applyPatchChangedPaths(from: object)
        guard let turnDiff = operation?.turnDiff
                ?? Self.applyPatchPayloadString(object, keys: ["turn_diff", "diff"])
                ?? Self.applyPatchDiffPreviewText(fromPatchInput: patchInput, changedPaths: changedPaths),
              !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let path = operation?.path ?? changedPaths.first ?? "文本文件"
        let stats = operation.map { ($0.linesAdded, $0.linesRemoved) }
            ?? Self.applyPatchStats(from: object, diff: turnDiff)
        var payload: [String: ExampleChatJSONValue] = [
            "chat_preview_kind": .string("apply_patch_diff"),
            "patch_status": .string(result.ok ? "applied" : "failed"),
            "status": .string(result.ok ? "applied" : "failed"),
            "p": .string(path),
            "file_name": .string(Self.applyPatchDocumentName(for: path)),
            "turn_diff": .string(turnDiff),
            "diff": .string(turnDiff),
            "lines_added": .number(Double(stats.0)),
            "lines_removed": .number(Double(stats.1)),
            "call_id": .string(result.callID)
        ]
        if !changedPaths.isEmpty {
            payload["changed_paths"] = .array(changedPaths.map { .string($0) })
        }
        if let changes = object["changes"]?.arrayValue {
            payload["changes"] = .array(changes.map(Self.exampleChatJSONValue(from:)))
        }
        if let operation {
            payload["operation_id"] = .string(operation.id.uuidString)
            payload["can_undo"] = .bool(operation.canUndo)
            payload["can_redo"] = .bool(operation.canRedo)
            payload["write_operation"] = .object(operation.referenceObject)
        }

        let statText = "+\(stats.0) -\(stats.1)"
        return [
            AssistantSupportPreviewItem(
                kind: .markdown,
                title: "文本文件差异",
                subtitle: "\(path) · \(statText)",
                documentName: operation?.documentName ?? Self.applyPatchDocumentName(for: path),
                filePath: path,
                fileName: Self.applyPatchDocumentName(for: path),
                payload: .object(payload)
            )
        ]
    }

    private func refreshApplyPatchPreview(for operation: ApplyPatchWriteOperation) {
        guard let index = transcript.firstIndex(where: { $0.callID == operation.callID }) else {
            return
        }
        let result = MSPAgentToolResult(
            callID: operation.callID,
            name: .applyPatch,
            outputKind: .custom,
            ok: true,
            content: .string(""),
            internalContent: .object([
                "turn_diff": .string(operation.turnDiff),
                "diff": .string(operation.turnDiff),
                "lines_added": .number(Double(operation.linesAdded)),
                "lines_removed": .number(Double(operation.linesRemoved))
            ]),
            errorMessage: nil
        )
        transcript[index].previewItems = applyPatchPreviewItems(for: result, operation: operation)
    }

    private func validateApplyPatchSnapshots<S: Sequence>(
        _ snapshots: S,
        runtime: MSPPlaygroundShellRuntime,
        targetIsAfterState: Bool
    ) throws where S.Element == ApplyPatchFileSnapshot {
        for snapshot in snapshots {
            guard try applyPatchSnapshot(
                snapshot,
                matchesStateIn: runtime,
                targetIsAfterState: targetIsAfterState
            ) else {
                throw NSError(
                    domain: "MSPPlaygroundApplyPatch",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "workspace changed after apply_patch: \(snapshot.path)"
                    ]
                )
            }
        }
    }

    private func restoreApplyPatchSnapshots<S: Sequence>(
        _ snapshots: S,
        runtime: MSPPlaygroundShellRuntime,
        targetIsAfterState: Bool
    ) throws where S.Element == ApplyPatchFileSnapshot {
        for snapshot in snapshots {
            let shouldExist = targetIsAfterState ? snapshot.existsAfter : snapshot.existedBefore
            let text = targetIsAfterState ? snapshot.afterText : snapshot.beforeText
            if shouldExist {
                try runtime.writeTextFile(snapshot.path, contents: text ?? "")
            } else {
                do {
                    try runtime.removeFile(snapshot.path)
                } catch MSPWorkspaceFileSystemError.notFound(_) {
                    continue
                }
            }
        }
    }

    private func applyPatchSnapshot(
        _ snapshot: ApplyPatchFileSnapshot,
        matchesStateIn runtime: MSPPlaygroundShellRuntime,
        targetIsAfterState: Bool
    ) throws -> Bool {
        let shouldExist = targetIsAfterState ? snapshot.existsAfter : snapshot.existedBefore
        let expectedText = targetIsAfterState ? snapshot.afterText : snapshot.beforeText
        do {
            let currentText = try runtime.readTextFile(snapshot.path)
            return shouldExist && currentText == (expectedText ?? "")
        } catch MSPWorkspaceFileSystemError.notFound(_) {
            return !shouldExist
        }
    }

    private static func applyPatchFileSnapshots(
        from object: [String: MSPAgentJSONValue]
    ) -> [ApplyPatchFileSnapshot] {
        object["file_snapshots"]?.arrayValue?.compactMap { value in
            guard let snapshot = value.objectValue,
                  let path = snapshot["path"]?.stringValue else {
                return nil
            }
            return ApplyPatchFileSnapshot(
                path: path,
                existedBefore: Self.mspBool(snapshot["existed_before"]) ?? false,
                existsAfter: Self.mspBool(snapshot["exists_after"]) ?? false,
                beforeText: snapshot["before_text"]?.stringValue,
                afterText: snapshot["after_text"]?.stringValue
            )
        } ?? []
    }

    private static func applyPatchChangedPaths(
        from object: [String: MSPAgentJSONValue]
    ) -> [String] {
        object["changed_paths"]?.arrayValue?
            .compactMap(\.stringValue)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
    }

    private static func applyPatchPayloadString(
        _ object: [String: MSPAgentJSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    static func applyPatchDiffPreviewText(
        fromPatchInput patchInput: String?,
        changedPaths: [String]
    ) -> String? {
        guard let patchInput,
              !patchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var output: [String] = []
        var currentPath: String?
        var bodyLineCount = 0
        var fallbackPathIndex = 0

        func normalizedPatchPath(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        func fallbackPath() -> String {
            defer { fallbackPathIndex += 1 }
            guard fallbackPathIndex < changedPaths.count else {
                return "文本文件"
            }
            return changedPaths[fallbackPathIndex]
        }

        func beginFile(path rawPath: String, newPath rawNewPath: String? = nil) {
            let path = normalizedPatchPath(rawPath).isEmpty
                ? fallbackPath()
                : normalizedPatchPath(rawPath)
            let newPath = rawNewPath.map(normalizedPatchPath)
            currentPath = path
            if !output.isEmpty {
                output.append("")
            }
            output.append("diff --git a/\(path) b/\(newPath ?? path)")
            output.append("--- \(path == "/dev/null" ? "/dev/null" : "a/\(path)")")
            output.append("+++ \((newPath ?? path) == "/dev/null" ? "/dev/null" : "b/\(newPath ?? path)")")
        }

        for line in patchInput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker == "*** Begin Patch" || marker == "*** End Patch" || marker == "*** End of File" {
                continue
            }
            if marker.hasPrefix("*** Update File: ") {
                beginFile(path: String(marker.dropFirst("*** Update File: ".count)))
                continue
            }
            if marker.hasPrefix("*** Add File: ") {
                beginFile(path: "/dev/null", newPath: String(marker.dropFirst("*** Add File: ".count)))
                continue
            }
            if marker.hasPrefix("*** Delete File: ") {
                beginFile(path: String(marker.dropFirst("*** Delete File: ".count)), newPath: "/dev/null")
                continue
            }
            if marker.hasPrefix("*** Move to: ") {
                continue
            }
            if marker.hasPrefix("***") {
                continue
            }
            guard currentPath != nil else {
                continue
            }
            if line.hasPrefix("@@")
                || line.hasPrefix("+")
                || line.hasPrefix("-")
                || line.hasPrefix(" ")
                || line.hasPrefix("\\") {
                output.append(line)
                bodyLineCount += 1
            }
        }

        guard bodyLineCount > 0 else {
            return nil
        }
        return output.joined(separator: "\n")
    }

    private static func applyPatchStats(
        from object: [String: MSPAgentJSONValue],
        diff: String
    ) -> (added: Int, removed: Int) {
        let added = object["lines_added"]?.intValue
        let removed = object["lines_removed"]?.intValue
        if let added, let removed {
            return (max(0, added), max(0, removed))
        }
        var computedAdded = 0
        var computedRemoved = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                continue
            }
            if line.hasPrefix("+") {
                computedAdded += 1
            } else if line.hasPrefix("-") {
                computedRemoved += 1
            }
        }
        return (computedAdded, computedRemoved)
    }

    private static func mspBool(_ value: MSPAgentJSONValue?) -> Bool? {
        guard case .bool(let bool) = value else { return nil }
        return bool
    }

    private static func applyPatchDocumentName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "文本文件" : name
    }

    private static func exampleChatJSONValue(from value: MSPAgentJSONValue) -> ExampleChatJSONValue {
        switch value {
        case .string(let text):
            return .string(text)
        case .number(let number):
            return .number(number)
        case .bool(let bool):
            return .bool(bool)
        case .object(let object):
            return .object(object.mapValues(exampleChatJSONValue(from:)))
        case .array(let array):
            return .array(array.map(exampleChatJSONValue(from:)))
        case .null:
            return .null
        }
    }

    private func appendToolOutputDelta(
        callID: String,
        name: MSPAgentToolName,
        stream: MSPExecCommandOutputStreamName,
        text: String
    ) {
        guard name == .execCommand,
              !text.isEmpty,
              let index = transcript.firstIndex(where: { $0.callID == callID }) else {
            return
        }
        switch stream {
        case .stdout:
            transcript[index].stdout = (transcript[index].stdout ?? "") + text
        case .stderr:
            transcript[index].stderr = (transcript[index].stderr ?? "") + text
        }
        transcript[index].status = "inProgress"
        transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
            ?? currentTurnStartedAtMilliseconds
    }

    private func ensureStreamingFinalItem() {
        guard streamingFinalItemID == nil else {
            return
        }
        let item = MSPAgentTimelineItem(
            kind: .assistantFinal,
            title: "",
            body: "",
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        streamingFinalItemID = item.id
        transcript.append(item)
    }

    private func ensureStreamingAssistantProgressItem() {
        guard streamingAssistantProgressItemID == nil else {
            return
        }
        let item = MSPAgentTimelineItem(
            kind: .assistantProgress,
            title: "模型中间回复",
            body: "",
            startedAtMilliseconds: Self.currentMillisecondsSince1970(),
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        streamingAssistantProgressItemID = item.id
        transcript.append(item)
    }

    private func appendAssistantProgressDelta(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        ensureStreamingAssistantProgressItem()
        guard let streamingAssistantProgressItemID,
              let index = transcript.firstIndex(where: { $0.id == streamingAssistantProgressItemID }) else {
            return
        }
        transcript[index].body += text
    }

    private func replaceOrAppendAssistantProgress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if let streamingAssistantProgressItemID,
           let index = transcript.firstIndex(where: { $0.id == streamingAssistantProgressItemID }) {
            transcript[index].body = text
            self.streamingAssistantProgressItemID = nil
            return
        }
        appendTimeline(kind: .assistantProgress, title: "模型中间回复", body: text)
    }

    private func appendFinalDelta(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        ensureStreamingFinalItem()
        guard let streamingFinalItemID,
              let index = transcript.firstIndex(where: { $0.id == streamingFinalItemID }) else {
            return
        }
        transcript[index].body += text
    }

    private func replaceOrAppendFinalAnswer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let streamingFinalItemID,
           let index = transcript.firstIndex(where: { $0.id == streamingFinalItemID }) {
            transcript[index].body = trimmed.isEmpty ? transcript[index].body : text
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            return
        }
        appendTimeline(kind: .assistantFinal, title: "", body: text)
    }

    private func finishCurrentTurn() {
        guard let currentTurnStartedAtMilliseconds else {
            return
        }
        let duration = max(0, Self.currentMillisecondsSince1970() - currentTurnStartedAtMilliseconds)
        for index in transcript.indices
        where transcript[index].turnStartedAtMilliseconds == currentTurnStartedAtMilliseconds {
            transcript[index].turnDurationMilliseconds = duration
        }
    }

    private func applyCodexOAuthQuotaResult(_ result: MSPCodexOAuthQuotaResult) {
        codexOAuthQuota = result

        var updated = codexOAuthConfiguration.normalized()
        var shouldSave = false
        if let email = result.email, !email.isEmpty, updated.email != email {
            updated.email = email
            shouldSave = true
        }
        if let planType = result.planType, !planType.isEmpty, updated.planType != planType {
            updated.planType = planType
            shouldSave = true
        }
        if result.status == .success, updated.lastLoginStatus != .signedIn {
            updated.lastLoginStatus = .signedIn
            shouldSave = true
        }
        if updated.lastStatusMessage != result.message {
            updated.lastStatusMessage = result.message
            shouldSave = true
        }
        if updated.lastCheckedAt != result.checkedAt {
            updated.lastCheckedAt = result.checkedAt
            shouldSave = true
        }
        if shouldSave {
            codexOAuthConfiguration = updated
            MSPCodexOAuthConfigurationStore.save(updated)
        }
    }

    private func applyCodexOAuthLoginResult(_ result: MSPCodexOAuthLoginResult) {
        codexOAuthConfiguration = result.configuration
        codexOAuthConfiguration.lastStatusMessage = result.message
        MSPCodexOAuthConfigurationStore.save(codexOAuthConfiguration)
        if result.configuration.lastLoginStatus != .signedIn {
            codexOAuthQuota = nil
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func transcriptVisibleTextProbeEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-probe-transcript-visible-text")
            || environment["MSP_PLAYGROUND_TRANSCRIPT_VISIBLE_TEXT_PROBE"] == "1"
    }

    private static func transcriptToolDetailExpansionEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-expand-transcript-tool-details")
            || environment["MSP_PLAYGROUND_EXPAND_TRANSCRIPT_TOOL_DETAILS"] == "1"
    }

    private func toolPresentation(for name: MSPAgentToolName) -> (
        title: String,
        runningBody: String,
        completedBody: String,
        failedBody: String
    ) {
        if name == .applyPatch {
            return (
                title: "文件补丁",
                runningBody: "正在编辑文件",
                completedBody: "已编辑文件",
                failedBody: "文件编辑失败"
            )
        }
        return (
            title: "工作区命令",
            runningBody: "正在执行工作区命令",
            completedBody: "已执行工作区命令",
            failedBody: "工作区命令执行失败"
        )
    }

    private func toolResultTimelineBody(
        _ result: MSPAgentToolResult,
        presentation: (title: String, runningBody: String, completedBody: String, failedBody: String),
        operation: ApplyPatchWriteOperation?
    ) -> String {
        guard result.name == .applyPatch else {
            return result.ok ? presentation.completedBody : presentation.failedBody
        }
        guard result.ok else {
            return presentation.failedBody
        }
        let changedPaths = result.internalContent?.objectValue.map(Self.applyPatchChangedPaths(from:)) ?? []
        if changedPaths.count > 1 {
            return "已编辑 \(changedPaths.count) 个文件"
        }
        let path = operation?.path ?? changedPaths.first
        let fileName = path.map(Self.applyPatchDocumentName(for:)) ?? "文件"
        return "已编辑 \(fileName)"
    }

    private func toolCallDetail(
        _ call: MSPAgentToolCall,
        statusText: String
    ) -> String {
        if call.name == .applyPatch {
            let bytes = call.input?.utf8.count ?? 0
            return "\(statusText)\npatch bytes: \(bytes)"
        }
        let command = call.arguments["cmd"]?.stringValue ?? ""
        guard !command.isEmpty else {
            return statusText
        }
        return "\(statusText)\n命令: \(command)"
    }

    private func toolResultBody(_ result: MSPAgentToolResult) -> String {
        if let text = result.content?.stringValue, !text.isEmpty {
            return text
        }
        if let error = result.errorMessage, !error.isEmpty {
            return error
        }
        return "(no output)"
    }

    private func toolResultDetail(_ result: MSPAgentToolResult) -> String? {
        if result.name == .applyPatch {
            return result.ok ? nil : result.errorMessage
        }
        guard let object = result.internalContent?.objectValue else {
            return nil
        }
        let exitCode = object["exit_code"]?.intValue ?? (result.ok ? 0 : 1)
        let changedPaths = object["changed_paths"]?.arrayValue?
            .compactMap(\.stringValue)
            .joined(separator: ", ") ?? ""
        guard result.name == .applyPatch, !changedPaths.isEmpty else {
            return "退出码: \(exitCode)"
        }
        return "退出码: \(exitCode)\nchanged paths: \(changedPaths)"
    }

    private func toolCompletedLogFields(_ result: MSPAgentToolResult) -> [String: String] {
        let contentText = result.content?.stringValue ?? ""
        let containsStructuredShellKeys = contentText.contains("\"stdout\"")
            || contentText.contains("\"stderr\"")
            || contentText.contains("\"exit_code\"")
        var fields: [String: String] = [
            "name": result.name.rawValue,
            "ok": "\(result.ok)",
            "content_kind": result.content?.stringValue == nil ? "non_string" : "string",
            "content_length": "\(contentText.count)",
            "content_text": contentText,
            "content_contains_shell_json_keys": "\(containsStructuredShellKeys)"
        ]
        if let object = result.internalContent?.objectValue {
            fields["internal_exit_code"] = "\(object["exit_code"]?.intValue ?? (result.ok ? 0 : 1))"
            fields["changed_paths"] = object["changed_paths"]?.arrayValue?
                .compactMap(\.stringValue)
                .joined(separator: ",") ?? ""
        }
        if let errorMessage = result.errorMessage,
           !errorMessage.isEmpty {
            fields["error_length"] = "\(errorMessage.count)"
        }
        return fields
    }

    private static func currentMillisecondsSince1970() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private func refreshWorkspace() async {
        guard let runtime else {
            return
        }

        do {
            fileTreeState = .loaded(try runtime.snapshotWorkspace())
        } catch {
            fileTreeState = .failed(error.localizedDescription)
        }
    }

    private struct TranscriptFixture {
        var variant: TranscriptFixtureVariant
        var items: [MSPAgentTimelineItem]
        var isGenerating: Bool
    }

    private enum TranscriptFixtureVariant: String {
        case completed
        case running
        case thinking
        case failed
        case markdown
        case applyPatch = "apply_patch"
    }

    private static func launchTranscriptFixtureIfRequested() -> TranscriptFixture? {
        guard let variant = transcriptFixtureVariant() else {
            return nil
        }
        let turnStartedAt = currentMillisecondsSince1970() - 2_400
        switch variant {
        case .completed:
            return TranscriptFixture(
                variant: variant,
                items: completedTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        case .running:
            return TranscriptFixture(
                variant: variant,
                items: runningTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: true
            )
        case .thinking:
            return TranscriptFixture(
                variant: variant,
                items: thinkingTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: true
            )
        case .failed:
            return TranscriptFixture(
                variant: variant,
                items: failedTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        case .markdown:
            return TranscriptFixture(
                variant: variant,
                items: markdownTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        case .applyPatch:
            return TranscriptFixture(
                variant: variant,
                items: applyPatchTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        }
    }

    private static func transcriptFixtureVariant() -> TranscriptFixtureVariant? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--msp-transcript-fixture=") }) {
            let rawValue = String(inline.dropFirst("--msp-transcript-fixture=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptFixtureVariant(rawValue: rawValue).map { $0 } ?? .completed
        }
        guard let flagIndex = arguments.firstIndex(of: "--msp-transcript-fixture") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return .completed
        }
        let rawValue = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.hasPrefix("--") else {
            return .completed
        }
        return TranscriptFixtureVariant(rawValue: rawValue) ?? .completed
    }

    private static func completedTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先查看当前工作区。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                detail: "退出码: 0",
                callID: "fixture-ls",
                command: "ls /",
                cwd: "/",
                stdout: "notes\nwelcome.md\nMSP_HIDDEN_TOOL_STDOUT_SENTINEL\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 300,
                completedAtMilliseconds: turnStartedAt + 1_200,
                durationMilliseconds: 900,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "工作区里现在有一个 notes 目录和一个 welcome.md 文件。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            )
        ]
    }

    private static func applyPatchTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        let diff = """
        diff --git a/notes/outline.md b/notes/outline.md
        --- a/notes/outline.md
        +++ b/notes/outline.md
        @@ -1,3 +1,3 @@
         # Outline
        -Draft notes
        +Draft notes with review checklist
         Next step
        diff --git a/Sources/Tooling/Runner.swift b/Sources/Tooling/Runner.swift
        --- a/Sources/Tooling/Runner.swift
        +++ b/Sources/Tooling/Runner.swift
        @@ -2,4 +2,5 @@
         struct Runner {
             let name: String
        +    let retries: Int
         }
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -8,2 +8,3 @@
         ## Usage
         Run the playground.
        +Use apply_patch for text edits.
        """
        let changedPaths = [
            "notes/outline.md",
            "Sources/Tooling/Runner.swift",
            "README.md"
        ]
        let preview = AssistantSupportPreviewItem(
            kind: .markdown,
            title: "文本文件差异",
            subtitle: "3 个文件 · +3 -1",
            documentName: "3 个文件",
            payload: .object([
                "chat_preview_kind": .string("apply_patch_diff"),
                "patch_status": .string("applied"),
                "status": .string("applied"),
                "p": .string(changedPaths[0]),
                "turn_diff": .string(diff),
                "diff": .string(diff),
                "changed_paths": .array(changedPaths.map { .string($0) }),
                "changes": .array(changedPaths.map { path in
                    .object([
                        "path": .string(path),
                        "kind": .string("update")
                    ])
                }),
                "lines_added": .number(3),
                "lines_removed": .number(1),
                "call_id": .string("fixture-apply-patch")
            ])
        )
        return [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "把说明和 Runner 一起更新一下",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我会直接修改这些文本文件。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "文件补丁",
                body: "已编辑 3 个文件",
                callID: "fixture-apply-patch",
                toolName: "apply_patch",
                command: "*** Begin Patch\n*** Update File: notes/outline.md\n*** End Patch",
                status: "completed",
                previewItems: [preview],
                startedAtMilliseconds: turnStartedAt + 300,
                completedAtMilliseconds: turnStartedAt + 1_200,
                durationMilliseconds: 900,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "已经更新了 outline.md、Runner.swift 和 README.md。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            )
        ]
    }

    private static func thinkingTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "先分析一下工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先确认当前工作区状态。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]
    }

    private static func runningTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先查看当前工作区。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                detail: "命令: ls /",
                callID: "fixture-running-ls",
                command: "ls /",
                cwd: "/",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 300,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]
    }

    private static func failedTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我找一下 docs",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先用工作区命令查找。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "工作区命令执行失败",
                detail: "退出码: 127",
                callID: "fixture-failed-find",
                command: "find /docs -maxdepth 2 -print",
                cwd: "/",
                stdout: "",
                stderr: "find: command not found\nMSP_HIDDEN_TOOL_STDERR_SENTINEL\n",
                exitCode: 127,
                status: "failed",
                startedAtMilliseconds: turnStartedAt + 300,
                completedAtMilliseconds: turnStartedAt + 900,
                durationMilliseconds: 600,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "这个工作区命令没有执行成功，我会换一种方式继续检查。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            )
        ]
    }

    private static func markdownTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "展示数学和代码渲染",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: """
                下面是数学和代码：

                内联公式 $E=mc^2$，块公式：

                $$\\int_0^1 x^2 dx = \\frac{1}{3}$$

                ```swift
                let answer = 42
                print(answer)
                ```
                """,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 1_800
            )
        ]
    }

    private static func launchAutoSubmitPromptIfRequested() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--msp-auto-submit=") }) {
            let value = String(inline.dropFirst("--msp-auto-submit=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let flagIndex = arguments.firstIndex(of: "--msp-auto-submit") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func launchAutoSubmitPromptSequenceIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        let rawSequence = argumentValue(
            named: "--msp-auto-submit-sequence-json",
            in: arguments
        ) ?? environment["MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON"]

        guard let rawSequence,
              !rawSequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = rawSequence.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }

        let prompts = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return prompts.isEmpty ? nil : prompts
    }

    private static func launchShellDiagnosticRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-shell-diagnostic")
            || environment["MSP_PLAYGROUND_SHELL_DIAGNOSTIC"] == "1"
    }

    private static func launchShellLifecycleDiagnosticRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-shell-lifecycle-diagnostic")
            || environment["MSP_PLAYGROUND_SHELL_LIFECYCLE_DIAGNOSTIC"] == "1"
    }

    private static func launchShellOracleURLIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let rawPath = argumentValue(named: "--msp-shell-oracle-path", in: arguments)
            ?? environment["MSP_PLAYGROUND_SHELL_ORACLE_PATH"]
        guard let rawPath else {
            return nil
        }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = name + "="
        if let inline = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }

    private static func scenePhaseName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}
