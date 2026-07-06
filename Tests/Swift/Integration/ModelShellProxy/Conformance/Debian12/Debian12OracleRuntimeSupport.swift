import Foundation
import ModelShellProxy
import MSPPythonEmbeddedRuntime
import MSPPythonRuntime

enum Debian12OraclePythonBackend {
    case none
    case hostProcess
    case embeddedCPython
}

enum Debian12OracleRuntimeSupport {
    static func makeShell(
        configuration: MSPConfiguration,
        rootURL: URL
    ) throws -> ModelShellProxy {
        let shell = try ModelShellProxy(configuration: configuration)
            .enable(.posixCore)
        switch try selectedPythonBackend() {
        case .none:
            return try enableNodeIfConfigured(shell)
        case .hostProcess:
        #if os(macOS)
            let temporaryDirectoryURL = try Debian12OracleTestSupport.packageRoot()
                .appendingPathComponent(".build")
                .appendingPathComponent("msp-conformance")
                .appendingPathComponent("python-runtime")
            let pythonShell = try shell.enable(
                .python(
                    runtime: MSPPythonHostProcessRuntime(
                        executableURL: try hostPythonExecutableURL(),
                        workspaceRootURL: rootURL,
                        temporaryDirectoryURL: temporaryDirectoryURL
                    )
                )
            )
            return try enableNodeIfConfigured(pythonShell)
        #else
            throw Debian12OracleTestSupport.runnerError("host Python oracle runtime is only available on macOS")
        #endif
        case .embeddedCPython:
            let pythonShell = try shell.enable(
                .python(
                    runtime: MSPPythonEmbeddedRuntime(
                        engine: try embeddedCPythonEngine(rootURL: rootURL)
                    )
                )
            )
            return try enableNodeIfConfigured(pythonShell)
        }
    }

    private static func enableNodeIfConfigured(_ shell: ModelShellProxy) throws -> ModelShellProxy {
        let environment = ProcessInfo.processInfo.environment
        guard let configured = environment["MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE"],
              !configured.isEmpty else {
            return shell
        }
        #if os(macOS)
        return try shell.registerExternalCommand(
            "node",
            summary: "Run Node.js through the configured host process runner for Debian oracle conformance.",
            commandLookupPaths: [environment["MSP_DEBIAN12_ORACLE_NODE_LOOKUP_PATH"] ?? "/usr/local/bin/node"],
            runner: MSPHostProcessExternalRunner(
                executableURL: try executableURL(path: configured, description: "node executable"),
                timeout: 30,
                versionOutput: environment["MSP_DEBIAN12_ORACLE_NODE_VERSION_OUTPUT"] ?? "v24.14.0\n"
            )
        )
        #else
        throw Debian12OracleTestSupport.runnerError("host Node oracle runtime is only available on macOS")
        #endif
    }

    private static func selectedPythonBackend() throws -> Debian12OraclePythonBackend {
        let environment = ProcessInfo.processInfo.environment
        if let backend = environment["MSP_DEBIAN12_ORACLE_PYTHON_BACKEND"],
           !backend.isEmpty {
            switch backend.lowercased() {
            case "none", "off", "disabled":
                return .none
            case "host", "host-process", "host_process":
                return .hostProcess
            case "embedded", "embedded-cpython", "embedded_cpython", "cpython":
                return .embeddedCPython
            default:
                throw Debian12OracleTestSupport.runnerError("unsupported Python oracle backend: \(backend)")
            }
        }
        return Debian12OracleTestSupport.environmentFlag("MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON")
            ? .hostProcess
            : .none
    }

    #if os(macOS)
    private static func hostPythonExecutableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE"],
           !configured.isEmpty {
            return try executableURL(path: configured, description: "python executable")
        }

        if let url = try? executableURL(path: "/usr/bin/python3", description: "python executable") {
            return url
        }
        throw Debian12OracleTestSupport.runnerError("python3 executable not found; set MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE")
    }

    private static func executableURL(path: String, description: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw Debian12OracleTestSupport.runnerError("\(description) path must be absolute: \(path)")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw Debian12OracleTestSupport.runnerError("\(description) is not executable: \(path)")
        }
        return URL(fileURLWithPath: path)
    }
    #endif

    private static func embeddedCPythonEngine(rootURL: URL) throws -> MSPCPythonEngine {
        let environment = ProcessInfo.processInfo.environment
        guard let libraryPath = environment["MSP_CPYTHON_LIBRARY_PATH"],
              !libraryPath.isEmpty else {
            throw Debian12OracleTestSupport.runnerError("MSP_CPYTHON_LIBRARY_PATH is required for embedded-cpython oracle runs")
        }
        let libraryURL = try existingAbsoluteURL(
            path: libraryPath,
            description: "CPython library"
        )
        let homeURL = try environment["MSP_CPYTHON_HOME"].flatMap { value -> URL? in
            guard !value.isEmpty else {
                return nil
            }
            return try existingAbsoluteURL(
                path: value,
                description: "CPython home"
            )
        }
        return try MSPCPythonEngine(
            library: .path(libraryURL),
            workspaceRootURL: rootURL,
            pythonHomeURL: homeURL
        )
    }

    private static func existingAbsoluteURL(path: String, description: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw Debian12OracleTestSupport.runnerError("\(description) path must be absolute: \(path)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw Debian12OracleTestSupport.runnerError("\(description) path does not exist: \(path)")
        }
        return URL(fileURLWithPath: path)
    }
}
