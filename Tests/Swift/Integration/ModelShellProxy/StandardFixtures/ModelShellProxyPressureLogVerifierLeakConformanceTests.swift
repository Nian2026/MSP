import Foundation
import XCTest

final class ModelShellProxyPressureLogVerifierLeakConformanceTests: ModelShellProxyPressureLogVerifierTestCase {
    func testRealModelPressureVerifierRejectsObservedInternalPathLeaks() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-leaked")
        defer { removeTemporaryURL(rootURL) }
        let leakedLog = rootURL.appendingPathComponent("leaked.jsonl")
        try writePressureEvents([
            pressureToolStarted("python3 /tmp/inspect.py"),
            pressureToolCompleted(stdout: "Traceback file /private/var/mobile/Containers/Data/Application/ABC/tmp/msp-python-launcher.py\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"no issue reported"}
            """)
        ], to: leakedLog)

        let leaked = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: leakedLog)

        XCTAssertNotEqual(leaked.exitCode, 0)
        XCTAssertTrue(
            leaked.stderr.contains("model-visible output leaked internal paths"),
            leaked.stderr
        )
        let leakedReport = try String(
            contentsOf: leakedLog.deletingPathExtension().appendingPathExtension("report.json"),
            encoding: .utf8
        )
        XCTAssertTrue(leakedReport.contains(#""passed": false"#), leakedReport)
        XCTAssertTrue(
            leakedReport.contains("model-visible output leaked internal paths"),
            leakedReport
        )
    }

    func testRealModelPressureVerifierScansStreamingAndFinalAnswerDeltasForLeaks() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-stream-leaked")
        defer { removeTemporaryURL(rootURL) }
        let streamLeakedLog = rootURL.appendingPathComponent("stream-leaked.jsonl")
        try writePressureEvents([
            pressureToolStarted("python3 /tmp/inspect.py"),
            pressureToolOutputDelta(
                "stdout",
                text: "streamed /private/var/mobile/Containers/Data/Application/ABC/tmp/vfs-broker/request.json\n"
            ),
            pressureToolCompleted(stdout: "sanitized stream output\n"),
            pressureFinalAnswerDelta("temporary text mentioned /private/var/mobile/Containers/Data/Application/ABC/tmp/msp-python-launcher.py"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"final answer was clean"}
            """)
        ], to: streamLeakedLog)

        let streamLeaked = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: streamLeakedLog)

        XCTAssertNotEqual(streamLeaked.exitCode, 0)
        XCTAssertTrue(
            streamLeaked.stderr.contains("tool_output_delta.text")
                || streamLeaked.stderr.contains("final_answer_delta.text"),
            streamLeaked.stderr
        )
    }

    func testRealModelPressureVerifierRejectsFeedbackPathLeaksAndTracksQuotedEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-feedback-path-leaks")
        defer { removeTemporaryURL(rootURL) }
        let feedbackConcretePathLeakLog = rootURL.appendingPathComponent("feedback-concrete-path-leak.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":["/private/var/mobile/Containers/Data/Application/ABC/tmp/msp-python-launcher.py"],"notes":"reported a concrete leaked path that was not observed earlier"}
            """)
        ], to: feedbackConcretePathLeakLog)

        let feedbackConcretePathLeak = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: feedbackConcretePathLeakLog
        )
        XCTAssertNotEqual(feedbackConcretePathLeak.exitCode, 0)
        XCTAssertTrue(
            feedbackConcretePathLeak.stderr.contains("model-visible output leaked internal paths"),
            feedbackConcretePathLeak.stderr
        )
        XCTAssertTrue(
            feedbackConcretePathLeak.stderr.contains("model reported leaked internal path was not quoted from observed output"),
            feedbackConcretePathLeak.stderr
        )

        let feedbackQuotedPathLeakLog = rootURL.appendingPathComponent("feedback-quoted-path-leak.jsonl")
        try writePressureEvents([
            pressureToolStarted("python3 /tmp/inspect.py"),
            pressureToolCompleted(stdout: "Traceback file /private/var/mobile/Containers/Data/Application/ABC/tmp/msp-python-launcher.py\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":["/private/var/mobile/Containers/Data/Application/ABC/tmp/msp-python-launcher.py"],"notes":"quoted the observed leaked path"}
            """)
        ], to: feedbackQuotedPathLeakLog)
        let feedbackQuotedPathLeak = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: feedbackQuotedPathLeakLog
        )
        XCTAssertNotEqual(feedbackQuotedPathLeak.exitCode, 0)
        XCTAssertTrue(
            feedbackQuotedPathLeak.stderr.contains("model reported leaked internal paths"),
            feedbackQuotedPathLeak.stderr
        )
        XCTAssertFalse(
            feedbackQuotedPathLeak.stderr.contains("model reported leaked internal path was not quoted from observed output"),
            feedbackQuotedPathLeak.stderr
        )
    }

    func testRealModelPressureVerifierRejectsUnquotedSuspiciousOutputs() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-feedback-suspicious-outputs")
        defer { removeTemporaryURL(rootURL) }

        let unquotedSuspiciousOutputLog = rootURL.appendingPathComponent("feedback-unquoted-suspicious-output.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":["error wording did not match Linux"],"leaked_internal_paths":[],"notes":"reported a suspicious output that was not observed earlier"}
            """)
        ], to: unquotedSuspiciousOutputLog)

        let unquotedSuspiciousOutput = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: unquotedSuspiciousOutputLog
        )
        XCTAssertNotEqual(unquotedSuspiciousOutput.exitCode, 0)
        XCTAssertTrue(
            unquotedSuspiciousOutput.stderr.contains("model reported suspicious output was not quoted from observed output"),
            unquotedSuspiciousOutput.stderr
        )
        XCTAssertTrue(
            unquotedSuspiciousOutput.stderr.contains("model reported suspicious outputs"),
            unquotedSuspiciousOutput.stderr
        )

        let quotedSuspiciousOutputLog = rootURL.appendingPathComponent("feedback-quoted-suspicious-output.jsonl")
        try writePressureEvents([
            pressureToolStarted("python3 /tmp/inspect.py"),
            pressureToolCompleted(stdout: "error wording did not match Linux\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":["error wording did not match Linux"],"leaked_internal_paths":[],"notes":"quoted the observed suspicious output"}
            """)
        ], to: quotedSuspiciousOutputLog)
        let quotedSuspiciousOutput = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: quotedSuspiciousOutputLog
        )
        XCTAssertNotEqual(quotedSuspiciousOutput.exitCode, 0)
        XCTAssertTrue(
            quotedSuspiciousOutput.stderr.contains("model reported suspicious outputs"),
            quotedSuspiciousOutput.stderr
        )
        XCTAssertFalse(
            quotedSuspiciousOutput.stderr.contains("model reported suspicious output was not quoted from observed output"),
            quotedSuspiciousOutput.stderr
        )
    }

    func testRealModelPressureVerifierClassifiesImplementationDisclosureKinds() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-implementation-disclosure")
        defer { removeTemporaryURL(rootURL) }
        let implementationDisclosureLog = rootURL.appendingPathComponent("implementation-disclosure.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "debug: ios sandbox path backed by msp runtime using a Materialized backend launcher in a virtual workspace and host-backed workspace with direct-host filesystem plus PhotoKit PHAsset localIdentifier, 照片库后端, 虚拟后端, 宿主路径, and 沙盒路径 in iOS Simulator via simctl app container CoreSimulator\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"no issue reported"}
            """)
        ], to: implementationDisclosureLog)

        let implementationDisclosure = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: implementationDisclosureLog
        )

        XCTAssertNotEqual(implementationDisclosure.exitCode, 0)
        for expected in [
            "plain_ios_sandbox_disclosure",
            "plain_sandbox_path_disclosure",
            "plain_msp_disclosure",
            "plain_backend_disclosure",
            "plain_virtual_backend_disclosure",
            "plain_host_backend_disclosure",
            "plain_photo_backend_disclosure",
            "plain_simulator_disclosure",
            "plain_app_container_disclosure"
        ] {
            XCTAssertTrue(implementationDisclosure.stderr.contains(expected), implementationDisclosure.stderr)
        }
    }

    func testRealModelPressureVerifierRejectsFeedbackThatDistinguishesLinux() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-confused")
        defer { removeTemporaryURL(rootURL) }
        let confusedLog = rootURL.appendingPathComponent("confused.jsonl")
        try writePressureEvents([
            pressureToolStarted("find /tmp -maxdepth 1 -type f"),
            pressureToolCompleted(stdout: "/tmp/report.txt\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":false,"can_distinguish_from_regular_linux":true,"suspicious_outputs":["error wording did not match Linux"],"leaked_internal_paths":[],"notes":"not regular Linux"}
            """)
        ], to: confusedLog)

        let confused = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: confusedLog)

        XCTAssertNotEqual(confused.exitCode, 0)
        XCTAssertTrue(
            confused.stderr.contains("can distinguish this from a regular Linux workspace"),
            confused.stderr
        )
        let confusedReport = try String(
            contentsOf: confusedLog.deletingPathExtension().appendingPathExtension("report.json"),
            encoding: .utf8
        )
        XCTAssertTrue(confusedReport.contains(#""passed": false"#), confusedReport)
        XCTAssertTrue(
            confusedReport.contains("can distinguish this from a regular Linux workspace"),
            confusedReport
        )
    }

    func testRealModelPressureVerifierRequiresEvidenceForNegativeLinuxFeedback() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-negative-feedback-evidence")
        defer { removeTemporaryURL(rootURL) }
        let negativeWithoutEvidenceLog = rootURL.appendingPathComponent("negative-without-evidence.jsonl")
        try writePressureEvents([
            pressureToolStarted("find /tmp -maxdepth 1 -type f"),
            pressureToolCompleted(stdout: "/tmp/report.txt\n"),
            pressureFinalAnswer("PRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":false,"can_distinguish_from_regular_linux":true,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"not regular Linux, but without concrete evidence"}
            """)
        ], to: negativeWithoutEvidenceLog)

        let negativeWithoutEvidence = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: negativeWithoutEvidenceLog
        )

        XCTAssertNotEqual(negativeWithoutEvidence.exitCode, 0)
        XCTAssertTrue(
            negativeWithoutEvidence.stderr.contains(
                "model negative Linux feedback did not include suspicious_outputs or leaked_internal_paths evidence"
            ),
            negativeWithoutEvidence.stderr
        )
    }
}
