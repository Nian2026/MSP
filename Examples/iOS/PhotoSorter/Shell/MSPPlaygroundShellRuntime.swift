import CoreGraphics
import Foundation
import ModelShellProxy
import MSPApple
import MSPChatCommands
import MSPCore
import MSPPythonEmbeddedRuntime

struct MSPPlaygroundShellRun: Equatable {
    var command: String
    var renderedText: String
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

@MainActor
final class MSPPlaygroundShellRuntime {
    private let photoLibraryMount: PhotoLibraryMount
    private let diagnosticsLog: PhotoSorterDiagnosticsLog
    private let workspace: PhotoSorterWorkspace
    private let commandExecutor: MSPPlaygroundShellCommandExecutor
    private let thumbnailCache = WorkspaceFileThumbnailCache()

    init(
        workspaceURL: URL,
        photoLibraryMount: PhotoLibraryMount,
        agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding,
        sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding = PhotoSorterSensitiveReadPolicyState(),
        mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)? = nil,
        diagnosticsLog: PhotoSorterDiagnosticsLog = .shared,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.photoLibraryMount = photoLibraryMount
        self.diagnosticsLog = diagnosticsLog
        let workspace = PhotoSorterWorkspace(
            localWorkspaceURL: workspaceURL,
            photoLibraryMount: photoLibraryMount,
            usesPresentationPhotoLibraryReads: true
        )
        self.workspace = workspace
        self.commandExecutor = try MSPPlaygroundShellCommandExecutor(
            workspaceURL: workspaceURL,
            workspace: workspace,
            photoLibraryMount: photoLibraryMount,
            agentAccessModeProvider: agentAccessModeProvider,
            sensitiveReadPolicyProvider: sensitiveReadPolicyProvider,
            mediaViewAuthorizer: mediaViewAuthorizer,
            diagnosticsLog: diagnosticsLog,
            arguments: arguments,
            environment: environment
        )
    }

    func run(_ command: String) async -> MSPPlaygroundShellRun {
        await commandExecutor.run(command)
    }

    func execCommandBridge() -> MSPExecCommandBridge {
        commandExecutor.execCommandBridge()
    }

    nonisolated static func withMediaLiveBudgets<T>(
        operation: () async throws -> T
    ) async rethrows -> T {
        try await MSPPlaygroundShellCommandExecutor.withMediaLiveBudgets(operation: operation)
    }

    func snapshotWorkspace(
        path: String = "/",
        maxDepth: Int = 1,
        maxEntriesPerDirectory: Int? = nil
    ) throws -> [WorkspaceFileNode] {
        try WorkspaceFileNode.loadChildren(
            path: path,
            remainingDepth: maxDepth
        ) { childPath in
            try workspace.photoLibraryFileSystem.listDirectoryForPresentation(
                childPath,
                from: "/",
                offset: 0,
                limit: maxEntriesPerDirectory
            )
        }
    }

    func snapshotWorkspacePage(
        path: String,
        offset: Int,
        limit: Int
    ) async throws -> WorkspaceDirectoryPage {
        let safeLimit = max(limit, 0)
        guard safeLimit > 0 else {
            return WorkspaceDirectoryPage(nodes: [], hasMore: false)
        }

        let fileSystem = workspace.photoLibraryFileSystem
        let safeOffset = max(offset, 0)
        return try await Task.detached(priority: .userInitiated) {
            let entries = try fileSystem.listDirectoryForPresentation(
                path,
                from: "/",
                offset: safeOffset,
                limit: safeLimit + 1
            )
            let visibleEntries = Array(entries.prefix(safeLimit))
            return WorkspaceDirectoryPage(
                nodes: visibleEntries.map(Self.workspaceNode),
                hasMore: entries.count > safeLimit
            )
        }.value
    }

    func snapshotWorkspaceTrash(maxEntries: Int? = nil) throws -> [WorkspaceFileNode] {
        try workspace.photoLibraryFileSystem.listWorkspaceTrashForPresentation(limit: maxEntries)
            .map(Self.workspaceNode)
    }

    func preview(for virtualPath: String) async -> PhotoLibraryMount.PreviewResult {
        await photoLibraryMount.preview(for: virtualPath)
    }

    func quickLookURL(for virtualPath: String) -> URL? {
        guard let info = try? workspace.photoLibraryFileSystem.stat(virtualPath, from: "/"),
              info.type == .regularFile,
              let physicalPath = try? workspace.photoLibraryFileSystem.resolve(virtualPath, from: "/").physicalPath
        else {
            return nil
        }
        return URL(fileURLWithPath: physicalPath)
    }

    func removeWorkspaceItem(_ virtualPath: String, recursive: Bool) throws {
        try workspace.photoLibraryFileSystem.remove(virtualPath, from: "/", recursive: recursive)
    }

    func emptyWorkspaceTrash(authorization: MSPWorkspaceTrashEmptyAuthorization) throws -> Int {
        try workspace.photoLibraryFileSystem.emptyWorkspaceTrash(authorization: authorization)
    }

    func restoreWorkspaceTrash(at displayPath: String) throws -> [MSPWorkspaceTrashRestoreSummary] {
        try workspace.photoLibraryFileSystem.restoreWorkspaceTrash(at: displayPath)
    }

    func restoreAllWorkspaceTrash() throws -> [MSPWorkspaceTrashRestoreSummary] {
        try workspace.photoLibraryFileSystem.restoreAllWorkspaceTrash()
    }

    func localWorkspaceURL(for virtualPath: String) -> URL? {
        guard let physicalPath = try? workspace.photoLibraryFileSystem.resolve(virtualPath, from: "/").physicalPath else {
            return nil
        }
        return URL(fileURLWithPath: physicalPath)
    }

    func thumbnail(
        for node: WorkspaceFileNode,
        targetSize: CGSize,
        cacheVersion: String
    ) async -> WorkspaceFileThumbnail? {
        guard node.mediaKind != nil else {
            return nil
        }

        let cacheKey = Self.thumbnailCacheKey(
            for: node,
            targetSize: targetSize,
            cacheVersion: cacheVersion
        )
        if let thumbnail = await thumbnailCache.thumbnail(for: cacheKey) {
            return thumbnail
        }

        let thumbnail: WorkspaceFileThumbnail?
        if let physicalPath = try? workspace.photoLibraryFileSystem.resolve(node.path, from: "/").physicalPath {
            thumbnail = await WorkspaceLocalMediaThumbnailGenerator.thumbnail(
                for: URL(fileURLWithPath: physicalPath),
                targetSize: targetSize
            )
        } else {
            thumbnail = await photoLibraryMount.thumbnail(for: node.path, targetSize: targetSize)
        }

        if let thumbnail {
            await thumbnailCache.store(thumbnail, for: cacheKey)
        }
        return thumbnail
    }

    nonisolated private static func workspaceNode(from entry: MSPDirectoryEntry) -> WorkspaceFileNode {
        WorkspaceFileNode(
            name: entry.name,
            path: entry.virtualPath,
            type: entry.type,
            size: entry.info.size,
            modificationDate: entry.info.modificationDate,
            mediaKind: entry.type == .regularFile
                ? WorkspaceFileMediaKind.inferred(fromFileName: entry.name)
                : nil,
            children: nil
        )
    }

    static func thumbnailCacheKey(
        for node: WorkspaceFileNode,
        targetSize: CGSize,
        cacheVersion: String
    ) -> String {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        let modifiedMilliseconds = node.modificationDate
            .map { Int($0.timeIntervalSince1970 * 1000) }
            .map(String.init) ?? ""
        let size = node.size.map(String.init) ?? ""
        return [
            node.path,
            node.mediaKind?.rawValue ?? "",
            cacheVersion,
            "\(width)x\(height)",
            modifiedMilliseconds,
            size
        ].joined(separator: "|")
    }

}

actor MSPPlaygroundShellCommandExecutor {
    private let photoLibraryMount: PhotoLibraryMount
    private let diagnosticsLog: PhotoSorterDiagnosticsLog
    private let shell: ModelShellProxy
    nonisolated private let sessionExecCommandBridge: MSPExecCommandBridge

    init(
        workspaceURL: URL,
        workspace: PhotoSorterWorkspace,
        photoLibraryMount: PhotoLibraryMount,
        agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding,
        sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding,
        mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)?,
        diagnosticsLog: PhotoSorterDiagnosticsLog,
        arguments: [String],
        environment: [String: String]
    ) throws {
        self.photoLibraryMount = photoLibraryMount
        self.diagnosticsLog = diagnosticsLog
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore(excluding: Self.excludedPOSIXCommandNames))
            .enable(MSPChatCommandPack())
            .enable(PhotoSorterCommandPack(
                photoLibraryMount: photoLibraryMount,
                agentAccessModeProvider: agentAccessModeProvider,
                sensitiveReadPolicyProvider: sensitiveReadPolicyProvider,
                mediaViewAuthorizer: mediaViewAuthorizer
            ))
        try shell.enable(.python(runtime: PhotoSorterPythonRuntimeProvider.runtime(
            workspaceURL: workspaceURL,
            arguments: arguments,
            environment: environment
        )))
        self.shell = shell
        self.sessionExecCommandBridge = shell.execCommandBridge()
    }

    init(
        shell: ModelShellProxy,
        photoLibraryMount: PhotoLibraryMount = PhotoLibraryMount(),
        diagnosticsLog: PhotoSorterDiagnosticsLog = .shared
    ) {
        self.photoLibraryMount = photoLibraryMount
        self.diagnosticsLog = diagnosticsLog
        self.shell = shell
        self.sessionExecCommandBridge = shell.execCommandBridge()
    }

    private static let excludedPOSIXCommandNames: Set<String> = [
        "b2sum",
        "cksum",
        "cmp",
        "dd",
        "diff",
        "md5sum",
        "rm",
        "sha1sum",
        "sha256sum",
        "sha512sum",
        "strings",
        "sum",
        "xxd"
    ]

    func run(_ command: String) async -> MSPPlaygroundShellRun {
        let result = await runDirectCommand(command)
        return MSPPlaygroundShellRun(
            command: command,
            renderedText: MSPExecCommandRenderer.renderAgentText(from: result),
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode
        )
    }

    nonisolated func execCommandBridge() -> MSPExecCommandBridge {
        sessionExecCommandBridge
    }

    func run(
        _ call: MSPExecCommandCall,
        outputHandler: MSPExecCommandOutputHandler?
    ) async -> MSPCommandResult {
        let cmd = call.cmd
        let startedAt = Date()
        let signpost = PhotoSorterDiagnosticsSystemLog.beginInterval(
            "ShellCommand",
            fields: ["cmd": cmd]
        )
        let indexStatusAtStart = photoLibraryMount.photoLibraryIndexStatus
        await diagnosticsLog.record("shell_command_start", fields: [
            "cmd": cmd
        ].merging(Self.indexStatusFields(indexStatusAtStart, prefix: "photo_library_index_start")) { _, fresh in fresh })
        let stdoutCoalescer = MSPPlaygroundShellOutputCoalescer(
            stream: .stdout,
            command: cmd,
            startedAt: startedAt,
            diagnosticsLog: diagnosticsLog,
            outputHandler: outputHandler
        )
        let stderrCoalescer = MSPPlaygroundShellOutputCoalescer(
            stream: .stderr,
            command: cmd,
            startedAt: startedAt,
            diagnosticsLog: diagnosticsLog,
            outputHandler: outputHandler
        )
        let stdoutStream = Self.outputStream(coalescer: stdoutCoalescer)
        let stderrStream = Self.outputStream(coalescer: stderrCoalescer)
        await Self.recordProbe(
            diagnosticsLog,
            "probe_shell_bridge_run_before",
            command: cmd,
            startedAt: startedAt
        )
        let result = await Self.withMediaLiveBudgets {
            await photoLibraryMount.withForegroundPhotoLibraryActivity {
                await shell.run(
                    cmd,
                    outputStream: stdoutStream,
                    errorStream: stderrStream
                )
            }
        }
        await Self.recordProbe(
            diagnosticsLog,
            "probe_shell_bridge_run_after",
            command: cmd,
            startedAt: startedAt,
            fields: [
                "exit_code": "\(result.exitCode)",
                "stdout_bytes": "\(result.stdoutData.count)",
                "stderr_bytes": "\(result.stderrData.count)"
            ]
        )
        await stdoutCoalescer.flush()
        await stderrCoalescer.flush()
        let indexStatusAtEnd = photoLibraryMount.photoLibraryIndexStatus
        let finishFields = Self.shellResultFields(
            command: cmd,
            stdout: result.stdout,
            stderr: result.stderr,
            stdoutDataCount: result.stdoutData.count,
            stderrDataCount: result.stderrData.count,
            exitCode: result.exitCode,
            startedAt: startedAt,
            extraFields: Self.indexStatusFields(
                indexStatusAtStart,
                prefix: "photo_library_index_start"
            ).merging(Self.indexStatusFields(indexStatusAtEnd, prefix: "photo_library_index_end")) { _, fresh in fresh }
        )
        await diagnosticsLog.record("shell_command_finish", fields: finishFields)
        PhotoSorterDiagnosticsSystemLog.endInterval(signpost, fields: finishFields)
        await Self.recordProbe(
            diagnosticsLog,
            "probe_shell_bridge_finish_record_after",
            command: cmd,
            startedAt: startedAt
        )
        return result
    }

    private func runDirectCommand(_ command: String) async -> MSPCommandResult {
        let startedAt = Date()
        let signpost = PhotoSorterDiagnosticsSystemLog.beginInterval(
            "ShellDirectRun",
            fields: ["cmd": command]
        )
        let indexStatusAtStart = photoLibraryMount.photoLibraryIndexStatus
        await diagnosticsLog.record("shell_direct_run_start", fields: [
            "cmd": command
        ].merging(Self.indexStatusFields(indexStatusAtStart, prefix: "photo_library_index_start")) { _, fresh in fresh })
        let result = await Self.withMediaLiveBudgets {
            await photoLibraryMount.withForegroundPhotoLibraryActivity {
                await shell.run(command)
            }
        }
        let indexStatusAtEnd = photoLibraryMount.photoLibraryIndexStatus
        let finishFields = Self.shellResultFields(
            command: command,
            stdout: result.stdout,
            stderr: result.stderr,
            stdoutDataCount: result.stdoutData.count,
            stderrDataCount: result.stderrData.count,
            exitCode: result.exitCode,
            startedAt: startedAt,
            extraFields: Self.indexStatusFields(
                indexStatusAtStart,
                prefix: "photo_library_index_start"
            ).merging(Self.indexStatusFields(indexStatusAtEnd, prefix: "photo_library_index_end")) { _, fresh in fresh }
        )
        await diagnosticsLog.record("shell_direct_run_finish", fields: finishFields)
        PhotoSorterDiagnosticsSystemLog.endInterval(signpost, fields: finishFields)
        return result
    }

    static func withMediaLiveBudgets<T>(
        operation: () async throws -> T
    ) async rethrows -> T {
        try await PhotoSorterMediaLiveOCRBudget.withBudget {
            try await PhotoSorterMediaLiveVLMBudget.withBudget {
                try await operation()
            }
        }
    }

    nonisolated private static func shellResultFields(
        command: String,
        stdout: String,
        stderr: String,
        stdoutDataCount: Int,
        stderrDataCount: Int,
        exitCode: Int32,
        startedAt: Date,
        extraFields: [String: String] = [:]
    ) -> [String: String] {
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        return [
            "cmd": command,
            "exit_code": "\(exitCode)",
            "stdout_bytes": "\(stdoutDataCount)",
            "stderr_bytes": "\(stderrDataCount)",
            "stdout_text_length": "\(stdout.count)",
            "stderr_text_length": "\(stderr.count)",
            "stdout_preview": diagnosticPreview(stdout),
            "stderr_preview": diagnosticPreview(stderr),
            "duration_ms": "\(durationMilliseconds)"
        ].merging(extraFields) { _, fresh in fresh }
    }

    nonisolated private static func indexStatusFields(
        _ status: PhotoLibraryIndexStatus,
        prefix: String
    ) -> [String: String] {
        var fields: [String: String] = [
            "\(prefix)_phase": status.phase.rawValue,
            "\(prefix)_processed": "\(status.processed)",
            "\(prefix)_version": "\(status.version)"
        ]
        if let total = status.total {
            fields["\(prefix)_total"] = "\(total)"
        }
        if let currentPath = status.currentPath {
            fields["\(prefix)_current_path"] = currentPath
        }
        if let message = status.message {
            fields["\(prefix)_message"] = message
        }
        return fields
    }

    nonisolated private static func diagnosticPreview(_ text: String, limit: Int = 200) -> String {
        guard text.count > limit else {
            return text
        }
        return "\(text.prefix(limit))…"
    }

    nonisolated private static func outputStream(
        coalescer: MSPPlaygroundShellOutputCoalescer
    ) -> any MSPCommandOutputStream {
        MSPClosureOutputStream { data in
            guard !data.isEmpty else {
                return
            }
            await coalescer.append(data)
        } closeHandler: {
            await coalescer.flush()
        }
    }

    private static func recordProbe(
        _ diagnosticsLog: PhotoSorterDiagnosticsLog,
        _ event: String,
        command: String,
        startedAt: Date,
        fields: [String: String] = [:]
    ) async {
        var merged = fields
        merged["cmd"] = command
        merged["elapsed_ms"] = "\(max(0, Int(Date().timeIntervalSince(startedAt) * 1000)))"
        await diagnosticsLog.record(event, fields: merged)
    }
}

enum PhotoSorterPythonRuntimeProvider {
    static func runtime(
        workspaceURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> any MSPPythonRuntime {
        guard let libraryURL = cpythonLibraryURL(arguments: arguments, environment: environment) else {
            return unavailableRuntime(reason: "CPython library is not configured")
        }
        do {
            let engine = try MSPCPythonEngine(
                library: .path(libraryURL),
                workspaceRootURL: workspaceURL,
                pythonHomeURL: cpythonHomeURL(arguments: arguments, environment: environment)
            )
            return MSPPythonEmbeddedRuntime(engine: engine)
        } catch {
            return unavailableRuntime(reason: "\(error)")
        }
    }

    private static func unavailableRuntime(reason: String) -> any MSPPythonRuntime {
        MSPPythonEmbeddedRuntime(engine: PhotoSorterUnavailablePythonEngine(reason: reason))
    }

    private static func cpythonLibraryURL(
        arguments: [String],
        environment: [String: String]
    ) -> URL? {
        if let path = argumentValue(named: "--msp-cpython-library-path", in: arguments)
            ?? environment["MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH"]
            ?? environment["MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH"] {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        let bundledURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Python.framework")
            .appendingPathComponent("Python")
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else {
            return nil
        }
        return bundledURL
    }

    private static func cpythonHomeURL(
        arguments: [String],
        environment: [String: String]
    ) -> URL? {
        if let path = argumentValue(named: "--msp-cpython-home", in: arguments)
            ?? environment["MSP_PHOTOSORTER_CPYTHON_HOME"]
            ?? environment["MSP_PLAYGROUND_CPYTHON_HOME"] {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("python")
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else {
            return nil
        }
        return bundledURL
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
}

private struct PhotoSorterUnavailablePythonEngine: MSPPythonEmbeddedEngine {
    var reason: String

    func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        throw MSPPythonEmbeddedRuntimeError.engineUnavailable(reason)
    }
}

actor MSPPlaygroundShellOutputCoalescer {
    private let stream: MSPExecCommandOutputStreamName
    private let command: String
    private let startedAt: Date
    private let diagnosticsLog: PhotoSorterDiagnosticsLog
    private let outputHandler: MSPExecCommandOutputHandler?
    private let flushThresholdBytes = 64 * 1024
    private let flushIntervalNanoseconds: UInt64 = 250_000_000
    private var buffer = Data()
    private var scheduledFlushTask: Task<Void, Never>?

    init(
        stream: MSPExecCommandOutputStreamName,
        outputHandler: MSPExecCommandOutputHandler?
    ) {
        self.init(
            stream: stream,
            command: "",
            startedAt: Date(),
            diagnosticsLog: .shared,
            outputHandler: outputHandler
        )
    }

    init(
        stream: MSPExecCommandOutputStreamName,
        command: String,
        startedAt: Date,
        diagnosticsLog: PhotoSorterDiagnosticsLog,
        outputHandler: MSPExecCommandOutputHandler?
    ) {
        self.stream = stream
        self.command = command
        self.startedAt = startedAt
        self.diagnosticsLog = diagnosticsLog
        self.outputHandler = outputHandler
    }

    func append(_ data: Data) async {
        guard !data.isEmpty else {
            return
        }
        buffer.append(data)
        if buffer.count >= flushThresholdBytes {
            await recordProbe("probe_shell_coalescer_flush_triggered", fields: [
                "bytes": "\(data.count)",
                "buffer_bytes": "\(buffer.count)"
            ])
            await flush(cancelScheduledFlush: true)
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        guard scheduledFlushTask == nil else {
            return
        }
        let delay = flushIntervalNanoseconds
        scheduledFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.flushFromScheduledTask()
        }
    }

    private func flushFromScheduledTask() async {
        scheduledFlushTask = nil
        await flush(cancelScheduledFlush: false)
    }

    func flush() async {
        await flush(cancelScheduledFlush: true)
    }

    private func flush(cancelScheduledFlush: Bool) async {
        if cancelScheduledFlush {
            scheduledFlushTask?.cancel()
            scheduledFlushTask = nil
        }
        guard !buffer.isEmpty else {
            await recordProbe("probe_shell_coalescer_flush_empty")
            return
        }
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            await recordProbe("probe_shell_coalescer_flush_empty_text", fields: [
                "bytes": "\(data.count)"
            ])
            return
        }
        await recordProbe("probe_shell_coalescer_output_handler_before", fields: [
            "bytes": "\(data.count)",
            "text_length": "\(text.count)"
        ])
        await outputHandler?(MSPExecCommandOutputEvent(stream: stream, text: text))
        await recordProbe("probe_shell_coalescer_output_handler_after", fields: [
            "bytes": "\(data.count)",
            "text_length": "\(text.count)"
        ])
    }

    func recordProbe(_ event: String, fields: [String: String] = [:]) async {
        var merged = fields
        merged["cmd"] = command
        merged["stream"] = stream.rawValue
        merged["elapsed_ms"] = "\(max(0, Int(Date().timeIntervalSince(startedAt) * 1000)))"
        await diagnosticsLog.record(event, fields: merged)
    }
}
