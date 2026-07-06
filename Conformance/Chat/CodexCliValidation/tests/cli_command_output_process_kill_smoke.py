#!/usr/bin/env python3
"""Run real CLI/TUI command-output process-kill parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a shell_command call
    wait until stdout/stderr markers are visible and sent back to the model
    kill the TUI process before the final assistant answer
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T01/T02/T03, H05, crash-recovery, or
user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import errno
import json
import os
import pathlib
import pty
import re
import select
import struct
import subprocess
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_command_execution_smoke import summarize_command_timeline  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_command_streaming_tui_smoke import (  # noqa: E402
    FINAL_TEXT,
    FOLLOWUP_TEXT,
    FOLLOWUP_USER_TEXT,
    STREAM_CALL_ID,
    STREAM_MARKERS,
    STREAM_COMMAND,
    USER_TEXT,
    body_contains,
    command_timeline_has_streaming_call,
    durable_line_counts,
    ev_final_message,
    ev_shell_command_call,
    marker_sequence_ok,
    ordered_marker_positions,
    response_request_bodies,
    response_request_count,
)
from cli_exec_resume_smoke import normalize_exec_events, run_cli_command  # noqa: E402
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


DELAYED_FINAL_SECONDS = 8.0
COMMAND_OUTPUT_IDLE_SECONDS = 0.8
PRE_MODEL_OUTPUT_IDLE_SECONDS = 0.2
KILL_MODE_AFTER_MODEL_OUTPUT = "after-model-output"
KILL_MODE_BEFORE_MODEL_OUTPUT = "before-model-output"
PRE_MODEL_STREAM_MARKERS = ["STREAM_STDOUT_1", "STREAM_STDERR_1"]
PRE_MODEL_STREAM_COMMAND = (
    "python3 -c 'import sys, time; "
    "print(\"STREAM_STDOUT_1\", flush=True); "
    "print(\"STREAM_STDERR_1\", file=sys.stderr, flush=True); "
    "time.sleep(30)'"
)

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Spec/Chat/CorePackage.md",
    "Spec/Chat/TimelineEvents.md",
    "Spec/Chat/CommandTimeline.md",
    "Spec/Chat/Projections.md",
    "Spec/Chat/ContextAndJournal.md",
    "Spec/Chat/Conformance.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/CODEX_BACKEND_MAPPING.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_command_streaming_tui_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_crash_pending_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_execution_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_output_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_event_sender.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "tests/cli_command_streaming_tui_smoke.py",
        "finding": (
            "The real TUI harness can drive an interactive command-output turn, "
            "detect stdout/stderr markers in visible terminal output, and verify "
            "follow-up resume context."
        ),
    },
    {
        "file": "tests/cli_request_permissions_crash_pending_resume_smoke.py",
        "finding": (
            "The existing process-kill smoke uses PTY control, kills the TUI at a "
            "user-visible boundary, and compares follow-up `codex exec --json "
            "resume --last` behavior."
        ),
    },
    {
        "file": "tests/app_server_command_output_failpoint_crash_smoke.py",
        "finding": (
            "The app-server failpoint slices already prove command output can be "
            "canonical before projection rebuild; this smoke adds the real TUI "
            "process-kill surface."
        ),
    },
]


class DelayedFinalCommandOutputServer:
    def __init__(self, kill_mode: str) -> None:
        self.requests: list[dict[str, Any]] = []
        self._counter = 0
        self._lock = None
        self._httpd = None
        self._thread = None
        self.kill_mode = kill_mode

    def __enter__(self) -> "DelayedFinalCommandOutputServer":
        import http.server
        import threading

        self._lock = threading.Lock()
        handler = self._make_handler()
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self._httpd.mock_server = self  # type: ignore[attr-defined]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)

    @property
    def url(self) -> str:
        assert self._httpd is not None
        host, port = self._httpd.server_address
        return f"http://{host}:{port}"

    def record_request(self, request: dict[str, Any]) -> None:
        assert self._lock is not None
        with self._lock:
            self.requests.append(request)

    def next_sse_body(self) -> bytes:
        assert self._lock is not None
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter == 1:
            return ev_shell_command_call(
                "resp-cli-command-output-kill-call",
                STREAM_CALL_ID,
                PRE_MODEL_STREAM_COMMAND
                if self.kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT
                else STREAM_COMMAND,
            )
        if counter == 2:
            if self.kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT:
                return ev_final_message(
                    "resp-cli-command-output-kill-followup-after-pre-model-kill",
                    "msg-cli-command-output-kill-followup-after-pre-model-kill",
                    FOLLOWUP_TEXT,
                )
            time.sleep(DELAYED_FINAL_SECONDS)
            return ev_final_message(
                "resp-cli-command-output-kill-delayed-final",
                "msg-cli-command-output-kill-delayed-final",
                FINAL_TEXT,
            )
        return ev_final_message(
            f"resp-cli-command-output-kill-followup-{counter}",
            f"msg-cli-command-output-kill-followup-{counter}",
            FOLLOWUP_TEXT,
        )

    def _make_handler(self) -> type[Any]:
        import http.server

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def do_GET(self) -> None:
                if self.path.endswith("/models"):
                    body = json.dumps({"models": []}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_error(404)

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length)
                try:
                    body_json = json.loads(raw_body.decode() or "{}")
                except json.JSONDecodeError:
                    body_json = {"_decode_error": raw_body.decode(errors="replace")}
                server: DelayedFinalCommandOutputServer = self.server.mock_server  # type: ignore[attr-defined]
                server.record_request(
                    {
                        "method": "POST",
                        "path": self.path,
                        "json": body_json,
                    }
                )
                if not self.path.endswith("/responses"):
                    self.send_error(404)
                    return
                body = server.next_sse_body()
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    return

        return Handler


def body_contains_all_markers(body: dict[str, Any]) -> bool:
    serialized = json.dumps(body, ensure_ascii=False)
    return all(marker in serialized for marker in STREAM_MARKERS)


def body_contains_required_markers(body: dict[str, Any], markers: list[str]) -> bool:
    serialized = json.dumps(body, ensure_ascii=False)
    return all(marker in serialized for marker in markers)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]], required_markers: list[str]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    serialized = [json.dumps(body, ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "second_body_contains_original_user_text": body_contains(second_body, USER_TEXT),
        "second_body_contains_followup_user_text": body_contains(second_body, FOLLOWUP_USER_TEXT),
        "second_body_contains_function_output": any(
            STREAM_CALL_ID in body and "function_call_output" in body
            for body in serialized[1:2]
        ),
        "second_body_contains_all_markers": body_contains_all_markers(second_body),
        "second_body_contains_required_markers": body_contains_required_markers(
            second_body,
            required_markers,
        ),
        "third_body_contains_original_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_followup_user_text": body_contains(third_body, FOLLOWUP_USER_TEXT),
        "third_body_contains_all_markers": body_contains_all_markers(third_body),
        "third_body_contains_interrupted_marker": serialized_contains(
            third_body,
            "interrupted",
        )
        or serialized_contains(third_body, "aborted"),
        "third_body_contains_delayed_final_text": serialized_contains(third_body, FINAL_TEXT),
    }


def run_cli_command_output_process_kill_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: DelayedFinalCommandOutputServer,
    kill_mode: str,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    master, slave = pty.openpty()
    try:
        import fcntl
        import termios

        winsize = struct.pack("HHHH", 34, 120, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)
    except OSError:
        pass

    started_at = time.time()
    process = subprocess.Popen(
        command,
        cwd=str(workspace),
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        text=False,
    )
    os.close(slave)

    output = b""
    sent_probe_response = False
    sent_trust_answer = False
    sent_trust_continue = False
    sent_term_gate_answer = False
    sent_prompt = False
    prompt_sent_at: float | None = None
    prompt_enter_retry_sent = False
    marker_first_seen: dict[str, float] = {}
    final_answer_visible_at: float | None = None
    command_output_ready_at: float | None = None
    required_markers = (
        PRE_MODEL_STREAM_MARKERS
        if kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT
        else STREAM_MARKERS
    )
    killed_after_command_output = False

    try:
        while time.time() - started_at < 90:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    chunk = os.read(master, 8192)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk

            visible_text = output.decode(errors="replace")
            visible_tail = visible_text[-2600:]
            stripped_text = strip_ansi(visible_text)
            compact_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))
            request_count = response_request_count(mock_server.requests)

            if not sent_probe_response and (
                "\x1b[6n" in visible_tail
                or "]10;?" in visible_tail
                or "[?u" in visible_tail
            ):
                os.write(master, TERMINAL_PROBE_RESPONSE)
                sent_probe_response = True

            if (
                not sent_trust_answer
                and "Doyoutrustthecontentsofthisdirectory?" in compact_tail
            ):
                os.write(master, b"1\r\r")
                sent_trust_answer = True
                sent_trust_continue = True

            if (
                sent_trust_answer
                and not sent_trust_continue
                and "Pressentertocontinue" in compact_tail
            ):
                os.write(master, b"\r")
                sent_trust_continue = True

            if "Continue anyway?" in strip_ansi(visible_tail) and not sent_term_gate_answer:
                os.write(master, b"y\r")
                sent_term_gate_answer = True

            ready_for_prompt = (
                "OpenAICodex" in compact_tail
                and "mock-model" in compact_tail
                and (
                    sent_trust_continue
                    or "Doyoutrustthecontentsofthisdirectory?" not in compact_tail
                )
            )
            if ready_for_prompt and not sent_prompt:
                type_prompt_and_enter(master, USER_TEXT)
                sent_prompt = True
                prompt_sent_at = time.time()

            if (
                sent_prompt
                and request_count < 1
                and prompt_sent_at is not None
                and time.time() - prompt_sent_at > 2.0
                and not prompt_enter_retry_sent
            ):
                os.write(master, b"\r")
                prompt_enter_retry_sent = True

            for marker in STREAM_MARKERS:
                if marker not in marker_first_seen and marker in stripped_text:
                    marker_first_seen[marker] = time.time()

            if FINAL_TEXT in stripped_text and final_answer_visible_at is None:
                final_answer_visible_at = time.time()

            required_markers_visible = all(marker in marker_first_seen for marker in required_markers)
            command_output_sent_to_model = request_count >= 2
            final_not_visible = final_answer_visible_at is None
            if command_output_ready_at is None and final_not_visible:
                if (
                    kill_mode == KILL_MODE_AFTER_MODEL_OUTPUT
                    and required_markers_visible
                    and command_output_sent_to_model
                ):
                    command_output_ready_at = time.time()
                elif (
                    kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT
                    and required_markers_visible
                    and not command_output_sent_to_model
                ):
                    command_output_ready_at = time.time()

            idle_seconds = (
                PRE_MODEL_OUTPUT_IDLE_SECONDS
                if kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT
                else COMMAND_OUTPUT_IDLE_SECONDS
            )
            if (
                command_output_ready_at is not None
                and final_not_visible
                and time.time() - command_output_ready_at >= idle_seconds
            ):
                process.kill()
                killed_after_command_output = True
                break

            if process.poll() is not None:
                break

        if process.poll() is None:
            process.terminate()
            time.sleep(0.5)
        if process.poll() is None:
            process.kill()
        exit_code = process.wait(timeout=5)
    finally:
        try:
            os.close(master)
        except OSError:
            pass

    stripped_output = strip_ansi(output.decode(errors="replace"))
    marker_positions = ordered_marker_positions(stripped_output)
    final_position = stripped_output.find(FINAL_TEXT) if FINAL_TEXT in stripped_output else None
    return {
        "command": command,
        "kill_mode": kill_mode,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_prompt": sent_prompt,
        "prompt_enter_retry_sent": prompt_enter_retry_sent,
        "command_output_ready": command_output_ready_at is not None,
        "killed_after_command_output": killed_after_command_output,
        "final_answer_visible": final_answer_visible_at is not None,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "markers_seen": sorted(marker_first_seen),
        "required_markers": required_markers,
        "required_markers_visible": all(marker in marker_first_seen for marker in required_markers),
        "all_markers_visible": all(marker in marker_first_seen for marker in STREAM_MARKERS),
        "marker_positions": marker_positions,
        "marker_sequence_in_output": marker_sequence_ok(marker_positions),
        "final_position": final_position,
        "output_tail_stripped": stripped_output[-4200:],
        "raw_output_bytes": len(output),
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    kill_mode: str,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    required_markers = (
        PRE_MODEL_STREAM_MARKERS
        if kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT
        else STREAM_MARKERS
    )
    with DelayedFinalCommandOutputServer(kill_mode) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        killed_tui = run_cli_command_output_process_kill_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
            kill_mode,
        )
        after_kill_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        followup_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_last=True,
        )
        final_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

    result: dict[str, Any] = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "kill_mode": kill_mode,
        "killed_tui": killed_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests, required_markers),
        "after_kill_storage": after_kill_storage,
        "final_storage": final_storage,
        "after_kill_line_counts": durable_line_counts(after_kill_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["after_kill_command_timeline_summary"] = summarize_command_timeline(chat_root)
    return result


def build_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> str:
    source_lines = "\n".join(
        f"- `{finding['file']}`: {finding['finding']}"
        for finding in SOURCE_FINDINGS
    )
    if summary["kill_mode"] == KILL_MODE_BEFORE_MODEL_OUTPUT:
        scope_text = (
            "ordinary shell command live output followed by CLI/TUI process death "
            "after the first stdout/stderr markers are visible but before the "
            "command output is sent back to the model."
        )
        verifies_text = """- both real TUIs show the required pre-model stdout/stderr markers;
- neither TUI sends the command output back to the model before being killed;
- both TUI processes are killed before the delayed final assistant answer appears;
- both follow-up `codex exec --json resume --last` surfaces return matching
  normalized CLI JSONL output;
- both follow-up model requests preserve the ordinary resume context equivalently;
- the `.chat` backend keeps at least the neutral command call in canonical
  timeline data without fabricating a command output before original Codex does;
- durable line counts stay aligned with the original rollout after kill and
  after resume."""
        not_yet = (
            "This smoke does not prove arbitrary real filesystem I/O failures, "
            "later-batch command crash variants, app-server loaded-status parity, "
            "complete command crash recovery, or final user-indistinguishability."
        )
    else:
        scope_text = (
            "ordinary shell command output followed by CLI/TUI process death after "
            "the command output is visible and model-facing output has been sent, "
            "but before the first turn receives its final assistant answer."
        )
        verifies_text = """- both real TUIs show all command stdout/stderr markers;
- both TUIs send the command output back to the model before being killed;
- both TUI processes are killed before the delayed final assistant answer appears;
- both follow-up `codex exec --json resume --last` surfaces return matching
  normalized CLI JSONL output;
- both follow-up model contexts preserve the original user message and command
  output markers;
- the `.chat` backend keeps the command mapped as neutral `command_call` /
  `command_output` timeline events;
- durable line counts stay aligned with the original rollout after kill and
  after resume."""
        not_yet = (
            "This smoke does not prove arbitrary real filesystem I/O failures, "
            "command output process death before the output is sent to the model, "
            "later-batch command crash variants, app-server loaded-status parity, "
            "complete command crash recovery, or final user-indistinguishability."
        )
    return f"""# CLI Command Output Process-Kill Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI, waits until a shell command reaches
the requested kill boundary, kills the TUI process before the delayed final
assistant answer can render, and then uses
`codex exec --json resume --last` as the cold CLI resume surface.

## Gate

Before this work, the public `.chat` spec files, formal draft
spec files, vendor manifest, baseline checks, backend mapping, parity matrix,
current reports, and relevant CLI/TUI command-output sources were read. The
unmodified original source tree was used only as the oracle.

## Scope

This smoke covers a narrow T01/T02/T03/R01/H05-adjacent user-visible slice:
{scope_text}

It verifies:

{verifies_text}

This smoke does not claim complete command crash recovery or final
user-indistinguishability.

## Source Basis

{source_lines}

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original-result.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend-result.json
```

## Not Yet Proven

{not_yet}
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-command-output-process-kill-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument(
        "--kill-mode",
        choices=[KILL_MODE_AFTER_MODEL_OUTPUT, KILL_MODE_BEFORE_MODEL_OUTPUT],
        default=KILL_MODE_AFTER_MODEL_OUTPUT,
    )
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

    run_root = output_dir / "run"
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [], args.kill_mode)
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
        args.kill_mode,
    )

    original_tui = original_result["killed_tui"]
    chat_tui = chat_result["killed_tui"]
    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    command_timeline_summary = chat_result["after_kill_command_timeline_summary"]

    after_model_mode = args.kill_mode == KILL_MODE_AFTER_MODEL_OUTPUT
    before_model_mode = args.kill_mode == KILL_MODE_BEFORE_MODEL_OUTPUT
    if before_model_mode:
        scope = "cli-command-output-before-model-process-kill-smoke"
        matrix_slice = [
            "T03-adjacent-live-command-output-visible-before-model-output",
            "R01-cold-resume-after-killed-tui",
            "H05-adjacent-process-kill-before-command-output-model-request",
        ]
        output_boundary_key = "mock_command_output_not_sent_before_kill"
        output_boundary_value = (
            original_tui["response_request_count_after_tui"]
            == chat_tui["response_request_count_after_tui"]
            == 1
        )
        context_preserved = (
            original_mock["second_body_contains_original_user_text"]
            and chat_mock["second_body_contains_original_user_text"]
            and original_mock["second_body_contains_followup_user_text"]
            and chat_mock["second_body_contains_followup_user_text"]
        )
        command_timeline_ok = any(
            "command_call" in (package.get("command_event_types") or [])
            for package in command_timeline_summary.get("packages") or []
        )
        not_yet_proven = [
            "later-batch command crash variants",
            "arbitrary real filesystem I/O failures outside validation failpoints",
            "final command crash recovery parity",
            "final user-indistinguishability",
        ]
    else:
        scope = "cli-command-output-process-kill-smoke"
        matrix_slice = [
            "T01/T02-command-output-after-real-tui-process-kill",
            "T03-adjacent-streamed-output-visible-before-kill",
            "R01-cold-resume-after-killed-tui",
            "H05-adjacent-process-kill-after-command-output",
        ]
        output_boundary_key = "mock_command_output_was_sent_before_kill"
        output_boundary_value = (
            original_mock["second_body_contains_function_output"]
            and chat_mock["second_body_contains_function_output"]
            and original_mock["second_body_contains_all_markers"]
            and chat_mock["second_body_contains_all_markers"]
        )
        context_preserved = (
            original_mock["third_body_contains_original_user_text"]
            and chat_mock["third_body_contains_original_user_text"]
            and original_mock["third_body_contains_followup_user_text"]
            and chat_mock["third_body_contains_followup_user_text"]
            and original_mock["third_body_contains_all_markers"]
            and chat_mock["third_body_contains_all_markers"]
        )
        command_timeline_ok = command_timeline_has_streaming_call(command_timeline_summary)
        not_yet_proven = [
            "command output process death before command output is sent to the model",
            "later-batch command crash variants",
            "arbitrary real filesystem I/O failures outside validation failpoints",
            "final command crash recovery parity",
            "final user-indistinguishability",
        ]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": scope,
        "kill_mode": args.kill_mode,
        "matrix_slice": matrix_slice,
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "binary_checks": binary_checks,
        "original_tui_prompt_sent": original_tui["sent_prompt"],
        "chat_backend_tui_prompt_sent": chat_tui["sent_prompt"],
        "original_tui_required_markers_visible": original_tui["required_markers_visible"],
        "chat_backend_tui_required_markers_visible": chat_tui["required_markers_visible"],
        "original_tui_all_markers_visible": original_tui["all_markers_visible"],
        "chat_backend_tui_all_markers_visible": chat_tui["all_markers_visible"],
        "original_marker_sequence_in_output": (
            original_tui["marker_sequence_in_output"] if after_model_mode else True
        ),
        "chat_backend_marker_sequence_in_output": (
            chat_tui["marker_sequence_in_output"] if after_model_mode else True
        ),
        "original_command_output_ready_before_kill": original_tui["command_output_ready"],
        "chat_backend_command_output_ready_before_kill": chat_tui["command_output_ready"],
        "original_tui_killed_after_command_output": original_tui["killed_after_command_output"],
        "chat_backend_tui_killed_after_command_output": chat_tui["killed_after_command_output"],
        "original_tui_exit_code": original_tui["exit_code"],
        "chat_backend_tui_exit_code": chat_tui["exit_code"],
        "original_tui_final_not_visible": not original_tui["final_answer_visible"],
        "chat_backend_tui_final_not_visible": not chat_tui["final_answer_visible"],
        "tui_response_request_counts_equal_at_kill": output_boundary_value
        if before_model_mode
        else (
            original_tui["response_request_count_after_tui"]
            == chat_tui["response_request_count_after_tui"]
            == 2
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        output_boundary_key: output_boundary_value,
        "followup_context_preserved_after_kill": context_preserved,
        "delayed_final_not_in_followup_context": (
            not original_mock["third_body_contains_delayed_final_text"]
            and not chat_mock["third_body_contains_delayed_final_text"]
        ),
        "after_kill_durable_line_counts_equal": (
            original_result["after_kill_line_counts"] == chat_result["after_kill_line_counts"]
            and bool(original_result["after_kill_line_counts"])
        ),
        "final_durable_line_counts_equal": (
            original_result["final_line_counts"] == chat_result["final_line_counts"]
            and bool(original_result["final_line_counts"])
        ),
        "chat_backend_has_command_timeline_after_kill": command_timeline_ok,
        "original": {
            "killed_tui": original_tui,
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "after_kill_line_counts": original_result["after_kill_line_counts"],
            "final_line_counts": original_result["final_line_counts"],
        },
        "chat_backend": {
            "killed_tui": chat_tui,
            "followup_exec": {
                "command": chat_followup["command"],
                "exit_code": chat_followup["exit_code"],
                "normalized_events": normalize_exec_events(chat_followup["events"]),
                "stderr_tail": chat_followup["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "after_kill_line_counts": chat_result["after_kill_line_counts"],
            "final_line_counts": chat_result["final_line_counts"],
            "after_kill_command_timeline_summary": command_timeline_summary,
        },
        "not_yet_proven": not_yet_proven,
    }

    output_boundary_summary_key = output_boundary_key
    passed = all(
        [
            summary["original_tui_prompt_sent"],
            summary["chat_backend_tui_prompt_sent"],
            summary["original_tui_required_markers_visible"],
            summary["chat_backend_tui_required_markers_visible"],
            summary["original_marker_sequence_in_output"],
            summary["chat_backend_marker_sequence_in_output"],
            summary["original_command_output_ready_before_kill"],
            summary["chat_backend_command_output_ready_before_kill"],
            summary["original_tui_killed_after_command_output"],
            summary["chat_backend_tui_killed_after_command_output"],
            summary["original_tui_final_not_visible"],
            summary["chat_backend_tui_final_not_visible"],
            summary["tui_response_request_counts_equal_at_kill"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary[output_boundary_summary_key],
            summary["followup_context_preserved_after_kill"],
            summary["delayed_final_not_in_followup_context"] if after_model_mode else True,
            summary["after_kill_durable_line_counts_equal"],
            summary["final_durable_line_counts_equal"],
            summary["chat_backend_has_command_timeline_after_kill"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow real CLI/TUI command-output process-kill slice for "
        f"{args.kill_mode}: both original and .chat-backend Codex hit the same "
        "user-visible kill boundary, then resume with matching normalized CLI "
        "output and persisted context. It is not final command crash recovery or "
        "user-indistinguishability evidence."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    if not passed:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
