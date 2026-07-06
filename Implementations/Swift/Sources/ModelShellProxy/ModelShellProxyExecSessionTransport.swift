import MSPAgentBridge
import MSPCore

actor ModelShellProxyExecSessionTransport: MSPExecCommandSessionTransport {
    private enum Backend {
        case pipe
        case pty
    }

    private let pipe: ModelShellProxyPipeExecSessionTransport
    private let pty: ModelShellProxyPTYExecSessionTransport
    private let nativePTYAvailable: @Sendable () -> Bool
    private var backendsBySessionID: [Int: Backend] = [:]

    init(
        shell: ModelShellProxy,
        nativePTYAvailable: @escaping @Sendable () -> Bool = {
            ModelShellProxyPTYExecSessionTransport.isAvailable
        }
    ) {
        self.pipe = ModelShellProxyPipeExecSessionTransport(shell: shell)
        self.pty = ModelShellProxyPTYExecSessionTransport()
        self.nativePTYAvailable = nativePTYAvailable
    }

    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        let backend: Backend = call.tty && nativePTYAvailable() ? .pty : .pipe
        let read: MSPExecCommandSessionRead
        switch backend {
        case .pipe:
            var pipeCall = call
            pipeCall.tty = false
            read = await pipe.start(call: pipeCall, sessionID: sessionID, onOutput: onOutput)
        case .pty:
            read = await pty.start(call: call, sessionID: sessionID, onOutput: onOutput)
        }
        if read.isRunning {
            backendsBySessionID[sessionID] = backend
        } else {
            backendsBySessionID.removeValue(forKey: sessionID)
        }
        return read
    }

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        guard let backend = backendsBySessionID[call.sessionID] else {
            return inactiveRead(sessionID: call.sessionID, operation: "write_stdin")
        }
        let read: MSPExecCommandSessionRead
        switch backend {
        case .pipe:
            read = await pipe.write(call: call, onOutput: onOutput)
        case .pty:
            read = await pty.write(call: call, onOutput: onOutput)
        }
        if !read.isRunning {
            backendsBySessionID.removeValue(forKey: call.sessionID)
        }
        return read
    }

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        guard let backend = backendsBySessionID[sessionID] else {
            return inactiveRead(sessionID: sessionID, operation: "read")
        }
        let read: MSPExecCommandSessionRead
        switch backend {
        case .pipe:
            read = await pipe.read(
                sessionID: sessionID,
                waitMilliseconds: waitMilliseconds,
                onOutput: onOutput
            )
        case .pty:
            read = await pty.read(
                sessionID: sessionID,
                waitMilliseconds: waitMilliseconds,
                onOutput: onOutput
            )
        }
        if !read.isRunning {
            backendsBySessionID.removeValue(forKey: sessionID)
        }
        return read
    }

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        guard let backend = backendsBySessionID.removeValue(forKey: sessionID) else {
            return inactiveRead(sessionID: sessionID, operation: "terminate")
        }
        switch backend {
        case .pipe:
            return await pipe.terminate(sessionID: sessionID)
        case .pty:
            return await pty.terminate(sessionID: sessionID)
        }
    }

    private func inactiveRead(
        sessionID: Int,
        operation: String
    ) -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "\(operation) failed: inactive session \(sessionID)\n"
            ),
            exitCode: 1
        )
    }
}
