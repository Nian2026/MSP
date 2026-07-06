import Foundation
import XCTest
import MSPAgentBridge
import MSPCodexApplyPatchRuntime
@testable import MSPPlaygroundApp

final class MSPPlaygroundApplyPatchRuntimeTests: XCTestCase {
    @MainActor
    func testToolDefinitionsAddApplyPatchOnlyWhenExecutorIsConfigured() {
        let defaultTools = MSPPlaygroundAgentRuntime.toolDefinitions(applyPatchEnabled: false)
        let applyPatchTools = MSPPlaygroundAgentRuntime.toolDefinitions(applyPatchEnabled: true)

        XCTAssertEqual(defaultTools.map(\.name), ["exec_command", "write_stdin"])
        XCTAssertEqual(applyPatchTools.map(\.name), ["exec_command", "write_stdin", "apply_patch"])
        XCTAssertFalse(MSPPlaygroundAgentRuntime.promptCacheKey(toolDefinitions: defaultTools).contains("apply_patch"))
        XCTAssertTrue(MSPPlaygroundAgentRuntime.promptCacheKey(toolDefinitions: applyPatchTools).contains("apply_patch"))
    }

    func testDynamicCodexApplyPatchRuntimeReturnsDiffAndSnapshots() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
        }

        let notesURL = workspaceURL.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try "old\n".write(
            to: notesURL.appendingPathComponent("apply_patch_demo.txt"),
            atomically: true,
            encoding: .utf8
        )

        let libraryPath = try Self.dynamicApplyPatchBridgeLibraryPath()
        let executor = try MSPCodexApplyPatchRuntime.makeDynamicLibraryExecutor(
            libraryPath: libraryPath,
            workspaceRoot: workspaceURL.path
        )
        let result = await executor.execute(MSPApplyPatchCall(
            callID: "call_apply_patch",
            patch: """
            *** Begin Patch
            *** Update File: notes/apply_patch_demo.txt
            @@
            -old
            +new
            *** End Patch
            """
        ))

        XCTAssertTrue(result.ok, result.errorMessage ?? result.output)
        XCTAssertEqual(result.changedPaths, ["/notes/apply_patch_demo.txt"])
        let internalContent = try XCTUnwrap(result.internalContent?.objectValue)
        XCTAssertTrue(internalContent["turn_diff"]?.stringValue?.contains("diff --git a/notes/apply_patch_demo.txt b/notes/apply_patch_demo.txt") == true)
        XCTAssertEqual(internalContent["file_snapshots"]?.arrayValue?.count, 1)
        let snapshot = try XCTUnwrap(internalContent["file_snapshots"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(snapshot["before_text"]?.stringValue, "old\n")
        XCTAssertEqual(snapshot["after_text"]?.stringValue, "new\n")
    }

    private static func dynamicApplyPatchBridgeLibraryPath() throws -> String {
        if let configuredPath = ProcessInfo.processInfo.environment["MSP_CODEX_APPLY_PATCH_DYLIB"],
           !configuredPath.isEmpty {
            let expandedPath = NSString(string: configuredPath).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                return expandedPath
            }
            throw NSError(
                domain: "MSPPlaygroundApplyPatchRuntimeTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "MSP_CODEX_APPLY_PATCH_DYLIB does not point to an existing file: \(expandedPath)"
                ]
            )
        }

        let relativePath = "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Artifacts/Build/target/release/libmsp_codex_apply_patch_bridge.dylib"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("dynamic apply_patch bridge library is not built")
    }
}
