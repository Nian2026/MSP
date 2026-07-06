import Foundation
import MSPCore

enum MSPAgentRuntimeToolExecutor {
    static func execute(
        _ call: MSPAgentToolCall,
        bridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        onOutput: MSPExecCommandOutputHandler? = nil,
        probe: (@Sendable (MSPAgentProbeEvent) async -> Void)? = nil
    ) async -> MSPAgentToolResult {
        if call.name == .applyPatch {
            return await executeApplyPatchToolCall(
                call,
                executor: applyPatchExecutor,
                probe: probe
            )
        }
        if call.name == .writeStdin {
            return await executeWriteStdinToolCall(
                call,
                bridge: bridge,
                onOutput: onOutput,
                probe: probe
            )
        }
        guard call.name == .execCommand else {
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                outputKind: call.outputKind,
                ok: false,
                content: .string("unsupported tool: \(call.name.rawValue)"),
                errorMessage: "unsupported tool"
            )
        }

        let execCall: MSPExecCommandCall
        do {
            execCall = try MSPExecCommandCall(arguments: call.arguments)
        } catch let error as MSPExecCommandCallError {
            let message = modelVisibleExecCommandArgumentError(error)
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                ok: false,
                content: .string(message),
                errorMessage: message
            )
        } catch {
            let message = "exec_command arguments are invalid"
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                ok: false,
                content: .string(message),
                errorMessage: message
            )
        }
        let command = execCall.cmd
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                ok: false,
                content: .string("workspace command is missing"),
                errorMessage: "missing command"
            )
        }

        let startedAt = Date()
        await probe?(MSPAgentProbeEvent(
            name: "probe_agent_runtime_bridge_run_before",
            fields: [
                "call_id": call.id,
                "name": call.name.rawValue,
                "cmd": command,
                "tty": "\(execCall.tty)",
                "yield_time_ms": execCall.yieldTimeMilliseconds.map(String.init) ?? ""
            ]
        ))
        let read = await bridge.runSession(execCall, onOutput: onOutput)
        let elapsed = read.wallTimeSeconds > 0
            ? read.wallTimeSeconds
            : Date().timeIntervalSince(startedAt)
        let result = read.result
        let isRunning = read.runningSessionID != nil
        let resolvedExitCode = read.exitCode ?? result.exitCode
        await probe?(MSPAgentProbeEvent(
            name: "probe_agent_runtime_bridge_run_after",
            fields: [
                "call_id": call.id,
                "name": call.name.rawValue,
                "cmd": command,
                "elapsed_ms": "\(Int(elapsed * 1000))",
                "exit_code": isRunning ? "" : "\(resolvedExitCode)",
                "signal": read.signal.map(String.init) ?? "",
                "session_id": read.runningSessionID.map(String.init) ?? "",
                "running_session_id": read.runningSessionID.map(String.init) ?? "",
                "yield_time_ms": execCall.yieldTimeMilliseconds.map(String.init) ?? "",
                "stdout_bytes": "\(result.stdoutData.count)",
                "stderr_bytes": "\(result.stderrData.count)",
                "stderr_preview": diagnosticPreview(result.stderr)
            ]
        ))
        let text = MSPExecCommandRenderer.renderAgentText(
            from: read,
            options: MSPExecCommandRenderOptions(
                maxOutputTokens: execCall.maxOutputTokens
            )
        )
        let modelOutputContent = modelOutputContent(
            renderedText: text,
            modelContentItems: result.modelContentItems
        )
        var internalContent: [String: MSPAgentJSONValue] = [
            "cmd": .string(command),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exit_code": isRunning ? .null : .number(Double(resolvedExitCode)),
            "running_session_id": read.runningSessionID.map { .number(Double($0)) } ?? .null
        ]
        if let sessionID = read.runningSessionID {
            internalContent["session_id"] = .number(Double(sessionID))
        }
        return MSPAgentToolResult(
            callID: call.id,
            name: call.name,
            ok: isRunning
                ? result.exitCode == 0
                : resolvedExitCode == 0,
            content: .string(text),
            internalContent: .object(internalContent),
            modelOutputContent: modelOutputContent,
            errorMessage: (!isRunning && resolvedExitCode != 0) ? text : nil
        )
    }

    private static func executeApplyPatchToolCall(
        _ call: MSPAgentToolCall,
        executor: (any MSPApplyPatchExecuting)?,
        probe: (@Sendable (MSPAgentProbeEvent) async -> Void)? = nil
    ) async -> MSPAgentToolResult {
        let patch = call.input ?? ""
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "apply_patch input is missing"
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                outputKind: .custom,
                ok: false,
                content: .string(message),
                errorMessage: message
            )
        }
        guard let executor else {
            let message = "apply_patch runtime is not configured"
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                outputKind: .custom,
                ok: false,
                content: .string(message),
                errorMessage: message
            )
        }

        await probe?(MSPAgentProbeEvent(
            name: "probe_agent_runtime_apply_patch_before",
            fields: [
                "call_id": call.id,
                "name": call.name.rawValue,
                "patch_bytes": "\(patch.utf8.count)"
            ]
        ))
        let result = await executor.execute(MSPApplyPatchCall(
            callID: call.id,
            patch: patch
        ))
        await probe?(MSPAgentProbeEvent(
            name: "probe_agent_runtime_apply_patch_after",
            fields: [
                "call_id": call.id,
                "name": call.name.rawValue,
                "ok": "\(result.ok)",
                "changed_path_count": "\(result.changedPaths.count)"
            ]
        ))
        var internalContent = result.internalContent?.objectValue ?? [:]
        internalContent["changed_paths"] = .array(result.changedPaths.map { .string($0) })
        if let exactDelta = result.exactDelta {
            internalContent["exact_delta"] = .bool(exactDelta)
        }
        return MSPAgentToolResult(
            callID: call.id,
            name: call.name,
            outputKind: .custom,
            ok: result.ok,
            content: .string(result.output),
            internalContent: .object(internalContent),
            modelOutputContent: result.modelOutputContent,
            errorMessage: result.errorMessage
        )
    }

    private static func executeWriteStdinToolCall(
        _ call: MSPAgentToolCall,
        bridge: MSPExecCommandBridge,
        onOutput: MSPExecCommandOutputHandler? = nil,
        probe: (@Sendable (MSPAgentProbeEvent) async -> Void)? = nil
    ) async -> MSPAgentToolResult {
        let writeCall: MSPWriteStdinCall
        do {
            writeCall = try MSPWriteStdinCall(arguments: call.arguments)
        } catch let error as MSPWriteStdinCallError {
            let message = modelVisibleWriteStdinArgumentError(error)
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                ok: false,
                content: .string(message),
                errorMessage: message
            )
        } catch {
            let message = "write_stdin arguments are invalid"
            return MSPAgentToolResult(
                callID: call.id,
                name: call.name,
                ok: false,
                content: .string(message),
                errorMessage: message
            )
        }

        await probe?(MSPAgentProbeEvent(
            name: "probe_agent_runtime_bridge_write_stdin_before",
            fields: [
                "call_id": call.id,
                "name": call.name.rawValue,
                "session_id": "\(writeCall.sessionID)",
                "chars_kind": writeStdinCharsKind(writeCall.chars),
                "chars_length": "\(writeCall.chars.count)",
                "yield_time_ms": writeCall.yieldTimeMilliseconds.map(String.init) ?? ""
            ]
        ))
        let read = await bridge.writeStdin(writeCall, onOutput: onOutput)
        let result = read.result
        let isRunning = read.runningSessionID != nil
        let resolvedExitCode = read.exitCode ?? result.exitCode
        await probe?(MSPAgentProbeEvent(
            name: "probe_agent_runtime_bridge_write_stdin_after",
            fields: [
                "call_id": call.id,
                "name": call.name.rawValue,
                "session_id": "\(writeCall.sessionID)",
                "running_session_id": read.runningSessionID.map(String.init) ?? "",
                "exit_code": isRunning ? "" : "\(resolvedExitCode)",
                "signal": read.signal.map(String.init) ?? "",
                "chars_kind": writeStdinCharsKind(writeCall.chars),
                "chars_length": "\(writeCall.chars.count)",
                "yield_time_ms": writeCall.yieldTimeMilliseconds.map(String.init) ?? "",
                "stdout_bytes": "\(result.stdoutData.count)",
                "stderr_bytes": "\(result.stderrData.count)",
                "stderr_preview": diagnosticPreview(result.stderr)
            ]
        ))
        let text = MSPExecCommandRenderer.renderAgentText(
            from: read,
            options: MSPExecCommandRenderOptions(maxOutputTokens: writeCall.maxOutputTokens)
        )
        let isOK = isRunning
            ? result.exitCode == 0
            : resolvedExitCode == 0
        return MSPAgentToolResult(
            callID: call.id,
            name: call.name,
            ok: isOK,
            content: .string(text),
            internalContent: .object([
                "session_id": .number(Double(writeCall.sessionID)),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr),
                "exit_code": isRunning ? .null : .number(Double(resolvedExitCode)),
                "running_session_id": read.runningSessionID.map { .number(Double($0)) } ?? .null
            ]),
            modelOutputContent: modelOutputContent(
                renderedText: text,
                modelContentItems: result.modelContentItems
            ),
            errorMessage: isOK ? nil : text
        )
    }

    private static func modelVisibleExecCommandArgumentError(
        _ error: MSPExecCommandCallError
    ) -> String {
        switch error {
        case .missingCommand:
            return "exec_command arguments missing cmd"
        case .invalidMaxOutputTokens:
            return "exec_command max_output_tokens must be a non-negative integer"
        case .invalidYieldTimeMilliseconds:
            return "exec_command yield_time_ms must be a non-negative integer"
        case .invalidTTY:
            return "exec_command tty must be a boolean"
        case .invalidArgumentKeys, .invalidStringArgument:
            return error.description
        }
    }

    private static func modelVisibleWriteStdinArgumentError(
        _ error: MSPWriteStdinCallError
    ) -> String {
        switch error {
        case .invalidSessionID:
            return "write_stdin arguments missing valid session_id"
        case .invalidMaxOutputTokens:
            return "write_stdin max_output_tokens must be a non-negative integer"
        case .invalidYieldTimeMilliseconds:
            return "write_stdin yield_time_ms must be a non-negative integer"
        case .invalidChars:
            return "write_stdin chars must be a string"
        case .invalidArgumentKeys:
            return error.description
        }
    }

    private static func writeStdinCharsKind(_ chars: String) -> String {
        if chars.isEmpty {
            return "empty_poll"
        }
        if chars == "\u{3}" {
            return "interrupt"
        }
        if chars == "\u{4}" {
            return "eof"
        }
        return "input"
    }

    private static func diagnosticPreview(
        _ text: String,
        maximumCharacters: Int = 240
    ) -> String {
        guard text.count > maximumCharacters else {
            return text
        }
        return String(text.prefix(maximumCharacters))
    }

    private static func modelOutputContent(
        renderedText: String,
        modelContentItems: [MSPCommandModelContentItem]
    ) -> MSPAgentJSONValue? {
        guard !modelContentItems.isEmpty else {
            return nil
        }
        var items: [MSPAgentJSONValue] = [
            .object([
                "type": .string("input_text"),
                "text": .string(renderedText)
            ])
        ]
        for item in modelContentItems {
            if let json = modelContentItemJSON(item) {
                items.append(json)
            }
        }
        return items.count > 1 ? .array(items) : nil
    }

    private static func modelContentItemJSON(_ item: MSPCommandModelContentItem) -> MSPAgentJSONValue? {
        switch item.kind {
        case .inputText:
            guard let text = item.text else {
                return nil
            }
            return .object([
                "type": .string("input_text"),
                "text": .string(text)
            ])
        case .inputImage:
            guard let data = item.data,
                  !data.isEmpty else {
                return nil
            }
            let mimeType = item.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMimeType = mimeType?.isEmpty == false ? mimeType! : "image/jpeg"
            var object: [String: MSPAgentJSONValue] = [
                "type": .string("input_image"),
                "image_url": .string("data:\(resolvedMimeType);base64,\(data.base64EncodedString())")
            ]
            if let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                object["detail"] = .string(detail)
            }
            return .object(object)
        }
    }

}
