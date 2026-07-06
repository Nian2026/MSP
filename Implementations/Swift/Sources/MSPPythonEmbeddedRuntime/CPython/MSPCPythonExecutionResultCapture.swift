import Foundation
import MSPPythonRuntime

struct MSPCPythonCapturedResult: Decodable {
    var stdoutB64: String
    var stderrB64: String
    var exitCode: Int32

    var stdoutData: Data {
        Data(base64Encoded: stdoutB64) ?? Data()
    }

    var stderrData: Data {
        Data(base64Encoded: stderrB64) ?? Data()
    }

    enum CodingKeys: String, CodingKey {
        case stdoutB64 = "stdout_b64"
        case stderrB64 = "stderr_b64"
        case exitCode = "exit_code"
    }
}

extension MSPCPythonEngine {
    func outputPathSanitizer(
        prepared: MSPCPythonPreparedExecution
    ) -> MSPPythonOutputPathSanitizer {
        MSPPythonOutputPathSanitizer(
            workspaceRootURL: workspaceRootURL,
            runtimeDirectoryMappings: [
                (prepared.vfsBrokerDirectoryURL, "/tmp"),
                (prepared.vfsMaterializedDirectoryURL, "/tmp"),
                (prepared.brokerDirectoryURL, "/tmp"),
                (prepared.resultURL.deletingLastPathComponent(), "/tmp")
            ],
            runtimeFileMappings: [
                (prepared.resultURL, "/tmp/\(prepared.resultURL.lastPathComponent)")
            ]
        )
    }

    func sanitizedExecutionResult(
        _ result: MSPCPythonCapturedResult,
        prepared: MSPCPythonPreparedExecution
    ) -> MSPPythonEmbeddedExecutionResult {
        let sanitizer = outputPathSanitizer(prepared: prepared)
        return MSPPythonEmbeddedExecutionResult(
            stdoutData: sanitizer.sanitize(result.stdoutData),
            stderrData: sanitizer.sanitize(result.stderrData),
            exitCode: result.exitCode
        )
    }
}
