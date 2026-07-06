import Foundation
import MSPPythonRuntime

public struct MSPCPythonEngine: MSPPythonStreamingEmbeddedEngine {
    public var workspaceRootURL: URL?

    private let symbols: MSPCPythonSymbols
    // CPython execution mutates process-wide cwd and interpreter state.
    private let lock = NSLock()
    private let pythonHomeURL: URL?

    public init(
        library: MSPCPythonLibrary,
        workspaceRootURL: URL? = nil,
        pythonHomeURL: URL? = nil
    ) throws {
        self.symbols = try MSPCPythonSymbols(library: library)
        self.workspaceRootURL = workspaceRootURL?.standardizedFileURL
        self.pythonHomeURL = pythonHomeURL?.standardizedFileURL
    }

    public func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        try lock.withLock {
            try initializeIfNeeded()
            return try runPythonSynchronously(request: request, streamsEnabled: false)
        }
    }

    public func runPythonStreaming(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        try lock.withLock {
            try initializeIfNeeded()
            return try runPythonSynchronously(request: request, streamsEnabled: true)
        }
    }

    private func initializeIfNeeded() throws {
        guard symbols.pyIsInitialized() == 0 else {
            return
        }
        let restorePythonHome = Self.temporarilySetPythonHome(pythonHomeURL)
        defer { restorePythonHome() }
        Self.configureUTF8Environment()
        symbols.pyInitializeEx(0)
        guard symbols.pyIsInitialized() != 0 else {
            throw MSPPythonEmbeddedRuntimeError.engineUnavailable("CPython failed to initialize")
        }
        _ = symbols.pyEvalSaveThread()
    }

    private func runPythonSynchronously(
        request: MSPPythonEmbeddedExecutionRequest,
        streamsEnabled: Bool
    ) throws -> MSPPythonEmbeddedExecutionResult {
        let liveIO = streamsEnabled ? MSPCPythonLiveIO(request: request) : nil
        let prepared = try MSPCPythonPreparedExecution(
            request: request,
            workspaceRootURL: workspaceRootURL,
            liveIO: liveIO
        )
        let subprocessBroker = try MSPPythonSubprocessBroker(
            directoryURL: prepared.brokerDirectoryURL,
            baseContext: request.subprocessContext
        )
        let vfsBroker = try MSPPythonVirtualFileSystemBroker(
            directoryURL: prepared.vfsBrokerDirectoryURL,
            baseContext: request.subprocessContext
        )
        subprocessBroker.start()
        vfsBroker.start()
        liveIO?.start(outputSanitizer: outputPathSanitizer(prepared: prepared))
        let currentDirectory = FileManager.default.currentDirectoryPath
        defer {
            liveIO?.finish()
            vfsBroker.stop()
            subprocessBroker.stop()
            FileManager.default.changeCurrentDirectoryPath(currentDirectory)
            try? FileManager.default.removeItem(at: prepared.resultURL)
            try? FileManager.default.removeItem(at: prepared.brokerDirectoryURL)
        }
        if let hostCurrentDirectoryURL = prepared.hostCurrentDirectoryURL {
            let changed = FileManager.default.changeCurrentDirectoryPath(hostCurrentDirectoryURL.path)
            guard changed else {
                throw MSPPythonEmbeddedRuntimeError.engineUnavailable(
                    "cannot enter workspace directory \(prepared.virtualCurrentDirectory)"
                )
            }
        }

        let state = symbols.pyGILStateEnsure()
        let previousThreadState = symbols.pyThreadStateGet()
        guard let subinterpreterThreadState = symbols.pyNewInterpreter() else {
            _ = symbols.pyThreadStateSwap(previousThreadState)
            symbols.pyGILStateRelease(state)
            throw MSPPythonEmbeddedRuntimeError.engineUnavailable("CPython failed to create subinterpreter")
        }
        defer {
            _ = symbols.pyThreadStateSwap(subinterpreterThreadState)
            symbols.pyEndInterpreter(subinterpreterThreadState)
            _ = symbols.pyThreadStateSwap(previousThreadState)
            symbols.pyGILStateRelease(state)
        }

        let bootstrap = try MSPCPythonBootstrapSource.makeSource(payload: prepared.payload)
        let status = bootstrap.withCString { pointer in
            symbols.pyRunSimpleStringFlags(pointer, nil)
        }
        if status != 0,
           let resultData = try? Data(contentsOf: prepared.resultURL),
           let result = try? JSONDecoder().decode(MSPCPythonCapturedResult.self, from: resultData) {
            return liveIO?.suppressStreamedOutput(
                in: sanitizedExecutionResult(result, prepared: prepared)
            ) ?? sanitizedExecutionResult(result, prepared: prepared)
        }
        guard status == 0 else {
            throw MSPPythonEmbeddedRuntimeError.engineUnavailable("CPython bootstrap execution failed")
        }
        let resultData = try Data(contentsOf: prepared.resultURL)
        let result = try JSONDecoder().decode(MSPCPythonCapturedResult.self, from: resultData)
        return liveIO?.suppressStreamedOutput(
            in: sanitizedExecutionResult(result, prepared: prepared)
        ) ?? sanitizedExecutionResult(result, prepared: prepared)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
