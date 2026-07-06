import Foundation

struct MSPPythonSubprocessRequest: Decodable {
    var id: String
    var action: String?
    var commandLine: String?
    var stdinB64: String?
    var stdinPipe: Bool?
    var cwd: String?
    var environment: [String: String]?
    var timeout: TimeInterval?
    var deadlineUnix: TimeInterval?
    var sessionID: String?
    var stream: String?
    var maxBytes: Int?
    var mergeStderrToStdout: Bool?
    var signalNumber: Int32?

    var stdinData: Data {
        Data(base64Encoded: stdinB64 ?? "") ?? Data()
    }

    var remainingTimeout: TimeInterval? {
        guard let timeout else {
            return nil
        }
        if let deadlineUnix {
            let remaining = deadlineUnix - Date().timeIntervalSince1970
            return remaining > 0 ? remaining : nil
        }
        return timeout
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case commandLine = "command_line"
        case stdinB64 = "stdin_b64"
        case stdinPipe = "stdin_pipe"
        case cwd
        case environment
        case timeout
        case deadlineUnix = "deadline_unix"
        case sessionID = "session_id"
        case stream
        case maxBytes = "max_bytes"
        case mergeStderrToStdout = "merge_stderr_to_stdout"
        case signalNumber = "signal_number"
    }
}

struct MSPPythonSubprocessResponse: Encodable {
    var stdoutB64: String = ""
    var stderrB64: String = ""
    var exitCode: Int32 = 0
    var ok: Bool = true
    var error: String?
    var sessionID: String?
    var dataB64: String?
    var running: Bool?
    var timedOut: Bool?

    init(
        stdoutB64: String = "",
        stderrB64: String = "",
        exitCode: Int32 = 0,
        ok: Bool = true,
        error: String? = nil,
        sessionID: String? = nil,
        dataB64: String? = nil,
        running: Bool? = nil,
        timedOut: Bool? = nil
    ) {
        self.stdoutB64 = stdoutB64
        self.stderrB64 = stderrB64
        self.exitCode = exitCode
        self.ok = ok
        self.error = error
        self.sessionID = sessionID
        self.dataB64 = dataB64
        self.running = running
        self.timedOut = timedOut
    }

    static func success(
        exitCode: Int32 = 0,
        stdoutB64: String = "",
        stderrB64: String = "",
        sessionID: String? = nil,
        dataB64: String? = nil,
        running: Bool? = nil
    ) -> MSPPythonSubprocessResponse {
        MSPPythonSubprocessResponse(
            stdoutB64: stdoutB64,
            stderrB64: stderrB64,
            exitCode: exitCode,
            sessionID: sessionID,
            dataB64: dataB64,
            running: running
        )
    }

    static func failure(stderr: String, exitCode: Int32 = 1) -> MSPPythonSubprocessResponse {
        MSPPythonSubprocessResponse(
            stdoutB64: "",
            stderrB64: Data(stderr.utf8).base64EncodedString(),
            exitCode: exitCode,
            ok: false,
            error: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func timedOut(
        running: Bool? = nil,
        stdoutB64: String = "",
        stderrB64: String = ""
    ) -> MSPPythonSubprocessResponse {
        MSPPythonSubprocessResponse(
            stdoutB64: stdoutB64,
            stderrB64: stderrB64,
            exitCode: 124,
            running: running,
            timedOut: true
        )
    }

    enum CodingKeys: String, CodingKey {
        case stdoutB64 = "stdout_b64"
        case stderrB64 = "stderr_b64"
        case exitCode = "exit_code"
        case ok
        case error
        case sessionID = "session_id"
        case dataB64 = "data_b64"
        case running
        case timedOut = "timed_out"
    }
}
