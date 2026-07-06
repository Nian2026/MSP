import Foundation
import MSPAgentBridge
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testExecCommandPipeSessionWritesNonEmptyStdinToLiveStream() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "cat",
            tty: false,
            yieldTimeMilliseconds: 100
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "")
        XCTAssertEqual(start.result.stderr, "")

        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "hello\n",
            yieldTimeMilliseconds: 100
        ))

        XCTAssertEqual(write.runningSessionID, sessionID)
        XCTAssertEqual(write.exitCode, nil)
        XCTAssertEqual(write.result.stdout, "hello\n")
        XCTAssertEqual(write.result.stderr, "")

        let eof = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{4}",
            yieldTimeMilliseconds: 250
        ))

        XCTAssertNil(eof.runningSessionID)
        XCTAssertEqual(eof.exitCode, 0)
        XCTAssertEqual(eof.result.stdout, "")
        XCTAssertEqual(eof.result.stderr, "")
    }

    func testExecCommandPipeSessionWritesBinaryStdinDataToLiveStream() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "od -An -tx1",
            tty: false,
            yieldTimeMilliseconds: 100
        ))
        let sessionID = try XCTUnwrap(
            start.runningSessionID,
            "expected od to wait for live stdin, got exit=\(String(describing: start.exitCode)) stdout=\(String(reflecting: start.result.stdout)) stderr=\(String(reflecting: start.result.stderr))"
        )
        XCTAssertEqual(start.result.stdout, "")
        XCTAssertEqual(start.result.stderr, "")

        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            stdinData: Data([0x41, 0x00, 0xff, 0x0a]),
            yieldTimeMilliseconds: 100
        ))

        XCTAssertEqual(write.runningSessionID, sessionID)
        XCTAssertEqual(write.exitCode, nil)
        XCTAssertEqual(write.result.stdout, "")
        XCTAssertEqual(write.result.stderr, "")

        let eof = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{4}",
            yieldTimeMilliseconds: 250
        ))

        XCTAssertNil(eof.runningSessionID)
        XCTAssertEqual(eof.exitCode, 0)
        XCTAssertEqual(eof.result.stdout, " 41 00 ff 0a\n")
        XCTAssertEqual(eof.result.stderr, "")
    }

    func testExecCommandPipeSessionReadBuiltinConsumesLiveStdinByRecord() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "read -r FIRST; printf 'first:%s\\n' \"$FIRST\"; read -r SECOND; printf 'second:%s\\n' \"$SECOND\"",
            tty: false,
            yieldTimeMilliseconds: 100
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "")
        XCTAssertEqual(start.result.stderr, "")

        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "alpha\nbeta\n",
            yieldTimeMilliseconds: 500
        ))

        XCTAssertNil(write.runningSessionID)
        XCTAssertEqual(write.exitCode, 0)
        XCTAssertEqual(write.result.stdout, "first:alpha\nsecond:beta\n")
        XCTAssertEqual(write.result.stderr, "")
    }

    func testExecCommandPipeSessionLateWriteAfterEOFReturnsCompletedResult() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "cat >/dev/null; sleep 0.6; printf 'after-eof\\n'",
            tty: false,
            yieldTimeMilliseconds: 100
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)

        let eof = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{4}",
            yieldTimeMilliseconds: 1
        ))
        XCTAssertEqual(eof.runningSessionID, sessionID)
        XCTAssertEqual(eof.exitCode, nil)

        try await Task.sleep(nanoseconds: 750_000_000)

        let lateWrite = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "too late\n",
            yieldTimeMilliseconds: 100
        ))

        XCTAssertNil(lateWrite.runningSessionID)
        XCTAssertEqual(lateWrite.exitCode, 0)
        XCTAssertEqual(lateWrite.result.stdout, "after-eof\n")
        XCTAssertEqual(lateWrite.result.stderr, "")
    }

    func testExecCommandPipeSessionAcceptsCtrlCAsInterrupt() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "sleep 5",
            tty: false,
            yieldTimeMilliseconds: 250
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)

        let interrupted = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{3}",
            yieldTimeMilliseconds: 250
        ))

        XCTAssertNil(interrupted.runningSessionID)
        XCTAssertEqual(interrupted.exitCode, 130)
        XCTAssertEqual(interrupted.signal, 2)

        let readAfterInterrupt = await bridge.readSession(sessionID: sessionID)
        XCTAssertNil(readAfterInterrupt.runningSessionID)
        XCTAssertEqual(readAfterInterrupt.exitCode, 1)
        XCTAssertEqual(readAfterInterrupt.result.stderr, "read failed: inactive session \(sessionID)\n")
    }
}
