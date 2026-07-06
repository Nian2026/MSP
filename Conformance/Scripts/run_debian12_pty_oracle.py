#!/usr/bin/env python3
"""Run the MSP Debian 12 PTY oracle fixture with a real OS PTY.

This runner is intended to execute inside Debian 12 or a Debian 12 based
container. It deliberately uses the platform PTY line discipline instead of the
MSP macOS PTY smoke backend, so it can serve as the byte-stream oracle gate for
the imported `pty-cases.json` matrix.
"""

from __future__ import annotations

import argparse
import base64
import datetime as _dt
import errno
import fcntl
import json
import os
import platform
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path
from typing import Any


DEFAULT_FIXTURE = (
    "Conformance/ReferenceOutputs/MSPV1Debian12Oracle/pty-cases.json"
)
DEFAULT_REPORT = ".build/msp-conformance/debian12-pty-linux-report.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run MSP Debian 12 PTY oracle cases with a real PTY."
    )
    parser.add_argument("--fixture", default=DEFAULT_FIXTURE)
    parser.add_argument(
        "--report",
        default=os.environ.get("MSP_DEBIAN12_PTY_ORACLE_REPORT", DEFAULT_REPORT),
    )
    parser.add_argument("--case", dest="case_id", default=None)
    parser.add_argument("--cases", default=None)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument(
        "--require-linux",
        action="store_true",
        help="Fail unless the runner is executing on Linux.",
    )
    parser.add_argument(
        "--allow-non-linux",
        action="store_true",
        help="Allow local smoke runs on non-Linux platforms.",
    )
    parser.add_argument(
        "--initial-read-timeout",
        type=float,
        default=0.25,
        help="Seconds to collect initial PTY output before the first action.",
    )
    parser.add_argument(
        "--final-polls",
        type=int,
        default=10,
        help="Number of final 500 ms polls before terminating a still-live case.",
    )
    parser.add_argument(
        "--post-exit-close-wait",
        type=float,
        default=0.35,
        help="Seconds to keep draining the PTY after process exit is observed.",
    )
    parser.add_argument(
        "--write-timeout",
        type=float,
        default=10.0,
        help="Seconds allowed for each action write, including echo backpressure.",
    )
    parser.add_argument(
        "--post-action-exit-settle",
        type=float,
        default=0.05,
        help="Seconds to wait for a just-satisfied PTY command to report exit after an action read.",
    )
    return parser.parse_args()


def iso8601_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")


def load_fixture(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def comma_set(value: str | None) -> set[str]:
    if not value:
        return set()
    return {item.strip() for item in value.split(",") if item.strip()}


def selected_cases(cases: list[dict[str, Any]], args: argparse.Namespace) -> list[dict[str, Any]]:
    selected = list(cases)
    case_list = args.cases or os.environ.get("MSP_DEBIAN12_PTY_ORACLE_CASES")
    single_case = args.case_id or os.environ.get("MSP_DEBIAN12_PTY_ORACLE_CASE")
    limit_text = os.environ.get("MSP_DEBIAN12_PTY_ORACLE_LIMIT")
    limit = args.limit
    if limit is None and limit_text:
        limit = int(limit_text)

    if case_list:
        ids = comma_set(case_list)
        selected = [case for case in selected if case["id"] in ids]
    elif single_case:
        selected = [case for case in selected if case["id"] == single_case]

    if limit is not None and limit >= 0:
        selected = selected[:limit]
    return selected


def set_nonblocking(fd: int) -> None:
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


def child_preexec(slave_fd: int) -> None:
    os.setsid()
    try:
        fcntl.ioctl(slave_fd, getattr(termios, "TIOCSCTTY", 0x540E), 0)
    except OSError:
        os._exit(127)


def spawn_case(command: str, cwd: Path) -> tuple[subprocess.Popen[bytes], int]:
    master_fd, slave_fd = pty.openpty()
    env = dict(os.environ)
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("LANG", "C.UTF-8")
    env.setdefault("LC_CTYPE", "C.UTF-8")
    argv = ["/bin/bash", "-lc", command]
    previous_sigpipe = signal.getsignal(signal.SIGPIPE)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    try:
        proc = subprocess.Popen(
            argv,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            cwd=str(cwd),
            env=env,
            close_fds=True,
            preexec_fn=lambda: child_preexec(slave_fd),
            restore_signals=False,
        )
    finally:
        signal.signal(signal.SIGPIPE, previous_sigpipe)
    os.close(slave_fd)
    set_nonblocking(master_fd)
    return proc, master_fd


def drain_nonblocking(fd: int) -> bytes:
    chunks: list[bytes] = []
    while True:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            break
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def read_for(
    fd: int,
    proc: subprocess.Popen[bytes],
    timeout: float,
    post_exit_close_wait: float,
) -> bytes:
    deadline = time.monotonic() + max(0.0, timeout)
    close_deadline: float | None = None
    chunks: list[bytes] = []
    while True:
        now = time.monotonic()
        if proc.poll() is not None and close_deadline is None:
            close_deadline = now + max(0.0, post_exit_close_wait)
        effective_deadline = close_deadline if close_deadline is not None else deadline
        remaining = effective_deadline - now
        if remaining <= 0:
            break
        ready, _, _ = select.select([fd], [], [], min(0.02, remaining))
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
            continue
    chunks.append(drain_nonblocking(fd))
    return b"".join(chunks)


def write_all_collecting_output(
    fd: int,
    data: bytes,
    timeout: float,
) -> tuple[bool, bytes]:
    deadline = time.monotonic() + timeout
    offset = 0
    chunks: list[bytes] = []
    while offset < len(data):
        try:
            written = os.write(fd, data[offset:])
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False, b"".join(chunks)
            readable, writable, _ = select.select(
                [fd],
                [fd],
                [],
                min(0.02, remaining),
            )
            if readable:
                chunks.append(drain_nonblocking(fd))
            if writable:
                continue
            continue
        except InterruptedError:
            continue
        except OSError:
            return False, b"".join(chunks)
        if written <= 0:
            return False, b"".join(chunks)
        offset += written
        chunks.append(drain_nonblocking(fd))
    chunks.append(drain_nonblocking(fd))
    return True, b"".join(chunks)


def write_all(fd: int, data: bytes, timeout: float = 1.0) -> bool:
    wrote_all, _ = write_all_collecting_output(fd, data, timeout)
    return wrote_all
    return True


def process_status(proc: subprocess.Popen[bytes]) -> tuple[int | None, int | None]:
    returncode = proc.poll()
    if returncode is None:
        return None, None
    if returncode < 0:
        return None, -returncode
    return returncode, None


def settled_process_status(
    proc: subprocess.Popen[bytes],
    timeout: float,
) -> tuple[int | None, int | None]:
    if proc.poll() is None and timeout > 0:
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            pass
    return process_status(proc)


def terminate_process(proc: subprocess.Popen[bytes]) -> tuple[int | None, int | None]:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return process_status(proc)
    try:
        proc.wait(timeout=0.15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=1.0)
    return process_status(proc)


def run_case(
    case: dict[str, Any],
    initial_timeout: float,
    final_polls: int,
    post_exit_close_wait: float,
    write_timeout: float,
    post_action_exit_settle: float,
) -> dict[str, Any]:
    stream = bytearray()
    exit_code: int | None = None
    sig: int | None = None

    with tempfile.TemporaryDirectory(prefix=f"msp-pty-{case['id']}-") as temp_dir:
        proc, master_fd = spawn_case(case["command_line"], Path(temp_dir))
        try:
            stream.extend(read_for(
                master_fd,
                proc,
                initial_timeout,
                post_exit_close_wait,
            ))
            exit_code, sig = settled_process_status(proc, post_action_exit_settle)

            for action in case.get("actions", []):
                if exit_code is not None or sig is not None:
                    break
                sleep_before_ms = int(action.get("sleep_before_ms") or 0)
                if sleep_before_ms > 0:
                    time.sleep(sleep_before_ms / 1000.0)
                data = base64.b64decode(action.get("bytes_b64") or "")
                wrote_all, write_output = write_all_collecting_output(
                    master_fd,
                    data,
                    write_timeout,
                )
                stream.extend(write_output)
                if not wrote_all:
                    break
                timeout = float(action.get("read_timeout") or 0.25)
                stream.extend(read_for(
                    master_fd,
                    proc,
                    timeout,
                    post_exit_close_wait,
                ))
                exit_code, sig = settled_process_status(proc, post_action_exit_settle)

            remaining = max(0, final_polls)
            while exit_code is None and sig is None and remaining > 0:
                remaining -= 1
                stream.extend(read_for(
                    master_fd,
                    proc,
                    0.5,
                    post_exit_close_wait,
                ))
                exit_code, sig = process_status(proc)

            if exit_code is None and sig is None:
                stream.extend(read_for(
                    master_fd,
                    proc,
                    post_exit_close_wait,
                    post_exit_close_wait,
                ))
                exit_code, sig = terminate_process(proc)
                if sig is not None or exit_code not in (0,):
                    stream.extend(b"terminated\n")
        finally:
            try:
                os.close(master_fd)
            except OSError:
                pass

    return {
        "streamB64": base64.b64encode(bytes(stream)).decode("ascii"),
        "exitCode": exit_code,
        "signal": sig,
    }


def decoded_bytes(value: str | None) -> bytes:
    if not value:
        return b""
    return base64.b64decode(value)


def utf8_preview(data: bytes, limit: int = 1200) -> str:
    text = data.decode("utf-8", errors="replace")
    if len(text) > limit:
        text = text[:limit] + "...<truncated>"
    return repr(text)


def byte_comparison(expected: bytes, actual: bytes) -> dict[str, Any]:
    shared = min(len(expected), len(actual))
    offset: int | None = None
    for index in range(shared):
        if expected[index] != actual[index]:
            offset = index
            break
    if offset is None and len(expected) != len(actual):
        offset = shared
    return {
        "expectedByteCount": len(expected),
        "actualByteCount": len(actual),
        "firstDifferentByteOffset": offset,
        "expectedByteAtOffset": expected[offset] if offset is not None and offset < len(expected) else None,
        "actualByteAtOffset": actual[offset] if offset is not None and offset < len(actual) else None,
        "expectedUtf8Preview": utf8_preview(expected),
        "actualUtf8Preview": utf8_preview(actual),
    }


def case_failure(case: dict[str, Any], actual: dict[str, Any]) -> dict[str, Any] | None:
    expected = {
        "streamB64": case["expected"]["stream_b64"],
        "exitCode": case["expected"].get("exit_code"),
        "signal": case["expected"].get("signal"),
    }
    mismatch = {
        "streamMatches": actual["streamB64"] == expected["streamB64"],
        "exitCodeMatches": actual["exitCode"] == expected["exitCode"],
        "signalMatches": actual["signal"] == expected["signal"],
    }
    if all(mismatch.values()):
        return None
    return {
        "id": case["id"],
        "command": case["command_line"],
        "mismatch": mismatch,
        "expected": expected,
        "actual": actual,
        "diagnostics": {
            "stream": byte_comparison(
                decoded_bytes(expected["streamB64"]),
                decoded_bytes(actual["streamB64"]),
            )
        },
    }


def write_report(
    path: Path,
    selected: list[dict[str, Any]],
    failures: list[dict[str, Any]],
    compatibility_adjustments: list[dict[str, Any]],
) -> None:
    passed_ids = [
        case["id"]
        for case in selected
        if not any(failure["id"] == case["id"] for failure in failures)
    ]
    report = {
        "generatedAt": iso8601_now(),
        "runnerBackend": "Python os.openpty PTY runner",
        "runnerPlatform": platform.platform(),
        "selectedCaseCount": len(selected),
        "passedCaseCount": len(selected) - len(failures),
        "failedCaseCount": len(failures),
        "passedCaseIDs": passed_ids,
        "failedCaseIDs": [failure["id"] for failure in failures],
        "failures": failures,
        "compatibilityAdjustments": compatibility_adjustments,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    is_linux = platform.system() == "Linux"
    if args.require_linux and not is_linux and not args.allow_non_linux:
        print(
            "Debian PTY oracle runner requires Linux; run the container wrapper or pass --allow-non-linux for smoke only.",
            file=sys.stderr,
        )
        return 2

    fixture_path = Path(args.fixture)
    report_path = Path(args.report)
    fixture = load_fixture(fixture_path)
    cases = selected_cases(fixture["cases"], args)
    if not cases:
        print("no PTY oracle cases selected", file=sys.stderr)
        return 3

    failures: list[dict[str, Any]] = []
    compatibility_adjustments: list[dict[str, Any]] = []
    for case in cases:
        try:
            actual = run_case(
                case,
                args.initial_read_timeout,
                args.final_polls,
                args.post_exit_close_wait,
                args.write_timeout,
                args.post_action_exit_settle,
            )
            adjustments = actual.get("readexCompatibilityAdjustments") or []
            if adjustments:
                compatibility_adjustments.append({
                    "id": case["id"],
                    "adjustments": adjustments,
                })
            failure = case_failure(case, actual)
            if failure is not None:
                failures.append(failure)
        except Exception as exc:  # noqa: BLE001 - report all runner errors as case failures.
            actual = {
                "streamB64": base64.b64encode(str(exc).encode("utf-8")).decode("ascii"),
                "exitCode": -1,
                "signal": None,
            }
            failure = case_failure(case, actual)
            failures.append(failure or {
                "id": case["id"],
                "command": case["command_line"],
                "mismatch": {
                    "streamMatches": False,
                    "exitCodeMatches": False,
                    "signalMatches": False,
                },
                "expected": {
                    "streamB64": case["expected"]["stream_b64"],
                    "exitCode": case["expected"].get("exit_code"),
                    "signal": case["expected"].get("signal"),
                },
                "actual": actual,
                "diagnostics": {
                    "stream": byte_comparison(
                        decoded_bytes(case["expected"]["stream_b64"]),
                        decoded_bytes(actual["streamB64"]),
                    )
                },
            })

    write_report(report_path, cases, failures, compatibility_adjustments)
    if failures:
        preview = ", ".join(failure["id"] for failure in failures[:8])
        print(
            f"Debian PTY oracle failed: {len(failures)} of {len(cases)} case(s): {preview}",
            file=sys.stderr,
        )
        print(f"report={report_path}", file=sys.stderr)
        return 1

    print(f"Debian PTY oracle passed: {len(cases)} case(s)")
    print(f"report={report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
