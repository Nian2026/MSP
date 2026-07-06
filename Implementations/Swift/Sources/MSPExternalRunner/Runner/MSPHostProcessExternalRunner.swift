#if os(macOS) || os(Linux)
import Foundation
import MSPCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct MSPHostProcessExternalRunner: MSPExternalCommandRunner {
    public var executableURL: URL
    public var timeout: TimeInterval
    public var extraEnvironment: [String: String]
    public var versionOutput: String?

    public init(
        executableURL: URL,
        timeout: TimeInterval = 30,
        extraEnvironment: [String: String] = [:],
        versionOutput: String? = nil
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.extraEnvironment = extraEnvironment
        self.versionOutput = versionOutput
    }

    public func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let versionOutput,
           request.arguments.count == 1,
           (request.arguments[0] == "--version" || request.arguments[0] == "-v") {
            guard context.workspace != nil else {
                return .success(stdout: versionOutput)
            }
            return try workspaceOutputSanitizer(context: context)
                .sanitize(.success(stdout: versionOutput))
        }
        let workingDirectoryURL = try hostWorkingDirectoryURL(
            virtualPath: request.workingDirectory,
            context: context
        )
        let standardInput = try await bufferedStandardInput(from: context)
        let outputSanitizer = try workspaceOutputSanitizer(context: context)
        return try runProcess(
            request: request,
            context: context,
            workingDirectoryURL: workingDirectoryURL,
            standardInput: standardInput,
            outputSanitizer: outputSanitizer
        )
    }

    private func hostWorkingDirectoryURL(
        virtualPath: String,
        context: MSPCommandContext
    ) throws -> URL {
        guard let workspace = context.workspace else {
            throw MSPHostProcessExternalRunnerError.missingWorkspace
        }
        let resolved = try workspace.fileSystem.resolve(virtualPath, from: "/")
        guard let physicalPath = resolved.physicalPath else {
            throw MSPHostProcessExternalRunnerError.unmappedWorkspacePath(resolved.virtualPath)
        }
        return URL(fileURLWithPath: physicalPath, isDirectory: true)
    }

    private func workspaceOutputSanitizer(
        context: MSPCommandContext
    ) throws -> MSPOutputPathSanitizer {
        var mappings = [
            try workspaceRootOutputMapping(context: context)
        ]
        let baseSanitizer = MSPOutputPathSanitizer(mappings: mappings)
        let executableDirectory = executableURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        if shouldVirtualizeHostOnlyExecutableDirectory(
            executableDirectory,
            baseSanitizer: baseSanitizer
        ) {
            mappings.append(MSPOutputPathSanitizer.Mapping(
                realPath: executableDirectory,
                virtualPath: modelVisibleHostOnlyExecutableDirectory
            ))
        }
        return MSPOutputPathSanitizer(mappings: mappings)
    }

    private func workspaceRootOutputMapping(
        context: MSPCommandContext
    ) throws -> MSPOutputPathSanitizer.Mapping {
        guard let workspace = context.workspace else {
            throw MSPHostProcessExternalRunnerError.missingWorkspace
        }
        let resolvedRoot = try workspace.fileSystem.resolve("/", from: "/")
        guard let physicalRootPath = resolvedRoot.physicalPath else {
            throw MSPHostProcessExternalRunnerError.unmappedWorkspacePath("/")
        }
        return MSPOutputPathSanitizer.Mapping(
            realPath: physicalRootPath,
            virtualPath: "/"
        )
    }

    private var modelVisibleHostOnlyExecutableDirectory: String {
        "/usr/local/bin"
    }

    private var modelVisibleExecutableDirectories: Set<String> {
        [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    private func shouldVirtualizeHostOnlyExecutableDirectory(
        _ executableDirectory: String,
        baseSanitizer: MSPOutputPathSanitizer
    ) -> Bool {
        guard !executableDirectory.isEmpty,
              !modelVisibleExecutableDirectories.contains(executableDirectory)
        else {
            return false
        }
        return baseSanitizer.sanitize(executableDirectory) == executableDirectory
    }

    private func bufferedStandardInput(from context: MSPCommandContext) async throws -> Data {
        guard let stream = context.standardInputStream else {
            return context.standardInput
        }
        var data = Data()
        while let chunk = try await stream.read(maxBytes: 32 * 1024) {
            data.append(chunk)
        }
        return data
    }

    private func processEnvironment(
        request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) throws -> [String: String] {
        var environment = defaultWorkspaceEnvironment()
        environment.merge(try processEnvironmentValues(extraEnvironment, context: context)) { _, new in new }
        environment.merge(try processEnvironmentValues(request.environment, context: context)) { _, new in new }
        environment["HOME"] = try processEnvironmentValue("/", context: context)
        environment["PWD"] = try processEnvironmentValue(
            MSPWorkspacePathResolver.normalize(request.workingDirectory, from: context.currentDirectory),
            context: context
        )
        environment["TMPDIR"] = try processEnvironmentValue("/tmp", context: context)
        environment["MSP_WORKSPACE_ROOT"] = try processEnvironmentValue("/", context: context)
        environment["PATH"] = try executableSearchPath(
            existingPath: environment["PATH"] ?? "",
            context: context
        )
        return environment
    }

    private func executableSearchPath(
        existingPath: String,
        context: MSPCommandContext
    ) throws -> String {
        let executableDirectory = executableURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        let pathComponents = existingPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        if pathComponents.contains(executableDirectory) {
            return existingPath
        }

        let baseSanitizer = try MSPOutputPathSanitizer(mappings: [
            workspaceRootOutputMapping(context: context)
        ])
        if shouldVirtualizeHostOnlyExecutableDirectory(
            executableDirectory,
            baseSanitizer: baseSanitizer
        ) {
            var didReplace = false
            let replacedComponents = pathComponents.map { component in
                guard !didReplace,
                      component == modelVisibleHostOnlyExecutableDirectory
                else {
                    return component
                }
                didReplace = true
                return executableDirectory
            }
            if didReplace {
                return replacedComponents.joined(separator: ":")
            }
        }

        return existingPath.isEmpty
            ? executableDirectory
            : executableDirectory + ":" + existingPath
    }

    private func defaultWorkspaceEnvironment() -> [String: String] {
        [
            "HOME": "/",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": "/",
            "TMPDIR": "/tmp",
            "MSP_WORKSPACE_ROOT": "/"
        ]
    }

    private func processEnvironmentValues(
        _ environment: [String: String],
        context: MSPCommandContext
    ) throws -> [String: String] {
        var processed: [String: String] = [:]
        for (key, value) in environment {
            processed[key] = try processEnvironmentValue(value, context: context)
        }
        return processed
    }

    private func processEnvironmentValue(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String {
        if let mappedPathList = try mappedVirtualPathList(value, context: context) {
            return mappedPathList
        }
        return try mappedVirtualPathLikeValue(value, context: context) ?? value
    }

    private func runProcess(
        request: MSPExternalCommandRequest,
        context: MSPCommandContext,
        workingDirectoryURL: URL,
        standardInput: Data,
        outputSanitizer: MSPOutputPathSanitizer
    ) throws -> MSPCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = try processArguments(request.arguments, context: context)
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = try processEnvironment(
            request: request,
            context: context
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let stdoutBuffer = MSPHostProcessLockedDataBuffer()
        let stderrBuffer = MSPHostProcessLockedDataBuffer()
        let outputStopSignal = MSPHostProcessOutputStopSignal()
        let outputReadGroup = DispatchGroup()
        let outputReadQueue = DispatchQueue(
            label: "dev.modelshellproxy.external-runner-output",
            attributes: .concurrent
        )

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return MSPCommandResult(
                stdout: "",
                stderr: launchFailureStderr(
                    request: request,
                    error: error,
                    outputSanitizer: outputSanitizer
                ),
                exitCode: 126
            )
        }

        readOutput(
            from: stdoutPipe,
            into: stdoutBuffer,
            stopSignal: outputStopSignal,
            group: outputReadGroup,
            queue: outputReadQueue
        )
        readOutput(
            from: stderrPipe,
            into: stderrBuffer,
            stopSignal: outputStopSignal,
            group: outputReadGroup,
            queue: outputReadQueue
        )

        if !standardInput.isEmpty {
            stdinPipe.fileHandleForWriting.write(standardInput)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
        }
        process.terminationHandler = nil
        outputStopSignal.stop()
        outputReadGroup.wait()

        var stderr = stderrBuffer.data()
        if timedOut {
            stderr.append(Data("\(request.executableName): timed out after \(Int(timeout))s\n".utf8))
        }

        return outputSanitizer.sanitize(MSPCommandResult(
            stdoutData: stdoutBuffer.data(),
            stderrData: stderr,
            exitCode: timedOut ? 124 : process.terminationStatus
        ))
    }

    private func readOutput(
        from pipe: Pipe,
        into buffer: MSPHostProcessLockedDataBuffer,
        stopSignal: MSPHostProcessOutputStopSignal,
        group: DispatchGroup,
        queue: DispatchQueue
    ) {
        group.enter()
        queue.async {
            readPipeOutput(pipe.fileHandleForReading, into: buffer, stopSignal: stopSignal)
            try? pipe.fileHandleForReading.close()
            group.leave()
        }
    }

    private func readPipeOutput(
        _ fileHandle: FileHandle,
        into buffer: MSPHostProcessLockedDataBuffer,
        stopSignal: MSPHostProcessOutputStopSignal
    ) {
        let fd = fileHandle.fileDescriptor
        setNonBlocking(fd)
        var scratch = [UInt8](repeating: 0, count: 32 * 1024)
        var stopDrainDeadline: Date?

        while true {
            if stopSignal.isStopped {
                if let deadline = stopDrainDeadline {
                    if Date() >= deadline {
                        return
                    }
                } else {
                    stopDrainDeadline = Date().addingTimeInterval(0.2)
                }
            }

            let count = scratch.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                buffer.append(Data(scratch.prefix(Int(count))))
                continue
            }
            if count == 0 {
                return
            }

            let error = errno
            if error == EINTR {
                continue
            }
            guard isWouldBlock(error) else {
                return
            }

            if stopSignal.isStopped {
                if stopDrainDeadline == nil {
                    stopDrainDeadline = Date().addingTimeInterval(0.2)
                } else if Date() >= stopDrainDeadline! {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            return
        }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private func isWouldBlock(_ error: Int32) -> Bool {
        error == EAGAIN || error == EWOULDBLOCK
    }

    private func launchFailureStderr(
        request: MSPExternalCommandRequest,
        error: Error,
        outputSanitizer: MSPOutputPathSanitizer
    ) -> String {
        let modelExecutablePath = modelVisibleExecutablePath(outputSanitizer: outputSanitizer)
        let reason = launchFailureReason(error, outputSanitizer: outputSanitizer)
        return "\(request.executableName): failed to start \(modelExecutablePath): \(reason)\n"
    }

    private func modelVisibleExecutablePath(
        outputSanitizer: MSPOutputPathSanitizer
    ) -> String {
        let hostPath = executableURL.path
        let sanitizedPath = outputSanitizer.sanitize(hostPath)
        guard sanitizedPath != hostPath else {
            return executableURL.lastPathComponent
        }
        return sanitizedPath
    }

    private func launchFailureReason(
        _ error: Error,
        outputSanitizer: MSPOutputPathSanitizer
    ) -> String {
        let sanitizedDescription = outputSanitizer.sanitize((error as NSError).localizedDescription)
        guard !sanitizedDescription.contains("/") else {
            return "process could not be started"
        }
        return sanitizedDescription
    }

    private func processArguments(
        _ arguments: [String],
        context: MSPCommandContext
    ) throws -> [String] {
        try arguments.map { argument in
            try processArgument(argument, context: context)
        }
    }

    private func processArgument(
        _ argument: String,
        context: MSPCommandContext
    ) throws -> String {
        if let mappedOptionValue = try processOptionValueArgument(argument, context: context) {
            return mappedOptionValue
        }
        return try mappedVirtualPathLikeValue(argument, context: context) ?? argument
    }

    private func processOptionValueArgument(
        _ argument: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard argument.hasPrefix("-"),
              let separatorIndex = argument.firstIndex(of: "=")
        else {
            return nil
        }
        let valueStartIndex = argument.index(after: separatorIndex)
        let value = String(argument[valueStartIndex...])
        guard let mappedValue = try mappedVirtualPathLikeValue(value, context: context) else {
            return nil
        }
        return String(argument[...separatorIndex]) + mappedValue
    }

    private func mappedVirtualPathLikeValue(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String? {
        if let mappedPath = try mappedVirtualAbsolutePath(value, context: context) {
            return mappedPath
        }
        return try mappedVirtualFileURL(value, context: context)
    }

    private func mappedVirtualPathList(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard value.contains(":"),
              !value.contains("://")
        else {
            return nil
        }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count > 1 else {
            return nil
        }
        var didMap = false
        let mappedComponents = try components.map { component in
            guard !component.isEmpty,
                  let mappedComponent = try mappedVirtualPathLikeValue(component, context: context)
            else {
                return component
            }
            didMap = true
            return mappedComponent
        }
        guard didMap else {
            return nil
        }
        return mappedComponents.joined(separator: ":")
    }

    private func mappedVirtualFileURL(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard let url = URL(string: value),
              url.isFileURL
        else {
            return nil
        }
        guard let physicalPath = try mappedVirtualAbsolutePath(url.path, context: context) else {
            return nil
        }
        return URL(fileURLWithPath: physicalPath)
            .standardizedFileURL
            .absoluteString
    }

    private func mappedVirtualAbsolutePath(
        _ path: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard path.hasPrefix("/"),
              MSPWorkspacePathResolver.isSyntacticallyValid(path),
              let workspace = context.workspace
        else {
            return nil
        }
        let resolved = try workspace.fileSystem.resolve(path, from: "/")
        guard let physicalPath = resolved.physicalPath else {
            throw MSPHostProcessExternalRunnerError.unmappedWorkspacePath(resolved.virtualPath)
        }
        return physicalPath
    }
}

public enum MSPHostProcessExternalRunnerError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingWorkspace
    case unmappedWorkspacePath(String)

    public var description: String {
        switch self {
        case .missingWorkspace:
            return "host process external runner requires a mapped workspace"
        case .unmappedWorkspacePath(let path):
            return "workspace path is not mapped to a host path: \(path)"
        }
    }
}

private final class MSPHostProcessLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
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

private final class MSPHostProcessOutputStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
#endif
