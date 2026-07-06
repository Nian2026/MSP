import XCTest
@testable import MSPPlaygroundApp

final class MSPPlaygroundViewModelTests: XCTestCase {
    @MainActor
    func testReloadModelConfigurationRefreshesStaleInMemoryConfiguration() {
        var storedConfiguration = Self.configuration(
            baseURL: "https://stored.example.test/v1",
            apiKey: "stored-key",
            modelID: "stored-model"
        )
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                storedConfiguration
            },
            saveModelConfiguration: { configuration in
                storedConfiguration = configuration
            },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )

        viewModel.modelConfiguration = Self.configuration(
            baseURL: "https://api.openai.com/v1",
            apiKey: "",
            modelID: "gpt-5"
        )
        storedConfiguration = Self.configuration(
            baseURL: "https://persisted.example.test/v1/responses",
            apiKey: "persisted-key",
            modelID: "gpt-5.5"
        )

        let reloaded = viewModel.reloadModelConfiguration()

        XCTAssertEqual(reloaded.baseURL?.absoluteString, "https://persisted.example.test/v1/responses")
        XCTAssertEqual(reloaded.apiKey, "persisted-key")
        XCTAssertEqual(reloaded.modelID, "gpt-5.5")
        XCTAssertEqual(viewModel.modelConfiguration, reloaded)
    }

    @MainActor
    func testSaveModelConfigurationReloadsCanonicalStoredConfiguration() {
        var storedConfiguration = Self.configuration(
            baseURL: "https://stored.example.test/v1",
            apiKey: "stored-key",
            modelID: "stored-model"
        )
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                storedConfiguration
            },
            saveModelConfiguration: { configuration in
                storedConfiguration = configuration
            },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )

        viewModel.modelConfiguration = MSPModelConfiguration(
            providerName: " Provider ",
            baseURL: URL(string: "https://saved.example.test/v1"),
            apiKey: " saved-key ",
            modelID: " saved-model ",
            apiStyle: " responses ",
            endpointType: " openai-response ",
            endpointPathOverride: " /custom/responses ",
            reasoningEffort: " high ",
            verbosity: " low "
        )

        XCTAssertTrue(viewModel.saveModelConfiguration())
        XCTAssertEqual(storedConfiguration.baseURL?.absoluteString, "https://saved.example.test/v1")
        XCTAssertEqual(storedConfiguration.apiKey, "saved-key")
        XCTAssertEqual(storedConfiguration.modelID, "saved-model")
        XCTAssertEqual(storedConfiguration.reasoningEffort, "high")
        XCTAssertEqual(storedConfiguration.verbosity, "low")
        XCTAssertEqual(viewModel.modelConfiguration, storedConfiguration)
    }

    @MainActor
    func testApplyPatchDiffPreviewTextFallsBackToPatchInputWhenRuntimeDiffIsMissing() {
        let patchInput = """
        *** Begin Patch
        *** Update File: notes/apply_patch_demo.txt
        @@
         旧内容
        +本次修改：再次使用 apply_patch 随便追加一行内容。
        *** End Patch
        """

        let diff = MSPPlaygroundViewModel.applyPatchDiffPreviewText(
            fromPatchInput: patchInput,
            changedPaths: ["/notes/apply_patch_demo.txt"]
        )

        XCTAssertNotNil(diff)
        XCTAssertTrue(diff?.contains("diff --git a/notes/apply_patch_demo.txt b/notes/apply_patch_demo.txt") == true)
        XCTAssertTrue(diff?.contains("@@") == true)
        XCTAssertTrue(diff?.contains("+本次修改：再次使用 apply_patch 随便追加一行内容。") == true)
        XCTAssertFalse(diff?.contains("*** Begin Patch") == true)
    }

    func testStructuredShellJSONLeakIgnoresModelAuthoredPythonDictionaryKeys() {
        let pythonSource = """
        def run_cmd(cmd):
            p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return {
                "cmd": " ".join(cmd),
                "returncode": p.returncode,
                "stdout": p.stdout,
                "stderr": p.stderr,
            }
        """

        XCTAssertFalse(MSPPlaygroundViewModel.containsStructuredShellJSONLeak(in: pythonSource))
    }

    func testStructuredShellJSONLeakDetectsRenderedInternalResultObject() {
        let leakedToolResult = """
        {"stdout":"done\\n","stderr":"","exit_code":0}
        """

        XCTAssertTrue(MSPPlaygroundViewModel.containsStructuredShellJSONLeak(in: leakedToolResult))
    }

    private static func configuration(
        baseURL: String,
        apiKey: String,
        modelID: String
    ) -> MSPModelConfiguration {
        MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: baseURL),
            apiKey: apiKey,
            modelID: modelID,
            apiStyle: "responses",
            endpointType: "openai-response",
            endpointPathOverride: "/v1/responses",
            reasoningEffort: "medium",
            verbosity: "medium"
        )
    }
}
