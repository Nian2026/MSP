import Foundation
import MSPAgentBridge
import MSPCodexApplyPatchRuntime
import ModelShellProxy

@MainActor
final class MSPPlaygroundAgentRuntime {
    private let shellRuntime: MSPPlaygroundShellRuntime
    private let applyPatchExecutor: (any MSPApplyPatchExecuting)?
    private let applyPatchRuntimeError: String?
    private var activeConversation: MSPAgentConversation?
    private var activeConversationSignature: ConversationSignature?

    init(
        shellRuntime: MSPPlaygroundShellRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.shellRuntime = shellRuntime
        do {
            self.applyPatchExecutor = try Self.makeApplyPatchExecutor(
                workspaceURL: shellRuntime.workspaceURL,
                environment: environment
            )
            self.applyPatchRuntimeError = nil
        } catch {
            self.applyPatchExecutor = nil
            self.applyPatchRuntimeError = error.localizedDescription
        }
    }

    func runTurn(
        userMessage: String,
        configuration: MSPModelConfiguration,
        codexOAuthConfiguration: MSPCodexOAuthConfiguration,
        onRequestBuilt: @escaping (MSPAgentRequestBody) -> Void,
        onEvent: @escaping (MSPAgentEvent) -> Void,
        onRuntimeError: @escaping (String) -> Void
    ) async {
        guard let resolvedConfiguration = MSPModelConfigurationResolver.resolve(
            configuration: configuration,
            codexOAuthConfiguration: codexOAuthConfiguration
        ) else {
            onRuntimeError(
                MSPModelConfigurationResolver.missingConfigurationMessage(
                    configuration: configuration,
                    codexOAuthConfiguration: codexOAuthConfiguration
                )
            )
            return
        }

        if let applyPatchRuntimeError {
            onRuntimeError("apply_patch runtime 接入失败：\(applyPatchRuntimeError)")
            return
        }

        guard let conversation = makeConversationIfNeeded(for: resolvedConfiguration) else {
            onRuntimeError("模型 runtime 接入失败：模型 base URL 无效。")
            return
        }

        do {
            _ = try await conversation.send(
                userMessage,
                onRequestBuilt: { requestBody in
                    await MainActor.run {
                        onRequestBuilt(requestBody)
                    }
                },
                onEvent: { event in
                    await MainActor.run {
                        onEvent(event)
                    }
                }
            )
        } catch {
            onRuntimeError("模型请求失败：\(error.localizedDescription)")
        }
    }

    private func makeConversationIfNeeded(
        for resolvedConfiguration: MSPResolvedModelConfiguration
    ) -> MSPAgentConversation? {
        let configuration = resolvedConfiguration.configuration.normalized()
        guard let baseURL = configuration.resolvedBaseURL else {
            return nil
        }
        let signature = ConversationSignature(
            modelConfiguration: configuration,
            credentialSource: resolvedConfiguration.credentialSource,
            additionalHTTPHeaders: resolvedConfiguration.additionalHTTPHeaders
        )
        if let activeConversation,
           activeConversationSignature == signature {
            return activeConversation
        }
        let modelConfiguration = MSPAgentModelConfiguration(
            baseURL: baseURL,
            apiKey: configuration.apiKey,
            model: configuration.modelID,
            providerName: configuration.providerName,
            additionalHTTPHeaders: resolvedConfiguration.additionalHTTPHeaders
        )
        let toolDefinitions = Self.toolDefinitions(applyPatchEnabled: applyPatchExecutor != nil)
        let runtime = MSPAgentRuntime(
            modelConfiguration: modelConfiguration,
            execCommandBridge: shellRuntime.execCommandBridge(),
            applyPatchExecutor: applyPatchExecutor
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: configuration.modelID,
                instructions: MSPAgentBridge.MSPAgentInstructions.defaultInstructions,
                developerContextBlocks: [MSPAgentBridge.MSPAgentInstructions.defaultApplicationContext],
                environmentNotes: environmentNotes(),
                tools: toolDefinitions,
                toolChoice: "auto",
                reasoningEffort: configuration.reasoningEffort,
                textVerbosity: configuration.verbosity,
                store: false,
                stream: true,
                parallelToolCalls: false,
                include: reasoningInclude(for: configuration),
                promptCacheKey: Self.promptCacheKey(toolDefinitions: toolDefinitions)
            )
        )
        activeConversation = conversation
        activeConversationSignature = signature
        return conversation
    }

    private func environmentNotes() -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone.current
        return [
            "Execution surface: Linux workspace.",
            "Workspace root visible to you: /",
            "Treat / as the Linux workspace root for all file and command work.",
            "Do not ask the user to type shell commands. Use exec_command yourself when workspace inspection or file operations are needed.",
            "Use workspace paths such as /, /notes, or /documents.",
            "Current date: \(formatter.string(from: Date()))",
            "Timezone: \(TimeZone.current.identifier)"
        ]
    }

    static func toolDefinitions(applyPatchEnabled: Bool) -> [MSPAgentModelToolDefinition] {
        MSPAgentRequestBuilder.toolDefinitions(includeApplyPatch: applyPatchEnabled)
    }

    static func promptCacheKey(toolDefinitions: [MSPAgentModelToolDefinition]) -> String {
        let names = toolDefinitions
            .map(\.name)
            .sorted()
            .joined(separator: ",")
        return "model-shell-proxy-ios-v2:\(names)"
    }

    private static func makeApplyPatchExecutor(
        workspaceURL: URL,
        environment: [String: String]
    ) throws -> (any MSPApplyPatchExecuting)? {
        #if os(iOS)
        return try MSPCodexApplyPatchRuntime.makeLinkedExecutor(
            workspaceRoot: workspaceURL.path,
            cwd: "/",
            hostPathRedactions: [workspaceURL.path]
        )
        #else
        guard let libraryPath = environment["MSP_PLAYGROUND_APPLY_PATCH_DYLIB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !libraryPath.isEmpty else {
            return nil
        }
        return try MSPCodexApplyPatchRuntime.makeDynamicLibraryExecutor(
            libraryPath: libraryPath,
            workspaceRoot: workspaceURL.path,
            cwd: "/",
            hostPathRedactions: [workspaceURL.path]
        )
        #endif
    }

    private func reasoningInclude(for configuration: MSPModelConfiguration) -> [String] {
        let effort = configuration.reasoningEffort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !effort.isEmpty, effort != "none" else {
            return []
        }
        return ["reasoning.encrypted_content"]
    }

    private struct ConversationSignature: Equatable {
        var modelConfiguration: MSPModelConfiguration
        var credentialSource: MSPModelCredentialSource
        var additionalHTTPHeaders: [String: String]
    }
}
