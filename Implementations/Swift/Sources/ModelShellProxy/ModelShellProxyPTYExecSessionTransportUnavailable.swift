import MSPAgentBridge

#if !(os(macOS) || (os(iOS) && targetEnvironment(simulator)))
actor ModelShellProxyPTYExecSessionTransport: MSPExecCommandSessionTransport {
    static var isAvailable: Bool { false }

    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "exec_command tty=true requires a native PTY backend on this platform.\n"
            ),
            exitCode: 1
        )
    }

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "write_stdin failed: native PTY backend is unavailable on this platform.\n"
            ),
            exitCode: 1
        )
    }

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "read failed: native PTY backend is unavailable on this platform.\n"
            ),
            exitCode: 1
        )
    }

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "terminate failed: native PTY backend is unavailable on this platform.\n"
            ),
            exitCode: 1
        )
    }
}
#endif
