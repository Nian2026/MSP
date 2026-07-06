import Foundation
import MSPCore

public final class MSPPythonSubprocessBroker: @unchecked Sendable {
    let directoryURL: URL
    let baseContext: MSPCommandContext
    let runner: MSPCommandLineRunner?
    let runnerGate = MSPPythonSubprocessRunnerGate()
    let lock = NSLock()
    var isStopped = false
    var processedRequestIDs = Set<String>()
    var sessions: [String: MSPPythonSubprocessSession] = [:]
    var thread: Thread?

    public init(directoryURL: URL, baseContext: MSPCommandContext) throws {
        self.directoryURL = directoryURL
        self.baseContext = baseContext
        self.runner = baseContext.commandLineRunner
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func start() {
        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        self.thread = thread
        thread.start()
    }

    public func stop() {
        let storedSessions = lock.withLock { () -> [MSPPythonSubprocessSession] in
            isStopped = true
            let values = Array(sessions.values)
            sessions.removeAll()
            return values
        }
        for session in storedSessions {
            session.kill(returnCode: -15)
        }
        while thread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private var stopped: Bool {
        lock.withLock { isStopped }
    }

    private func runLoop() {
        while !stopped {
            autoreleasepool {
                processAvailableRequests()
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func processAvailableRequests() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("request-")
            && file.pathExtension == "json" {
            processRequest(at: file)
        }
    }

    private func processRequest(at url: URL) {
        guard let request = try? JSONDecoder().decode(
            MSPPythonSubprocessRequest.self,
            from: Data(contentsOf: url)
        ) else {
            return
        }
        let shouldProcess = lock.withLock { () -> Bool in
            guard !processedRequestIDs.contains(request.id) else {
                return false
            }
            processedRequestIDs.insert(request.id)
            return true
        }
        guard shouldProcess else {
            return
        }

        let response = handle(request)
        write(response, id: request.id)
        try? FileManager.default.removeItem(at: url)
    }

    func session(for request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessSession? {
        guard let id = request.sessionID else {
            return nil
        }
        return lock.withLock { sessions[id] }
    }

    func context(
        for request: MSPPythonSubprocessRequest,
        stdinData: Data,
        cancellationToken: MSPPythonSubprocessCancellationToken
    ) -> MSPCommandContext {
        var context = baseContext
        context.currentDirectory = MSPWorkspacePathResolver.normalize(
            request.cwd ?? baseContext.currentDirectory,
            from: baseContext.currentDirectory
        )
        if let environment = request.environment {
            context.environment = environment
        }
        context.standardInput = stdinData
        context.standardInputClosed = false
        context.standardInputStream = nil
        context.standardOutputStream = nil
        context.standardErrorStream = nil
        if let workspace = context.workspace {
            context.workspace = MSPPythonCancellableWorkspace(
                base: MSPPythonImplicitDirectoryWorkspace(base: workspace),
                cancellationToken: cancellationToken
            )
        }
        return context
    }

    func write(_ response: MSPPythonSubprocessResponse, id: String) {
        let responseURL = directoryURL.appendingPathComponent("response-\(id).json")
        let temporaryURL = directoryURL.appendingPathComponent("response-\(id).json.tmp")
        do {
            try JSONEncoder().encode(response).write(to: temporaryURL)
            if FileManager.default.fileExists(atPath: responseURL.path) {
                try FileManager.default.removeItem(at: responseURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: responseURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
