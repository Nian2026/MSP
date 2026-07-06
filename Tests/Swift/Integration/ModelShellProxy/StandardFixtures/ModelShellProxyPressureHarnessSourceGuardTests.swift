import Foundation
import XCTest

final class ModelShellProxyPressureHarnessSourceGuardTests: XCTestCase {
    func testRealModelPressureHarnessHasHardFeedbackAndNoFirstPromptDisclosure() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let e2eURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("MSPPlaygroundApp")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")

        let runner = try String(contentsOf: e2eURL.appendingPathComponent("run-real-model-pressure.sh"), encoding: .utf8)
        assertContainsAll(runner, [
            "REQUIRED_MODEL=\"gpt-5.5\"",
            "export PYTHONDONTWRITEBYTECODE=1",
            "require_env MSP_PLAYGROUND_MODEL_BASE_URL",
            "require_env MSP_PLAYGROUND_MODEL_API_KEY",
            "require_env MSP_PLAYGROUND_MODEL",
            "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the real-model pressure suite",
            "MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH",
            "MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH",
            "MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON",
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
            "MSP_PLAYGROUND_PRESSURE_RESET_APP",
            "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
            "msp_pressure_prompt_contract.py",
            "MSP_PLAYGROUND_E2E_RESET_APP=\"$RESET_APP\"",
            "reject_true_env MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
            "reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
            "require_enabled_setting MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
            "require_enabled_setting MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
            "require_enabled_setting MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
            "require_enabled_setting MSP_PLAYGROUND_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP",
            "real-model-ui-pressure.lock",
            "MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD",
            "refusing to run concurrently",
            "REQUIRED_FINAL_SENTINELS",
            "--require-provider-smoke",
            "--provider-smoke-request",
            "--provider-smoke-response",
            "--required-model \"$REQUIRED_MODEL\"",
            "--model \"$MSP_PLAYGROUND_MODEL\"",
            "provider-smoke-request.redacted.json",
            "provider-smoke-response.json",
            "run-shell-diagnostic.sh",
            "verify-real-model-pressure-log.py"
        ], label: "pressure runner")

        let photoSorterPressureRunnerURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("PhotoSorter")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("run-real-model-pressure.sh")
        let photoSorterPressureRunner = try String(contentsOf: photoSorterPressureRunnerURL, encoding: .utf8)
        assertContainsAll(photoSorterPressureRunner, [
            "REQUIRED_MODEL=\"gpt-5.5\"",
            "export PYTHONDONTWRITEBYTECODE=1",
            "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the real-model pressure suite",
            "--require-provider-smoke",
            "--provider-smoke-request",
            "--provider-smoke-response",
            "--required-model \"$REQUIRED_MODEL\"",
            "--model \"$MSP_PLAYGROUND_MODEL\"",
            "reject_true_env MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
            "require_enabled_setting MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
            "require_enabled_setting MSP_PHOTOSORTER_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP",
            "msp_pressure_prompt_contract.py",
            "provider-smoke-request.redacted.json",
            "provider-smoke-response.json"
        ], label: "PhotoSorter pressure runner")

        let playgroundProviderSmoke = try String(contentsOf: e2eURL.appendingPathComponent("check-openai-responses-provider.sh"), encoding: .utf8)
        let photoSorterProviderSmokeURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("PhotoSorter")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("check-openai-responses-provider.sh")
        let photoSorterProviderSmoke = try String(contentsOf: photoSorterProviderSmokeURL, encoding: .utf8)
        for (label, providerSmoke) in [("MSPPlaygroundApp", playgroundProviderSmoke), ("PhotoSorter", photoSorterProviderSmoke)] {
            assertContainsAll(providerSmoke, [
                "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
                "secrets.token_hex(8)",
                "MSP_PROVIDER_OK_${NONCE}",
                "Return exactly and only this string",
                "ACTUAL_OUTPUT",
                "output_text.strip()",
                "sys.exit(0)",
                ".object == \"response\"",
                ".id | type == \"string\" and length > 0",
                "provider smoke response text mismatch",
                "nonce=$NONCE"
            ], label: "\(label) provider smoke")
        }

        let e2eRunner = try String(contentsOf: e2eURL.appendingPathComponent("run-real-model-e2e.sh"), encoding: .utf8)
        assertContainsAll(e2eRunner, [
            "MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH",
            "embed-cpython-xcframework.sh",
            "MSP_PLAYGROUND_EMBEDDED_CPYTHON_LIBRARY_PATH",
            "INSTALLED_APP_BUNDLE"
        ], label: "real-model E2E runner")

        let embedCPython = try String(contentsOf: e2eURL.appendingPathComponent("embed-cpython-xcframework.sh"), encoding: .utf8)
        assertContainsAll(embedCPython, [
            "mktemp -d",
            "msp-playground-cpython",
            "trap 'rm -rf",
            "ln -s \"$PYTHON_XCFRAMEWORK_PATH\" \"$SAFE_PYTHON_XCFRAMEWORK_PATH\"",
            "while IFS= read -r FULL_EXT",
            "> \"${FULL_EXT%.so}.fwork\""
        ], label: "CPython embed helper")

        let verifier = try String(contentsOf: e2eURL.appendingPathComponent("verify-real-model-pressure-log.py"), encoding: .utf8)
        assertContainsAll(verifier, [
            "Conformance/Scripts/msp_pressure_evidence.py",
            "from msp_pressure_evidence import",
            "verify_pressure_event_log_report",
            "write_json_report",
            "required_final_sentinels",
            "REQUIRED_MODEL",
            "--require-provider-smoke",
            "--provider-smoke-request",
            "--provider-smoke-response",
            "--prompt-file",
            "--model",
            "real-model pressure log passed"
        ], label: "pressure verifier wrapper")

        let scriptsURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
        let pressureEvidenceURL = scriptsURL
            .appendingPathComponent("msp_pressure_evidence.py")
        let pressureContractURL = scriptsURL
            .appendingPathComponent("msp_pressure_contract.py")
        let pressureJSONSupportURL = scriptsURL
            .appendingPathComponent("msp_pressure_json_support.py")
        let pressureEventLogURL = scriptsURL
            .appendingPathComponent("msp_pressure_event_log.py")
        let pressureEventFieldsURL = scriptsURL
            .appendingPathComponent("msp_pressure_event_fields.py")
        let pressureExecSessionContractURL = scriptsURL
            .appendingPathComponent("msp_pressure_exec_session_contract.py")
        let pressureFeedbackEvidenceURL = scriptsURL
            .appendingPathComponent("msp_pressure_feedback_evidence.py")
        let pressureFeedbackJSONURL = scriptsURL
            .appendingPathComponent("msp_pressure_feedback_json.py")
        let pressureModelProvenanceURL = scriptsURL
            .appendingPathComponent("msp_pressure_model_provenance.py")
        let pressureProviderSmokeURL = scriptsURL
            .appendingPathComponent("msp_pressure_provider_smoke.py")
        let pressurePromptDeliveryURL = scriptsURL
            .appendingPathComponent("msp_pressure_prompt_delivery.py")
        let pressurePromptContractURL = scriptsURL
            .appendingPathComponent("msp_pressure_prompt_contract.py")
        let pressureEvidenceForVerifier = try [
            pressureEvidenceURL,
            pressureContractURL,
            pressureJSONSupportURL,
            pressureEventLogURL,
            pressureEventFieldsURL,
            pressureExecSessionContractURL,
            pressureFeedbackEvidenceURL,
            pressureFeedbackJSONURL,
            pressureModelProvenanceURL,
            pressureProviderSmokeURL,
            pressurePromptDeliveryURL,
            pressurePromptContractURL
        ].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        assertContainsAll(pressureEvidenceForVerifier, [
            "can_distinguish_from_regular_linux",
            "leaked_internal_paths",
            "suspicious_outputs",
            "FORBIDDEN_PATTERNS",
            "host_user_path",
            "materialized_path",
            "plain_ios_sandbox_disclosure",
            "plain_sandbox_path_disclosure",
            "plain_msp_disclosure",
            "plain_backend_disclosure",
            "plain_virtual_backend_disclosure",
            "plain_host_backend_disclosure",
            "plain_photo_backend_disclosure",
            "plain_simulator_disclosure",
            "plain_app_container_disclosure",
            "re.IGNORECASE",
            "verify_pressure_event_log_report",
            "pressure suite model is not",
            "model_request_built event is missing",
            "model_request_built count",
            "expected pressure turn count",
            "model_request_built model is not",
            "model_matches_required",
            "model_failures",
            "REQUIRED_PROMPT_FILES",
            "prompt_contract",
            "prompt_contract_evidence",
            "prompt_delivery",
            "prompt_delivery_summary",
            "prompt_delivery_contract",
            "model_response_provenance",
            "model_response_provenance_summary",
            "model_response_completed",
            "model_final_answer_provenance",
            "provider_stream_final_answer",
            "request_layer",
            "runtime_provider",
            "request_layers",
            "request_layers count does not match model_request_built.count",
            "request_layers are not all runtime_provider",
            "model_request_layer",
            "model_request ref is missing",
            "model_request ref was not previously built",
            "model_request_sequence",
            "model_request_run_id",
            "completed_model_request_layers",
            "completed_model_request_refs",
            "final_answer_model_request_layers",
            "final_answer_model_request_refs",
            "final_answer_request_last_user_input_sha256s",
            "final_answer_text_sha256s",
            "text_hash_algorithm",
            "text_sha256",
            "provenance_text_hash_algorithm",
            "provenance_text_sha256",
            "final_answer[{answer_number}].response_id does not match provenance event",
            "final_answer[{answer_number}].provenance_text_length does not match provenance event",
            "final_answer[{answer_number}].text_sha256 does not match text",
            "final_answer[{answer_number}].text_sha256 does not match provenance event",
            "final_answer[{answer_number}].provenance_text_sha256 does not match provenance event",
            "final_answer[{answer_number}].response_id was not previously completed",
            "model_response_provenance final_answer response_id values are not unique",
            "auto_submit_sequence_loaded",
            "prompt_hash_algorithm",
            "prompt_sha256",
            "sha256-utf8",
            "request_user_input_hash_algorithm",
            "request_last_user_input_sha256",
            "model_request_last_user_input_sha256s",
            "model_request_prompt_match_indices",
            "prompt_contract.prompt_count does not match expected final answers",
            "prompt_contract.required_final_sentinels does not match verifier sentinels",
            "prompt_delivery auto_submit prompt_index sequence does not match prompt file order",
            "prompt_delivery auto_submit[{index}].prompt_sha256 does not match prompt file",
            "prompt_delivery model_request_built[{index}].request_last_user_input_sha256 is missing",
            "prompt_delivery model_request_built request_last_user_input_sha256s do not contain prompt hashes in order",
            "prompt_delivery final_answer_request_last_user_input_sha256s do not match prompt file order",
            "expected_prompt_contract_for_suite",
            "sha256",
            "FORBIDDEN_EXECUTION_DISCLOSURES",
            "pressure prompt {index} discloses implementation term before feedback",
            "launcher",
            "runtime",
            "CoreSimulator",
            "app container",
            "PhotoKit",
            "PHAsset",
            "localIdentifier",
            "virtual",
            "内部运行时路径",
            "FINAL_PROMPT_REQUIRED_PHRASES",
            "iOS 沙盒路径",
            "broker 路径",
            "materialized 路径"
        ], label: "shared pressure verifier")
        let pressureEventLog = try String(contentsOf: pressureEventLogURL, encoding: .utf8)
        assertContainsAll(pressureEventLog, [
            "REQUIRED_PROMPT_FILES,",
            "repository_root() / REQUIRED_PROMPT_FILES[name]"
        ], label: "pressure event-log prompt contract bridge")

        let promptsURL = e2eURL.appendingPathComponent("pressure").appendingPathComponent("host-backed-linux-parity-prompts.json")
        let prompts = try JSONDecoder().decode([String].self, from: Data(contentsOf: promptsURL))
        XCTAssertGreaterThanOrEqual(prompts.count, 4)
        for forbidden in ["ios", "msp", "sandbox", "broker", "materialized", "launcher"] {
            XCTAssertFalse(prompts[0].lowercased().contains(forbidden), "first pressure prompt discloses \(forbidden)")
        }
        assertContainsAll(prompts[1], ["nested/", "符号链接", "移动", "删除", "subprocess", "printenv", "PWD", "TMPDIR", "PRESSURE_STATE_CHANGE_DONE"], label: "state-change pressure prompt")
        assertContainsAll(prompts[2], ["2048", "large.txt", "xargs", "stat -c", "Permission denied", "PRESSURE_BULK_PERMISSION_DONE"], label: "bulk/permission pressure prompt")
        assertContainsAll(prompts[prompts.count - 1], ["looks_like_regular_linux", "can_distinguish_from_regular_linux", "leaked_internal_paths"], label: "feedback prompt")

        let mixedPromptsURL = e2eURL.appendingPathComponent("pressure").appendingPathComponent("mixed-backend-linux-parity-prompts.json")
        let mixedPrompts = try JSONDecoder().decode([String].self, from: Data(contentsOf: mixedPromptsURL))
        XCTAssertGreaterThanOrEqual(mixedPrompts.count, 4)
        for forbidden in ["ios", "msp", "sandbox", "broker", "materialized", "launcher", "virtual"] {
            XCTAssertFalse(mixedPrompts[0].lowercased().contains(forbidden), "first mixed pressure prompt discloses \(forbidden)")
        }
        assertContainsAll(mixedPrompts[0], ["/tmp", "/docs", "/media", "host.txt", "clip.txt", "mixed-host-output.txt", "mixed-media-output.txt", "MIXED_WORKSPACE_TASK_DONE"], label: "mixed pressure prompt")
        assertContainsAll(mixedPrompts[1], ["pathlib", "subprocess", "printenv", "PWD", "TMPDIR", "find /media", "cat /media/mixed-media-output.txt", "missing-media-error.txt", "MIXED_PYTHON_SUBPROCESS_DONE"], label: "mixed Python pressure prompt")
        assertContainsAll(mixedPrompts[2], ["移动", "删除", "32", "xargs", "wc -c", "MIXED_MOVE_DELETE_BATCH_DONE"], label: "mixed state pressure prompt")
        assertContainsAll(mixedPrompts[mixedPrompts.count - 1], ["looks_like_regular_linux", "can_distinguish_from_regular_linux", "leaked_internal_paths", "/docs", "/media"], label: "mixed feedback prompt")

        let pressurePromptSuites: [(label: String, url: URL)] = [
            ("host-backed", promptsURL),
            ("exec-session", e2eURL.appendingPathComponent("pressure").appendingPathComponent("exec-session-parity-prompts.json")),
            ("mixed-backend", mixedPromptsURL),
            ("photosorter-virtual", rootURL
                .appendingPathComponent("Examples")
                .appendingPathComponent("iOS")
                .appendingPathComponent("PhotoSorter")
                .appendingPathComponent("Tools")
                .appendingPathComponent("E2E")
                .appendingPathComponent("pressure")
                .appendingPathComponent("photosorter-virtual-workspace-prompts.json")),
            ("photosorter-exec-session", rootURL
                .appendingPathComponent("Examples")
                .appendingPathComponent("iOS")
                .appendingPathComponent("PhotoSorter")
                .appendingPathComponent("Tools")
                .appendingPathComponent("E2E")
                .appendingPathComponent("pressure")
                .appendingPathComponent("photosorter-exec-session-parity-prompts.json"))
        ]
        let forbiddenTaskDisclosure = [
            "ios", "msp", "sandbox", "沙盒", "broker", "materialized", "launcher", "virtual",
            "虚拟", "photokit", "phasset", "localIdentifier", "照片库后端", "cache", "真实宿主目录", "内部运行时路径",
            "p_python_", "env_prefix_count", "path_marker_count", "coresimulator", "containers/data/application",
            "/users/", "/volumes/", "/private/var/", "subprocess-", "vfs-", "materiali"
        ]
        let requiredFeedbackTerms = [
            "不要猜测底层环境",
            "只根据前面可见输出",
            "真 Linux 工作区区分",
            "looks_like_regular_linux",
            "can_distinguish_from_regular_linux",
            "suspicious_outputs",
            "leaked_internal_paths",
            "不像普通 Linux 命令输出",
            "不是工作区路径",
            "用户刚创建的文件路径",
            "本身不是路径",
            "iOS 沙盒路径",
            "broker 路径",
            "materialized 路径",
            "真实底层路径",
            "数据中转路径",
            "按需生成的临时副本路径",
            "疑似构建产物路径",
            "框架路径",
            "运行器路径",
            "临时实现路径",
            "其他底层实现路径"
        ]
        for suite in pressurePromptSuites {
            let prompts = try JSONDecoder().decode([String].self, from: Data(contentsOf: suite.url))
            XCTAssertGreaterThanOrEqual(prompts.count, 4, "\(suite.label) prompt suite is too small")
            for (index, prompt) in prompts.dropLast().enumerated() {
                let normalizedPrompt = prompt.lowercased()
                for forbidden in forbiddenTaskDisclosure {
                    XCTAssertFalse(normalizedPrompt.contains(forbidden.lowercased()), "\(suite.label) task prompt \(index) discloses \(forbidden)")
                }
            }
            switch suite.label {
            case "exec-session", "photosorter-exec-session":
                assertContainsAll(prompts[1], ["PTY_PWD", "PTY_TMPDIR", "PTY_ENV_SUMMARY_DONE", "EXEC_PTY_PYTHON_DONE"], label: "\(suite.label) PTY Python pressure prompt")
            case "photosorter-virtual":
                assertContainsAll(prompts[1], ["pathlib", "subprocess", "printenv", "PWD", "TMPDIR", "find /图库", "PHOTO_PYTHON_DONE"], label: "\(suite.label) Python pressure prompt")
            default:
                break
            }
            let feedbackPrompt = prompts[prompts.count - 1]
            assertContainsAll(feedbackPrompt, requiredFeedbackTerms, label: "\(suite.label) feedback prompt")
        }
    }

    func testRealModelPressureMatrixHarnessRequiresAllWorkspaceClasses() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let scriptsURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
        let matrixRunnerURL = scriptsURL
            .appendingPathComponent("run_real_model_pressure_matrix.sh")
        let matrixVerifierURL = scriptsURL
            .appendingPathComponent("verify_real_model_pressure_matrix.py")
        let pressureEvidenceURL = scriptsURL
            .appendingPathComponent("msp_pressure_evidence.py")
        let pressureContractURL = scriptsURL
            .appendingPathComponent("msp_pressure_contract.py")
        let pressureJSONSupportURL = scriptsURL
            .appendingPathComponent("msp_pressure_json_support.py")
        let pressureEventLogURL = scriptsURL
            .appendingPathComponent("msp_pressure_event_log.py")
        let pressureEventFieldsURL = scriptsURL
            .appendingPathComponent("msp_pressure_event_fields.py")
        let pressureExecSessionContractURL = scriptsURL
            .appendingPathComponent("msp_pressure_exec_session_contract.py")
        let pressureFeedbackEvidenceURL = scriptsURL
            .appendingPathComponent("msp_pressure_feedback_evidence.py")
        let pressureFeedbackJSONURL = scriptsURL
            .appendingPathComponent("msp_pressure_feedback_json.py")
        let pressureModelProvenanceURL = scriptsURL
            .appendingPathComponent("msp_pressure_model_provenance.py")
        let pressureProviderSmokeURL = scriptsURL
            .appendingPathComponent("msp_pressure_provider_smoke.py")
        let matrixSummaryURL = scriptsURL
            .appendingPathComponent("msp_pressure_matrix_summary.py")

        let matrixRunner = try String(contentsOf: matrixRunnerURL, encoding: .utf8)
        for required in [
            "REQUIRED_MODEL=\"gpt-5.5\"",
            "require_env MSP_PLAYGROUND_MODEL_BASE_URL",
            "require_env MSP_PLAYGROUND_MODEL_API_KEY",
            "require_env MSP_PLAYGROUND_MODEL",
            "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the real-model pressure matrix",
            "reject_true_env MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
            "reject_true_env MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
            "reject_zero_env MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
            "reject_zero_env MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
            "reject_zero_env MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
            "reject_zero_env MSP_PLAYGROUND_PRESSURE_RESET_APP",
            "reject_zero_env MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
            "reject_zero_env MSP_PHOTOSORTER_PRESSURE_RESET_APP",
            "reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
            "reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
            "reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT",
            "reject_nonempty_env MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
            "reject_nonempty_env MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
            "REQUESTED_OUT_ROOT=\"${MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR:-}\"",
            "MSP_FINAL_EXEC_SESSION_GATE_ACTIVE",
            "MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR is required when the matrix is launched from the final release gate",
            "--required-model \"$REQUIRED_MODEL\"",
            "--model \"$MSP_PLAYGROUND_MODEL\"",
            "REQUIRED_SUITES=(host-backed exec-session mixed-backend photosorter-virtual photosorter-exec-session)",
            "REQUIRED_SUITES_CSV",
            "MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR",
            "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES",
            "MSP_REAL_MODEL_PRESSURE_MATRIX_TMPDIR",
            "export TMPDIR=\"$MATRIX_TMPDIR/\"",
            "MATRIX_TMPDIR_ALIAS",
            "msp-real-model-matrix-tmp-$STAMP",
            "--root \"$OUT_ROOT\"",
            "$OUT_ROOT/builds/playground",
            "$OUT_ROOT/builds/photosorter",
            "real-model-pressure-matrix.lock",
            "real-model-ui-pressure.lock",
            "MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD",
            "refusing to run concurrently",
            "MSP_PLAYGROUND_WORKSPACE_PROFILE=mixed-backend",
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=1",
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=1",
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=1",
            "MSP_PLAYGROUND_PRESSURE_RESET_APP=1",
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=1",
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP=1",
            "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
            "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
            "validate_requested_suites",
            "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES must include every required suite",
            "verify_real_model_pressure_matrix.py",
            "pressure-matrix-report.json"
        ] {
            XCTAssertTrue(matrixRunner.contains(required), "pressure matrix runner missing \(required)")
        }

        let matrixVerifier = try [
            matrixVerifierURL,
            pressureEvidenceURL,
            pressureContractURL,
            pressureJSONSupportURL,
            pressureEventLogURL,
            pressureEventFieldsURL,
            pressureExecSessionContractURL,
            pressureFeedbackEvidenceURL,
            pressureModelProvenanceURL,
            pressureProviderSmokeURL,
            matrixSummaryURL
        ].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for required in [
            "REQUIRED_PRESSURE_SUITES",
            "host-backed",
            "exec-session",
            "mixed-backend",
            "photosorter-virtual",
            "photosorter-exec-session",
            "PRESSURE_TASK_DONE",
            "EXEC_YIELD_POLL_DONE",
            "MIXED_WORKSPACE_TASK_DONE",
            "PHOTO_ROOT_DONE",
            "provider_smoke",
            "prompt_contract",
            "prompt_delivery",
            "PROMPT_CONTRACT_CORE_FIELDS",
            "PROMPT_DELIVERY_CORE_FIELDS",
            "MODEL_RESPONSE_PROVENANCE_CORE_FIELDS",
            "compare_event_log_core_fields",
            "validate_matrix_prompt_contract",
            "validate_matrix_prompt_delivery",
            "validate_matrix_model_response_provenance",
            "path does not match canonical prompt file",
            "sha256 does not match canonical prompt file",
            "prompt_sha256s does not match canonical prompt file",
            "model_response_provenance",
            "model_response_completed_count is below required pressure turn count",
            "final_answer_response_ids include ids not completed by provider stream",
            "final_answer_model_request_refs include refs not completed by provider stream",
            "final_answer_request_last_user_input_sha256s does not match required pressure turn count",
            "final_answer_text_sha256s does not match required pressure turn count",
            "final_answer_sources are not all provider_stream_final_answer",
            "auto_submit_count does not match required pressure turn count",
            "model_request_last_user_input_sha256s do not match canonical prompt order",
            "model_request_prompt_match_indices does not cover every prompt",
            "final_answer_request_last_user_input_sha256s do not match canonical prompt order",
            "required_final_sentinels does not match final gate contract",
            "provider_smoke.checked is not true",
            "artifact does not exist",
            "EXPECTED_PROVIDER_SMOKE_RELATIVE_PATHS",
            "provider_smoke_artifact_matches_canonical_path",
            "provider_smoke.{key} artifact does not match canonical suite path",
            "provider_smoke.expected_output is not a dynamic MSP_PROVIDER_OK nonce",
            "provider_smoke actual output does not match expected output",
            "canonical_suite_report_path",
            "suite_path_failures_for_root",
            "suite path does not match canonical matrix root path",
            "duplicate_suite_names",
            "duplicate pressure suite(s)",
            "model_matches_required",
            "suite report model is not",
            "suite report model_failures",
            "model_request_built.expected_count must be positive",
            "model_request_built.expected_count does not match required pressure turn count",
            "model_request_built.count is below expected_count",
            "model_request_built.models is not exactly",
            "model_request_built.all_match_required is not true",
            "provider_smoke.request_model is not",
            "provider_smoke request artifact model is not",
            "pressure matrix model is not",
            "pressure matrix missing_suites",
            "pressure matrix {suite} name does not match suite id",
            "looks_like_regular_linux",
            "can_distinguish_from_regular_linux",
            "notes",
            "EXPECTED_FEEDBACK_FIELDS",
            "require_feedback_schema",
            "missing required field(s)",
            "has unexpected field(s)",
            ".notes must be a non-empty string",
            "scanner_leaks",
            "suite report passed flag is not true",
            "suite report contains failures",
            "pressure matrix suites keys do not match required pressure suites",
            "matrix_passed"
        ] {
            XCTAssertTrue(matrixVerifier.contains(required), "pressure matrix verifier missing \(required)")
        }

        let pressureEvidence = try [
            pressureEvidenceURL,
            pressureContractURL,
            pressureJSONSupportURL,
            pressureEventLogURL,
            pressureEventFieldsURL,
            pressureFeedbackEvidenceURL,
            pressureFeedbackJSONURL
        ].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for required in [
            "FORBIDDEN_PATTERNS",
            "host_user_path",
            "materialized_path",
            "plain_ios_sandbox_disclosure",
            "plain_sandbox_path_disclosure",
            "plain_msp_disclosure",
            "plain_backend_disclosure",
            "plain_virtual_backend_disclosure",
            "plain_host_backend_disclosure",
            "plain_photo_backend_disclosure",
            "plain_simulator_disclosure",
            "plain_app_container_disclosure",
            "structured_feedback_window",
            "is_structured_feedback_text",
            "validate_feedback_observed_quotes",
            "validate_feedback_leak_quotes",
            "validate_feedback_suspicious_output_quotes",
            "validate_feedback_negative_evidence",
            "require_feedback_schema",
            "feedback answer must be a raw JSON object, not Markdown fenced JSON",
            "model reported {report_label} was not quoted from observed output",
            "model negative Linux feedback did not include suspicious_outputs",
            "\"leaked internal path\"",
            "\"suspicious output\"",
            "label.startswith(\"plain_\")",
            "EXPECTED_EVENT_LOG_RELATIVE_PATH",
            "event must be a JSON object",
            "blank JSONL event line is not allowed",
            "event must have a non-empty string event name",
            "event timestamp is missing",
            "event timestamp must be a string",
            "event timestamp must be an ISO-8601 UTC timestamp",
            "event timestamp moved backwards",
            "event fields are missing",
            "event fields must be a JSON object",
            "event field values must be strings",
            "event has unexpected top-level field(s)",
            "TEXT_LIKE_EVENT_FIELD_NAMES",
            "model-visible text field is not registered for event",
            "stdout",
            "stderr",
            "output_text",
            "visible_text",
            "event_log artifact does not match canonical suite path",
            "event_log scanner found model-visible internal path leaks",
            "scanner found model-visible internal path leaks",
            "leak_kind_summary"
        ] {
            XCTAssertTrue(pressureEvidence.contains(required), "pressure evidence scanner missing \(required)")
        }
    }

    private func assertContainsAll(_ text: String, _ requiredValues: [String], label: String) {
        for required in requiredValues {
            XCTAssertTrue(text.contains(required), "\(label) missing \(required)")
        }
    }
}
