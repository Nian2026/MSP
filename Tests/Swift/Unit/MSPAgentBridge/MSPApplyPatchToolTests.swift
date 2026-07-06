import Foundation
import MSPAgentBridge
import MSPCodexApplyPatchRuntime
import XCTest

final class MSPApplyPatchToolTests: XCTestCase {
    func testApplyPatchToolDefinitionMatchesCodexFreeformContract() throws {
        let tool = MSPAgentRequestBuilder.applyPatchToolDefinition

        XCTAssertEqual(tool.type, "custom")
        XCTAssertEqual(tool.name, "apply_patch")
        XCTAssertEqual(
            tool.description,
            "Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON."
        )
        XCTAssertEqual(tool.format?.type, "grammar")
        XCTAssertEqual(tool.format?.syntax, "lark")
        XCTAssertEqual(tool.format?.definition, Self.codexSingleEnvironmentApplyPatchGrammar)

        let data = try JSONEncoder().encode(tool)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "custom")
        XCTAssertEqual(object["name"] as? String, "apply_patch")
        XCTAssertNil(object["parameters"])
        XCTAssertNil(object["strict"])
        let format = try XCTUnwrap(object["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "grammar")
        XCTAssertEqual(format["syntax"] as? String, "lark")
        XCTAssertEqual(format["definition"] as? String, Self.codexSingleEnvironmentApplyPatchGrammar)
    }

    func testApplyPatchToolDefinitionCanIncludeCodexEnvironmentIDGrammar() {
        let grammar = MSPApplyPatchToolSchema.grammar(includeEnvironmentID: true)

        XCTAssertTrue(grammar.contains("start: begin_patch environment_id? hunk+ end_patch"))
        XCTAssertTrue(grammar.contains("environment_id: \"*** Environment ID: \" filename LF"))
        XCTAssertTrue(grammar.contains("update_hunk: \"*** Update File: \" filename LF change_move? change?"))
    }

    func testPackageManifestsIncludeApplyPatchSourcesUnderToolsOwner() throws {
        let root = Self.repositoryRoot()
        let rootManifest = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let implementationManifest = try String(
            contentsOf: root.appendingPathComponent("Implementations/Swift/Package.swift")
        )
        let applyPatchOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/Tools/MSP/apply_patch")
        let codexRuntimeOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/MSPCodexApplyPatchRuntime")
        let misplacedCapabilityOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/MSPAgentBridge/Capabilities/ApplyPatch")
        let linkedRuntimeArtifact = root
            .appendingPathComponent("Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Artifacts/MSPCodexApplyPatchBridge.xcframework")

        XCTAssertTrue(rootManifest.contains(#"path: "Implementations/Swift/Sources""#))
        XCTAssertTrue(implementationManifest.contains(#"path: "Sources""#))
        for manifest in [rootManifest, implementationManifest] {
            XCTAssertTrue(manifest.contains(#""MSPAgentBridge/Capabilities""#))
            XCTAssertTrue(manifest.contains("MSPCodexApplyPatchRuntime"))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/apply_patch/Contract""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/apply_patch/Runtime""#))
            XCTAssertFalse(manifest.contains(#""Tools/MSP/apply_patch/CodexRuntime""#))
            XCTAssertFalse(manifest.contains(#""Tools/MSP/apply_patch/README.md""#))
            XCTAssertFalse(manifest.contains(#""Tools/MSP/apply_patch/Runtime/README.md""#))
        }
        XCTAssertTrue(rootManifest.contains(#""Implementations/Swift/Sources/MSPCodexApplyPatchRuntime""#))
        XCTAssertTrue(implementationManifest.contains(#""Sources/MSPCodexApplyPatchRuntime""#))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applyPatchOwner.appendingPathComponent("Contract/MSPApplyPatchToolSchema.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applyPatchOwner.appendingPathComponent("Runtime/MSPApplyPatchExecution.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applyPatchOwner.appendingPathComponent("Runtime/MSPCodexApplyPatchExecutor.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applyPatchOwner.appendingPathComponent("Runtime/MSPNativeCodexApplyPatchBridge.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: codexRuntimeOwner.appendingPathComponent("MSPCodexApplyPatchRuntime.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: linkedRuntimeArtifact.appendingPathComponent("Info.plist").path
        ))
        let linkedRuntimeReceipt = linkedRuntimeArtifact.appendingPathComponent("BUILD_RECEIPT.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedRuntimeReceipt.path))
        let receipt = try String(contentsOf: linkedRuntimeReceipt, encoding: .utf8)
        XCTAssertTrue(receipt.contains("format=msp-codex-apply-patch-artifact-receipt-v1"))
        XCTAssertTrue(receipt.contains("debug_symbols=stripped"))
        XCTAssertTrue(receipt.contains("path_remap_policy=required"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: linkedRuntimeArtifact.appendingPathComponent("ios-arm64/libmsp_codex_apply_patch_bridge.a").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: linkedRuntimeArtifact.appendingPathComponent("ios-arm64-simulator/libmsp_codex_apply_patch_bridge.a").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Schema/MSPApplyPatchToolSchema.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Runtime/MSPApplyPatchExecution.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Runtime/MSPCodexApplyPatchExecutor.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Runtime/MSPNativeCodexApplyPatchBridge.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: applyPatchOwner.appendingPathComponent("CodexRuntime/MSPCodexApplyPatchRuntime.swift").path
        ))
    }

    func testCustomToolOutputEncodingUsesCustomToolCallOutput() throws {
        let result = MSPAgentToolResult(
            callID: "call_patch",
            name: .applyPatch,
            outputKind: .custom,
            ok: false,
            content: .string("apply_patch runtime is not configured"),
            errorMessage: "apply_patch runtime is not configured"
        )

        let items = try MSPResponsesStreamingModelClient.toolOutputInputItems(from: [result])
        let item = try XCTUnwrap(items.first?.objectValue)
        XCTAssertEqual(item["type"], .string("custom_tool_call_output"))
        XCTAssertEqual(item["call_id"], .string("call_patch"))
        XCTAssertEqual(item["output"], .string("apply_patch runtime is not configured"))
    }

    func testCodexApplyPatchExecutorPassesRawPatchToBridgeAndMapsResponse() async throws {
        let patch = """
        *** Begin Patch
        *** Add File: bridge.txt
        +hello
        *** End Patch
        """
        let bridge = RecordingCodexApplyPatchBridge(response: MSPCodexApplyPatchBridgeResponse(
            exitCode: 0,
            stdout: "Success. Updated the following files:\nA bridge.txt\n",
            stderr: "",
            output: "Success. Updated the following files:\nA bridge.txt\n",
            changedPaths: ["bridge.txt"],
            exactDelta: true
        ))
        let executor = MSPCodexApplyPatchExecutor(
            bridge: bridge,
            workspaceRoot: "/workspace",
            cwd: "/",
            hostPathRedactions: ["/private/workspace"]
        )

        let result = await executor.execute(MSPApplyPatchCall(
            callID: "call_bridge",
            patch: patch
        ))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.output, "Success. Updated the following files:\nA bridge.txt\n")
        XCTAssertEqual(result.changedPaths, ["bridge.txt"])
        XCTAssertEqual(result.exactDelta, true)

        let requests = await bridge.requests
        let requestJSON = try XCTUnwrap(requests.first)
        let requestData = try XCTUnwrap(requestJSON.data(using: .utf8))
        let request = try JSONDecoder().decode(MSPCodexApplyPatchBridgeRequest.self, from: requestData)
        XCTAssertEqual(request.patch, patch)
        XCTAssertEqual(request.cwd, "/")
        XCTAssertEqual(request.workspaceRoot, "/workspace")
        XCTAssertEqual(request.hostPathRedactions, ["/private/workspace"])
    }

    func testNativeCodexApplyPatchBridgeCallsCABIAndFreesResponse() async throws {
        NativeCodexApplyPatchBridgeTestState.reset()
        let bridge = MSPNativeCodexApplyPatchBridge(
            applyPatchJSON: { @Sendable inputPointer, inputLength, outputPointer, outputLength in
                nativeCodexApplyPatchTestJSON(
                    inputPointer: inputPointer,
                    inputLength: inputLength,
                    outputPointer: outputPointer,
                    outputLength: outputLength
                )
            },
            freeBuffer: { @Sendable pointer, length in
                nativeCodexApplyPatchTestFree(pointer: pointer, length: length)
            }
        )
        let request = #"{"patch":"*** Begin Patch\n*** End Patch","cwd":"/","workspaceRoot":"/workspace","hostPathRedactions":[]}"#

        let response = try await bridge.applyPatch(requestJSON: request)

        XCTAssertEqual(NativeCodexApplyPatchBridgeTestState.receivedRequest(), request)
        XCTAssertTrue(NativeCodexApplyPatchBridgeTestState.didFreeBuffer())
        let responseData = try XCTUnwrap(response.data(using: .utf8))
        let decoded = try JSONDecoder().decode(MSPCodexApplyPatchBridgeResponse.self, from: responseData)
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(decoded.output, "Success. Updated the following files:\nA native.txt\n")
        XCTAssertEqual(decoded.changedPaths, ["native.txt"])
        XCTAssertEqual(decoded.exactDelta, true)
    }

    func testNativeCodexApplyPatchBridgeReportsMissingResponsePointer() async throws {
        let bridge = MSPNativeCodexApplyPatchBridge(
            applyPatchJSON: { @Sendable _, _, _, _ in
                0
            },
            freeBuffer: { @Sendable _, _ in }
        )

        do {
            _ = try await bridge.applyPatch(requestJSON: "{}")
            XCTFail("Expected native bridge missing response pointer")
        } catch let error as MSPNativeCodexApplyPatchBridgeError {
            XCTAssertEqual(
                error.localizedDescription,
                "apply_patch native bridge returned a null response pointer"
            )
        }
    }

    func testNativeCodexApplyPatchBridgeReportsCABIStatusFailure() async throws {
        let bridge = MSPNativeCodexApplyPatchBridge(
            applyPatchJSON: { @Sendable _, _, _, _ in
                -7
            },
            freeBuffer: { @Sendable _, _ in }
        )

        do {
            _ = try await bridge.applyPatch(requestJSON: "{}")
            XCTFail("Expected native bridge status failure")
        } catch let error as MSPNativeCodexApplyPatchBridgeError {
            XCTAssertEqual(
                error.localizedDescription,
                "apply_patch native bridge call failed with status -7"
            )
        }
    }

    func testNativeCodexApplyPatchBridgeLoadsDylibWhenConfigured() async throws {
        guard let libraryPath = ProcessInfo.processInfo.environment["MSP_CODEX_APPLY_PATCH_DYLIB"],
              !libraryPath.isEmpty else {
            throw XCTSkip("Set MSP_CODEX_APPLY_PATCH_DYLIB to run native Codex apply_patch dylib coverage.")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-apply-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
        }
        let bridge = try MSPNativeCodexApplyPatchBridge(libraryPath: libraryPath)
        let executor = MSPCodexApplyPatchExecutor(
            bridge: bridge,
            workspaceRoot: workspace.path,
            cwd: "/",
            hostPathRedactions: [workspace.path]
        )
        let patch = """
        *** Begin Patch
        *** Add File: /native-e2e.txt
        +hello from codex
        *** End Patch
        """

        let result = await executor.execute(MSPApplyPatchCall(
            callID: "call_native",
            patch: patch
        ))

        XCTAssertTrue(result.ok, result.output)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("native-e2e.txt"), encoding: .utf8),
            "hello from codex\n"
        )
        XCTAssertEqual(result.changedPaths, ["/native-e2e.txt"])
        XCTAssertEqual(result.exactDelta, true)
    }

    func testCodexApplyPatchRuntimeLinkedFactoryReportsAvailabilityByPlatform() throws {
        #if os(iOS)
        XCTAssertTrue(MSPCodexApplyPatchRuntime.isLinkedRuntimeAvailable)
        throw XCTSkip("Linked Codex apply_patch runtime is expected to be available on iOS when the product is linked.")
        #else
        XCTAssertFalse(MSPCodexApplyPatchRuntime.isLinkedRuntimeAvailable)
        XCTAssertThrowsError(try MSPCodexApplyPatchRuntime.makeLinkedExecutor(
            workspaceRoot: "/workspace"
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Codex apply_patch linked runtime is only available when the native artifact is linked for this platform"
            )
        }
        XCTAssertThrowsError(try MSPCodexApplyPatchRuntime.makeExecutor(
            workspaceRoot: "/workspace"
        ))
        #endif
    }

    func testCodexApplyPatchRuntimeDynamicLibraryFactoryLoadsDylibWhenConfigured() async throws {
        guard let libraryPath = ProcessInfo.processInfo.environment["MSP_CODEX_APPLY_PATCH_DYLIB"],
              !libraryPath.isEmpty else {
            throw XCTSkip("Set MSP_CODEX_APPLY_PATCH_DYLIB to run optional runtime factory dylib coverage.")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-apply-patch-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
        }
        let executor = try MSPCodexApplyPatchRuntime.makeDynamicLibraryExecutor(
            libraryPath: libraryPath,
            workspaceRoot: workspace.path,
            cwd: "/",
            hostPathRedactions: [workspace.path]
        )
        let patch = """
        *** Begin Patch
        *** Add File: /runtime-factory.txt
        +hello from runtime factory
        *** End Patch
        """

        let result = await executor.execute(MSPApplyPatchCall(
            callID: "call_runtime_factory",
            patch: patch
        ))

        XCTAssertTrue(result.ok, result.output)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("runtime-factory.txt"), encoding: .utf8),
            "hello from runtime factory\n"
        )
        XCTAssertEqual(result.changedPaths, ["/runtime-factory.txt"])
        XCTAssertEqual(result.exactDelta, true)
    }

    private static let codexSingleEnvironmentApplyPatchGrammar = """
    start: begin_patch hunk+ end_patch
    begin_patch: "*** Begin Patch" LF
    end_patch: "*** End Patch" LF?

    hunk: add_hunk | delete_hunk | update_hunk
    add_hunk: "*** Add File: " filename LF add_line+
    delete_hunk: "*** Delete File: " filename LF
    update_hunk: "*** Update File: " filename LF change_move? change?

    filename: /(.+)/
    add_line: "+" /(.*)/ LF -> line

    change_move: "*** Move to: " filename LF
    change: (change_context | change_line)+ eof_line?
    change_context: ("@@" | "@@ " /(.+)/) LF
    change_line: ("+" | "-" | " ") /(.*)/ LF
    eof_line: "*** End of File" LF

    %import common.LF
    """

    private static func repositoryRoot(filePath: String = #filePath) -> URL {
        var current = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while current.path != "/" {
            let rootPackage = current.appendingPathComponent("Package.swift")
            let implementationPackage = current.appendingPathComponent("Implementations/Swift/Package.swift")
            if FileManager.default.fileExists(atPath: rootPackage.path),
               FileManager.default.fileExists(atPath: implementationPackage.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

private actor RecordingCodexApplyPatchBridge: MSPCodexApplyPatchBridge {
    private(set) var requests: [String] = []
    private let response: MSPCodexApplyPatchBridgeResponse

    init(response: MSPCodexApplyPatchBridgeResponse) {
        self.response = response
    }

    func applyPatch(requestJSON: String) async throws -> String {
        requests.append(requestJSON)
        let data = try JSONEncoder().encode(response)
        return String(data: data, encoding: .utf8)!
    }
}

private enum NativeCodexApplyPatchBridgeTestState {
    private static let lock = NSLock()
    private static var request: String = ""
    private static var freed = false

    static func reset() {
        lock.withLock {
            request = ""
            freed = false
        }
    }

    static func record(request: String) {
        lock.withLock {
            self.request = request
        }
    }

    static func markFreed() {
        lock.withLock {
            freed = true
        }
    }

    static func receivedRequest() -> String {
        lock.withLock { request }
    }

    static func didFreeBuffer() -> Bool {
        lock.withLock { freed }
    }
}

private func nativeCodexApplyPatchTestJSON(
    inputPointer: UnsafePointer<UInt8>?,
    inputLength: Int,
    outputPointer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    outputLength: UnsafeMutablePointer<Int>?
) -> Int32 {
    if let inputPointer {
        let input = UnsafeBufferPointer(start: inputPointer, count: inputLength)
        NativeCodexApplyPatchBridgeTestState.record(
            request: String(decoding: input, as: UTF8.self)
        )
    }
    let response = """
    {"exitCode":0,"stdout":"Success. Updated the following files:\\nA native.txt\\n","stderr":"","output":"Success. Updated the following files:\\nA native.txt\\n","changedPaths":["native.txt"],"exactDelta":true}
    """
    let bytes = Array(response.utf8)
    let responsePointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
    responsePointer.initialize(from: bytes, count: bytes.count)
    outputPointer?.pointee = responsePointer
    outputLength?.pointee = bytes.count
    return 0
}

private func nativeCodexApplyPatchTestFree(
    pointer: UnsafeMutablePointer<UInt8>?,
    length: Int
) {
    NativeCodexApplyPatchBridgeTestState.markFreed()
    pointer?.deallocate()
}
