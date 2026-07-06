import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineControlledSubprocessSignalTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineControlledSubprocessSignalsKillAndTerminateWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython controlled subprocess signal test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        import signal
        import subprocess

        p_signal = subprocess.Popen(['sleep', '2'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        signal_result = p_signal.send_signal(signal.SIGTERM)
        print('send_signal=' + repr((signal_result, p_signal.returncode, p_signal.wait(timeout=5), p_signal.returncode)))

        p_done_signal = subprocess.Popen(['printf', 'done'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p_done_signal.wait(timeout=5)
        done_signal_result = p_done_signal.send_signal(signal.SIGTERM)
        print('send_signal_done=' + repr((done_signal_result, p_done_signal.returncode)))

        p12 = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        print('kill_poll=' + str(p12.poll()))
        p12.kill()
        print('kill_returncode_immediate=' + repr(p12.returncode))
        print('kill_wait=' + str(p12.wait(timeout=5)))
        print('kill_final=' + str(p12.returncode))

        p13 = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        p13.terminate()
        print('terminate_returncode_immediate=' + repr(p13.returncode))
        print('terminate_wait=' + str(p13.wait(timeout=5)))
        print('terminate_final=' + str(p13.returncode))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        send_signal=(None, None, -15, -15)
        send_signal_done=(None, 0)
        kill_poll=None
        kill_returncode_immediate=None
        kill_wait=-9
        kill_final=-9
        terminate_returncode_immediate=None
        terminate_wait=-15
        terminate_final=-15

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
}
