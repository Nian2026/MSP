#if os(macOS)
import Foundation
import MSPCore

public struct MSPPythonHostProcessRuntime: MSPPythonRuntime {
    public var executableURL: URL
    public var workspaceRootURL: URL
    public var temporaryDirectoryURL: URL
    public var timeout: TimeInterval
    public var keepsTemporaryDirectories: Bool

    public init(
        executableURL: URL,
        workspaceRootURL: URL,
        temporaryDirectoryURL: URL? = nil,
        timeout: TimeInterval = 30,
        keepsTemporaryDirectories: Bool = false
    ) {
        self.executableURL = executableURL
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.temporaryDirectoryURL = (
            temporaryDirectoryURL
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("MSPPythonHostProcessRuntime")
        ).standardizedFileURL
        self.timeout = timeout
        self.keepsTemporaryDirectories = keepsTemporaryDirectories
    }

    public func runPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        await runPreparedPython(request: request, context: context, streamsEnabled: false)
    }

    public func runPythonStreaming(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard !request.entrypoint.requiresBufferedStandardInputSource else {
            do {
                let bufferedContext = try await MSPPythonStreamingRuntimeSupport
                    .contextByBufferingStandardInputStream(context)
                return await runPython(request: request, context: bufferedContext)
            } catch {
                return .failure(
                    exitCode: 1,
                    stderr: "\(request.invocation.commandName): \(error)\n"
                )
            }
        }
        return await runPreparedPython(request: request, context: context, streamsEnabled: true)
    }

    private func runPreparedPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext,
        streamsEnabled: Bool
    ) async -> MSPCommandResult {
        do {
            var processContext = context
            if !streamsEnabled {
                processContext.standardInputStream = nil
                processContext.standardOutputStream = nil
                processContext.standardErrorStream = nil
            }
            let prepared = try prepareProcessPlan(for: request, context: context)
            prepared.subprocessBroker.start()
            prepared.vfsBroker.start()
            defer {
                prepared.vfsBroker.stop()
                prepared.subprocessBroker.stop()
                if !keepsTemporaryDirectories {
                    try? FileManager.default.removeItem(at: prepared.runtimeDirectoryURL)
                }
            }
            let sanitizer = outputPathSanitizer(prepared: prepared)
            return sanitizer.sanitize(
                try await runProcess(
                    prepared.plan,
                    context: processContext,
                    outputSanitizer: sanitizer
                )
            )
        } catch {
            return .failure(exitCode: 1, stderr: "\(request.invocation.commandName): \(error)\n")
        }
    }

    func makeProcessPlan(
        for request: MSPPythonExecutionRequest,
        context: MSPCommandContext,
        launcherURL: URL,
        vfsBrokerDirectoryURL: URL? = nil,
        materializedDirectoryURL: URL? = nil,
        subprocessBrokerDirectoryURL: URL? = nil
    ) throws -> MSPPythonHostProcessPlan {
        let mappedArguments = mappedPythonArguments(for: request)
        return MSPPythonHostProcessPlan(
            executableURL: executableURL,
            arguments: ["-S", launcherURL.path] + mappedArguments,
            currentDirectoryURL: hostURL(forVirtualPath: request.virtualCurrentDirectory, isDirectory: true),
            environment: processEnvironment(
                for: request,
                context: context,
                vfsBrokerDirectoryURL: vfsBrokerDirectoryURL,
                materializedDirectoryURL: materializedDirectoryURL,
                subprocessBrokerDirectoryURL: subprocessBrokerDirectoryURL
            ),
            standardInput: context.standardInput,
            timeout: timeout
        )
    }

    private func prepareProcessPlan(
        for request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) throws -> MSPPythonPreparedHostProcessPlan {
        let runtimeDirectoryURL = temporaryDirectoryURL
            .appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        let launcherURL = runtimeDirectoryURL.appendingPathComponent(MSPPythonLauncherSource.fileName)
        try MSPPythonLauncherSource.source.write(to: launcherURL, atomically: true, encoding: .utf8)
        let vfsBrokerDirectoryURL = runtimeDirectoryURL.appendingPathComponent("vfs-broker", isDirectory: true)
        let materializedDirectoryURL = runtimeDirectoryURL.appendingPathComponent("vfs-materialized", isDirectory: true)
        let subprocessBrokerDirectoryURL = runtimeDirectoryURL.appendingPathComponent(
            "subprocess-broker",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: vfsBrokerDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materializedDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subprocessBrokerDirectoryURL, withIntermediateDirectories: true)
        let vfsBroker = try MSPPythonVirtualFileSystemBroker(
            directoryURL: vfsBrokerDirectoryURL,
            baseContext: context
        )
        let subprocessBroker = try MSPPythonSubprocessBroker(
            directoryURL: subprocessBrokerDirectoryURL,
            baseContext: context
        )
        let plan = try makeProcessPlan(
            for: request,
            context: context,
            launcherURL: launcherURL,
            vfsBrokerDirectoryURL: vfsBrokerDirectoryURL,
            materializedDirectoryURL: materializedDirectoryURL,
            subprocessBrokerDirectoryURL: subprocessBrokerDirectoryURL
        )
        return MSPPythonPreparedHostProcessPlan(
            runtimeDirectoryURL: runtimeDirectoryURL,
            vfsBrokerDirectoryURL: vfsBrokerDirectoryURL,
            materializedDirectoryURL: materializedDirectoryURL,
            subprocessBrokerDirectoryURL: subprocessBrokerDirectoryURL,
            subprocessBroker: subprocessBroker,
            vfsBroker: vfsBroker,
            plan: plan
        )
    }

    private func mappedPythonArguments(for request: MSPPythonExecutionRequest) -> [String] {
        request.invocation.arguments
    }

    private func processEnvironment(
        for request: MSPPythonExecutionRequest,
        context: MSPCommandContext,
        vfsBrokerDirectoryURL: URL?,
        materializedDirectoryURL: URL?,
        subprocessBrokerDirectoryURL: URL?
    ) -> [String: String] {
        var environment = MSPPythonUTF8Environment.applying(to: context.environment)
        if MSPPythonOptionParser.requestsUnbufferedIO(in: request.invocation.arguments) {
            environment["PYTHONUNBUFFERED"] = "1"
        }
        environment["MSP_PYTHON_WORKSPACE_ROOT"] = workspaceRootURL.path
        environment["MSP_PYTHON_VIRTUAL_CWD"] = request.virtualCurrentDirectory
        environment["MSP_PYTHON_VIRTUAL_HOME"] = "/"
        environment["MSP_PYTHON_VIRTUAL_TMPDIR"] = "/tmp"
        environment["MSP_PYTHON_VIRTUAL_PATH"] = "/usr/bin:/bin"
        environment["MSP_PYTHON_FILE_CREATION_MASK"] = String(format: "%03o", context.fileCreationMask)
        if let availableCommands = Self.base64EncodedJSON(context.availableCommandNames) {
            environment["MSP_PYTHON_AVAILABLE_COMMANDS_B64"] = availableCommands
        }
        if let commandLookupPaths = Self.base64EncodedJSON(context.commandLookupPaths) {
            environment["MSP_PYTHON_COMMAND_LOOKUP_PATHS_B64"] = commandLookupPaths
        }
        if let vfsBrokerDirectoryURL {
            environment["MSP_PYTHON_VFS_BROKER_DIR"] = vfsBrokerDirectoryURL.path
        }
        if let materializedDirectoryURL {
            environment["MSP_PYTHON_VFS_MATERIALIZED_DIR"] = materializedDirectoryURL.path
        }
        if let subprocessBrokerDirectoryURL {
            environment["MSP_PYTHON_SUBPROCESS_BROKER_DIR"] = subprocessBrokerDirectoryURL.path
        }
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private static func base64EncodedJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return data.base64EncodedString()
    }

    private func virtualizedOutputResult(
        _ result: MSPCommandResult,
        prepared: MSPPythonPreparedHostProcessPlan
    ) -> MSPCommandResult {
        outputPathSanitizer(prepared: prepared).sanitize(result)
    }

    private func outputPathSanitizer(
        prepared: MSPPythonPreparedHostProcessPlan
    ) -> MSPPythonOutputPathSanitizer {
        MSPPythonOutputPathSanitizer(
            workspaceRootURL: workspaceRootURL,
            runtimeDirectoryMappings: [
                (prepared.vfsBrokerDirectoryURL, "/tmp"),
                (prepared.materializedDirectoryURL, "/tmp"),
                (prepared.subprocessBrokerDirectoryURL, "/tmp"),
                (prepared.runtimeDirectoryURL, "/tmp")
            ]
        )
    }

    private func hostURL(forVirtualPath virtualPath: String, isDirectory: Bool) -> URL {
        let normalized = MSPWorkspacePathResolver.normalize(virtualPath)
        guard normalized != "/" else {
            return workspaceRootURL
        }
        let relative = String(normalized.dropFirst())
        return workspaceRootURL.appendingPathComponent(relative, isDirectory: isDirectory).standardizedFileURL
    }

    private func runProcess(
        _ plan: MSPPythonHostProcessPlan,
        context: MSPCommandContext,
        outputSanitizer: MSPPythonOutputPathSanitizer
    ) async throws -> MSPCommandResult {
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.currentDirectoryURL
        process.environment = plan.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let stdoutBuffer = MSPPythonLockedDataBuffer()
        let stderrBuffer = MSPPythonLockedDataBuffer()
        let stdoutPump = Self.startOutputPump(
            fileHandle: stdoutPipe.fileHandleForReading,
            buffer: stdoutBuffer,
            outputStream: context.standardOutputStream,
            sanitizer: outputSanitizer
        )
        let stderrPump = Self.startOutputPump(
            fileHandle: stderrPipe.fileHandleForReading,
            buffer: stderrBuffer,
            outputStream: context.standardErrorStream,
            sanitizer: outputSanitizer
        )

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPump.cancel()
            stderrPump.cancel()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            process.terminationHandler = nil
            _ = await (stdoutPump.value, stderrPump.value)
            throw error
        }
        let stdinTask = Self.startInputPump(
            standardInput: context.standardInputStream == nil ? plan.standardInput : Data(),
            standardInputStream: context.standardInputStream,
            fileHandle: stdinPipe.fileHandleForWriting
        )

        let timedOut = await Self.wait(
            for: semaphore,
            timeout: .now() + plan.timeout
        ) == .timedOut
        if timedOut {
            process.terminate()
            _ = await Self.wait(for: semaphore, timeout: .now() + 1)
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        await context.standardInputStream?.closeRead()
        stdinTask.cancel()
        try? stdinPipe.fileHandleForWriting.close()
        process.terminationHandler = nil
        _ = await (stdoutPump.value, stderrPump.value)

        var stderr = stderrBuffer.data()
        if timedOut {
            stderr.append(Data("python3: timed out after \(Int(plan.timeout))s\n".utf8))
        }
        let streamedStdout = context.standardOutputStream != nil
        let streamedStderr = context.standardErrorStream != nil

        return MSPCommandResult(
            stdoutData: streamedStdout ? Data() : stdoutBuffer.data(),
            stderrData: streamedStderr ? Data() : stderr,
            exitCode: timedOut ? 124 : process.terminationStatus
        )
    }

    private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: timeout))
            }
        }
    }

    private static func startInputPump(
        standardInput: Data,
        standardInputStream: (any MSPCommandInputStream)?,
        fileHandle: FileHandle
    ) -> Task<Void, Never> {
        Task {
            if !standardInput.isEmpty {
                fileHandle.write(standardInput)
            }
            if let standardInputStream {
                do {
                    while !Task.isCancelled,
                          let chunk = try await standardInputStream.read(maxBytes: 32 * 1024) {
                        if !chunk.isEmpty {
                            fileHandle.write(chunk)
                        }
                    }
                } catch {
                    // Closing stdin below lets Python observe EOF instead of hanging.
                }
            }
            try? fileHandle.close()
        }
    }

    private static func startOutputPump(
        fileHandle: FileHandle,
        buffer: MSPPythonLockedDataBuffer,
        outputStream: (any MSPCommandOutputStream)?,
        sanitizer: MSPPythonOutputPathSanitizer
    ) -> Task<Bool, Never> {
        Task {
            var streamingSanitizer = MSPPythonStreamingOutputSanitizer(sanitizer: sanitizer)
            var didBreakPipe = false
            while !Task.isCancelled {
                let data = fileHandle.availableData
                guard !data.isEmpty else {
                    break
                }
                buffer.append(data)
                guard let outputStream else {
                    continue
                }
                let sanitized = streamingSanitizer.append(data)
                guard !sanitized.isEmpty else {
                    continue
                }
                do {
                    try await outputStream.write(sanitized)
                } catch MSPCommandStreamError.brokenPipe {
                    didBreakPipe = true
                    try? fileHandle.close()
                    break
                } catch {
                    // Preserve previous host-runtime behavior: streaming sink errors do not
                    // rewrite the Python process result.
                }
            }
            if !didBreakPipe, let outputStream {
                let remaining = streamingSanitizer.flush()
                if !remaining.isEmpty {
                    do {
                        try await outputStream.write(remaining)
                    } catch MSPCommandStreamError.brokenPipe {
                        didBreakPipe = true
                        try? fileHandle.close()
                    } catch {
                        // Keep buffered process completion independent from sink errors.
                    }
                }
            }
            return didBreakPipe
        }
    }
}

struct MSPPythonHostProcessPlan: Equatable {
    var executableURL: URL
    var arguments: [String]
    var currentDirectoryURL: URL
    var environment: [String: String]
    var standardInput: Data
    var timeout: TimeInterval
}

private struct MSPPythonPreparedHostProcessPlan {
    var runtimeDirectoryURL: URL
    var vfsBrokerDirectoryURL: URL
    var materializedDirectoryURL: URL
    var subprocessBrokerDirectoryURL: URL
    var subprocessBroker: MSPPythonSubprocessBroker
    var vfsBroker: MSPPythonVirtualFileSystemBroker
    var plan: MSPPythonHostProcessPlan
}

private final class MSPPythonLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

private extension MSPPythonEntrypoint {
    var requiresBufferedStandardInputSource: Bool {
        if case .standardInput = self {
            return true
        }
        return false
    }
}
#endif
