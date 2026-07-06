import Foundation
@testable import MSPPythonEmbeddedRuntime
import XCTest

final class MSPCPythonBootstrapSourceTests: XCTestCase {
    func testBootstrapSourceEmbedsPayloadAndSharedVFSBootstrap() throws {
        let payload = MSPCPythonExecutionPayload(
            mode: "command",
            moduleName: nil,
            sourceB64: Data("print('ok')".utf8).base64EncodedString(),
            filename: "<string>",
            argv: ["-c"],
            stdinB64: Data("stdin".utf8).base64EncodedString(),
            environment: ["PYTHONUTF8": "1"],
            fileCreationMask: 0o022,
            resultPath: "/tmp/result.json",
            subprocessBrokerDir: "/tmp/subprocess-broker",
            vfsBrokerDir: "/tmp/vfs-broker",
            vfsMaterializedDir: "/tmp/vfs-materialized",
            workspaceRootPath: "/workspace",
            virtualCurrentDirectory: "/tmp"
        )

        let source = try MSPCPythonBootstrapSource.makeSource(payload: payload)
        XCTAssertFalse(source.contains("__MSP_BOOTSTRAP_BODY_B64__"))

        let body = try Self.decodedBase64Literal(
            after: "_msp_cpython_bootstrap_base64.b64decode(",
            in: source
        )
        XCTAssertFalse(body.contains("__MSP_PAYLOAD_B64__"))
        XCTAssertFalse(body.contains("__MSP_VFS_BOOTSTRAP_SOURCE__"))
        XCTAssertTrue(body.contains("_msp_install_python_vfs()"))
        XCTAssertTrue(body.contains("_msp_restore_python_vfs()"))
        XCTAssertTrue(body.contains("def _msp_cpython_run_nested_python"))
        XCTAssertTrue(body.contains("pending_writeback_state = _msp_vfs_capture_pending_writeback_state()"))
        XCTAssertTrue(body.contains("_msp_vfs_flush_pending_writebacks(pending_writeback_state)"))

        let payloadJSON = try Self.decodedBase64Literal(
            after: "_msp_payload = _msp_json.loads(_msp_base64.b64decode(",
            in: body
        )
        let payloadObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payloadObject["argv"] as? [String], ["-c"])
        XCTAssertEqual(payloadObject["source_b64"] as? String, Data("print('ok')".utf8).base64EncodedString())
        XCTAssertEqual(payloadObject["stdin_b64"] as? String, Data("stdin".utf8).base64EncodedString())
        XCTAssertEqual(payloadObject["mode"] as? String, "command")
        XCTAssertEqual(payloadObject["result_path"] as? String, "/tmp/result.json")
        XCTAssertEqual(payloadObject["subprocess_broker_dir"] as? String, "/tmp/subprocess-broker")
        XCTAssertEqual(payloadObject["environment"] as? [String: String], ["PYTHONUTF8": "1"])
        XCTAssertEqual(payloadObject["file_creation_mask"] as? Int, 0o022)
        XCTAssertEqual(payloadObject["vfs_broker_dir"] as? String, "/tmp/vfs-broker")
        XCTAssertEqual(payloadObject["vfs_materialized_dir"] as? String, "/tmp/vfs-materialized")
        XCTAssertEqual(payloadObject["workspace_root_path"] as? String, "/workspace")
        XCTAssertEqual(payloadObject["virtual_cwd"] as? String, "/tmp")
    }

    private static func decodedBase64Literal(after marker: String, in source: String) throws -> String {
        guard let markerRange = source.range(of: marker) else {
            XCTFail("Missing marker \(marker)")
            return ""
        }
        let suffix = source[markerRange.upperBound...]
        guard let openQuote = suffix.firstIndex(of: "\"") else {
            XCTFail("Missing opening quote after marker \(marker)")
            return ""
        }
        let quotedSuffix = suffix[suffix.index(after: openQuote)...]
        guard let closeQuote = quotedSuffix.firstIndex(of: "\"") else {
            XCTFail("Missing closing quote after marker \(marker)")
            return ""
        }
        let literal = String(quotedSuffix[..<closeQuote])
        let data = try XCTUnwrap(Data(base64Encoded: literal))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
