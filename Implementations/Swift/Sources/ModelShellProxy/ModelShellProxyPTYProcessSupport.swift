import Foundation
import MSPAgentBridge
import MSPPtySupport

#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
import Darwin

struct ModelShellProxyPTYWaitStatus {
    var exitCode: Int32?
    var signal: Int32?

    var resultExitCode: Int32 {
        if let exitCode {
            return exitCode
        }
        if let signal {
            return 128 + signal
        }
        return 1
    }
}

enum ModelShellProxyPTYProcessSupport {
    static let writeTimeoutMilliseconds = 1_000

    static func killProcessGroup(_ processID: pid_t, signal: Int32) -> Int32 {
        let processGroupID = getpgid(processID)
        if processGroupID > 0 {
            return kill(-processGroupID, signal)
        }
        return kill(processID, signal)
    }

    static func configureNonBlocking(masterFD: Int32) throws {
        let flags = fcntl(masterFD, F_GETFL)
        if flags < 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if fcntl(masterFD, F_SETFL, flags | O_NONBLOCK) < 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    static func writeAll(
        _ data: Data,
        to fd: Int32,
        timeoutMilliseconds: Int
    ) -> Bool {
        guard !data.isEmpty else {
            return true
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return true
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    return false
                }

                let writeErrno = errno
                if writeErrno == EINTR {
                    continue
                }
                if writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
                    guard Date() < deadline else {
                        return false
                    }
                    waitUntilWritable(fd: fd, deadline: deadline)
                    continue
                }
                return false
            }
            return true
        }
    }

    static func waitUntilReadable(
        fd: Int32,
        timeoutMilliseconds: Int32
    ) {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result >= 0 || errno != EINTR {
                return
            }
        }
    }

    static func spawnPTYProcess(call: MSPExecCommandCall) throws -> (masterFD: Int32, processID: pid_t) {
        let shell = resolvedShell(call.shell)
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        var argv = makeCStringArray([shellName, "-c", call.cmd])
        defer { freeCStringArray(argv) }

        let requestedWorkdir = call.workdir?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir: String
        if let requestedWorkdir, !requestedWorkdir.isEmpty {
            workdir = requestedWorkdir
        } else {
            workdir = "/"
        }
        var environment = sanitizedPTYProcessEnvironment(shell: shell, workdir: workdir)
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "C.UTF-8"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "C.UTF-8"
        var envp = makeCStringArray(
            environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        )
        defer { freeCStringArray(envp) }

        var result = MSPPtySpawnResult()
        let spawnStatus: Int32
        spawnStatus = workdir.withCString { cwdPointer in
            shell.withCString { shellPointer in
                msp_spawn_pty_process(shellPointer, &argv, &envp, cwdPointer, &result)
            }
        }
        if spawnStatus != 0 {
            let code = result.error_code != 0 ? result.error_code : errno
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return (result.master_fd, result.process_id)
    }

    static func decodeWaitStatus(_ status: Int32) -> ModelShellProxyPTYWaitStatus {
        let terminationStatus = status & 0x7f
        if terminationStatus == 0 {
            return ModelShellProxyPTYWaitStatus(exitCode: (status >> 8) & 0xff, signal: nil)
        }
        if terminationStatus != 0x7f {
            return ModelShellProxyPTYWaitStatus(exitCode: nil, signal: terminationStatus)
        }
        return ModelShellProxyPTYWaitStatus(exitCode: 1, signal: nil)
    }

    private static func waitUntilWritable(fd: Int32, deadline: Date) {
        let remainingMilliseconds = max(
            1,
            min(20, Int(deadline.timeIntervalSinceNow * 1_000))
        )
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))
            if result >= 0 || errno != EINTR {
                return
            }
        }
    }

    private static func sanitizedPTYProcessEnvironment(
        shell: String,
        workdir: String?
    ) -> [String: String] {
        let virtualCurrentDirectory: String
        if let workdir, !workdir.isEmpty {
            virtualCurrentDirectory = workdir
        } else {
            virtualCurrentDirectory = "/"
        }
        return [
            "HOME": "/tmp",
            "LANG": "C.UTF-8",
            "LC_CTYPE": "C.UTF-8",
            "LOGNAME": "msp",
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "PWD": virtualCurrentDirectory,
            "PYTHON_HISTORY": "/tmp/.python_history",
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "PYTHON_BASIC_REPL": "1",
            "SHELL": shell,
            "TERM": "xterm-256color",
            "TMP": "/tmp",
            "TMPDIR": "/tmp",
            "USER": "msp"
        ]
    }

    private static func resolvedShell(_ requestedShell: String?) -> String {
        if let requestedShell = requestedShell?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedShell.isEmpty {
            return requestedShell
        }
        for candidate in ["/bin/bash", "/bin/zsh", "/bin/sh"] where isExecutable(candidate) {
            return candidate
        }
        return "/bin/sh"
    }

    private static func isExecutable(_ path: String) -> Bool {
        access(path, X_OK) == 0
    }

    private static func makeCStringArray(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ values: [UnsafeMutablePointer<CChar>?]) {
        for value in values {
            free(value)
        }
    }
}
#endif
