import Foundation
import XCTest

final class ModelShellProxyPressureLogVerifierSentinelConformanceTests: ModelShellProxyPressureLogVerifierTestCase {
    func testRealModelPressureVerifierAcceptsDistinctRequiredSentinelFinalAnswers() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-multi-sentinel")
        defer { removeTemporaryURL(rootURL) }
        let multiSentinelLog = rootURL.appendingPathComponent("multi-sentinel.jsonl")
        try writePressureEvents(mixedSentinelEvents(), to: multiSentinelLog)

        let multiSentinel = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: multiSentinelLog,
            extraArguments: mixedSentinelArguments()
        )

        XCTAssertEqual(multiSentinel.exitCode, 0, multiSentinel.stderr)
    }

    func testRealModelPressureVerifierRejectsSharedSentinelFinalAnswer() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-shared-sentinel")
        defer { removeTemporaryURL(rootURL) }
        let sharedSentinelFinalAnswerLog = rootURL.appendingPathComponent("shared-sentinel-final-answer.jsonl")
        try writePressureEvents([
            pressureToolStarted("find /tmp /docs /media -maxdepth 1 -type f"),
            pressureToolCompleted(stdout: "/tmp/a\n/docs/b\n/media/c\n"),
            pressureFinalAnswer("""
            first mixed step
            MIXED_WORKSPACE_TASK_DONE
            MIXED_PYTHON_SUBPROCESS_DONE
            MIXED_MOVE_DELETE_BATCH_DONE
            """),
            pressureFinalAnswer("completed mixed pressure step 2"),
            pressureFinalAnswer("completed mixed pressure step 3"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"all mixed workspace outputs matched Linux expectations"}
            """)
        ], to: sharedSentinelFinalAnswerLog)

        let sharedSentinelFinalAnswer = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: sharedSentinelFinalAnswerLog,
            extraArguments: mixedSentinelArguments()
        )

        XCTAssertNotEqual(sharedSentinelFinalAnswer.exitCode, 0)
        XCTAssertTrue(
            sharedSentinelFinalAnswer.stderr.contains("completion sentinels share one final answer"),
            sharedSentinelFinalAnswer.stderr
        )
    }

    func testRealModelPressureVerifierRejectsExtraFinalAnswerWithoutSentinel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-extra-final-answer")
        defer { removeTemporaryURL(rootURL) }
        let extraFillerFinalAnswerLog = rootURL.appendingPathComponent("extra-filler-final-answer.jsonl")
        var events = mixedSentinelEvents()
        events.insert(pressureFinalAnswer("extra final answer without a required sentinel"), at: 5)
        try writePressureEvents(events, to: extraFillerFinalAnswerLog)

        let extraFillerFinalAnswer = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: extraFillerFinalAnswerLog,
            extraArguments: mixedSentinelArguments()
        )

        XCTAssertNotEqual(extraFillerFinalAnswer.exitCode, 0)
        XCTAssertTrue(
            extraFillerFinalAnswer.stderr.contains("expected no more than 4 final answers; got 5"),
            extraFillerFinalAnswer.stderr
        )
        XCTAssertTrue(
            extraFillerFinalAnswer.stderr.contains("completion final_answer has no required sentinel"),
            extraFillerFinalAnswer.stderr
        )
    }

    func testRealModelPressureVerifierRejectsMissingRequiredSentinel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-missing-sentinel")
        defer { removeTemporaryURL(rootURL) }
        let multiSentinelLog = rootURL.appendingPathComponent("multi-sentinel.jsonl")
        try writePressureEvents(mixedSentinelEvents(), to: multiSentinelLog)

        let missingSentinel = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: multiSentinelLog,
            extraArguments: [
                "--expected-final-answers", "4",
                "--required-final-sentinel", "MIXED_WORKSPACE_TASK_DONE",
                "--required-final-sentinel", "MISSING_SENTINEL"
            ]
        )

        XCTAssertNotEqual(missingSentinel.exitCode, 0)
        XCTAssertTrue(
            missingSentinel.stderr.contains("missing pressure completion sentinel: MISSING_SENTINEL"),
            missingSentinel.stderr
        )
    }

    private func mixedSentinelEvents() -> [[String: Any]] {
        [
            pressureToolStarted("find /tmp /docs /media -maxdepth 1 -type f"),
            pressureToolCompleted(stdout: "/tmp/a\n/docs/b\n/media/c\n"),
            pressureFinalAnswer("first mixed step\nMIXED_WORKSPACE_TASK_DONE"),
            pressureFinalAnswer("second mixed step\nMIXED_PYTHON_SUBPROCESS_DONE"),
            pressureFinalAnswer("third mixed step\nMIXED_MOVE_DELETE_BATCH_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"all mixed workspace outputs matched Linux expectations"}
            """)
        ]
    }

    private func mixedSentinelArguments() -> [String] {
        [
            "--expected-final-answers", "4",
            "--required-final-sentinel", "MIXED_WORKSPACE_TASK_DONE",
            "--required-final-sentinel", "MIXED_PYTHON_SUBPROCESS_DONE",
            "--required-final-sentinel", "MIXED_MOVE_DELETE_BATCH_DONE"
        ]
    }
}
