#!/usr/bin/env python3
"""Run a real CLI/TUI running-thread rejoin parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI path:

    codex --remote <app-server>       # TUI A starts a turn and keeps it running
    codex --remote <app-server> resume <thread-id>
                                      # TUI B rejoins the same running thread

The first TUI uses a shared WebSocket app-server and a delayed mock Responses
API. The second TUI resumes the already-loaded thread before the delayed model
response completes. The smoke checks that the resume does not start a duplicate
model request, that the running user message and eventual assistant answer are
visible in the rejoined TUI, and that durable storage stays aligned.

This is not a final parity claim.
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
import queue
import re
import select
import struct
import subprocess
import sys
import threading
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    MockResponsesServer,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_durable_turn_smoke import sse_response  # noqa: E402


RUNNING_USER_TEXT = "CLI running rejoin active user turn."
RUNNING_ASSISTANT_TEXT = "CLI running rejoin delayed answer from mock model."

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_running_rejoin_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_search_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_server_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/thread_state.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server-client/src/remote.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

ANSI_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ROLLOUT_RE = re.compile(
    r"(?:^|/)(?:archived_)?sessions/\d{4}/\d{2}/\d{2}/"
    r"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?P<thread_id>[^/]+)\.jsonl$"
)
WS_RE = re.compile(r"ws://(?P<addr>127\.0\.0\.1:\d+|localhost:\d+)")
TERMINAL_PROBE_RESPONSE = (
    b"\x1b[20;10R"
    b"\x1b]10;rgb:eeee/eeee/eeee\x07"
    b"\x1b]11;rgb:1111/1111/1111\x07"
    b"\x1b[?64;1;2c"
    b"\x1b[?7u"
)


def strip_ansi(text: str) -> str:
    stripped = ANSI_RE.sub("", text).replace("\r", "\n")
    lines = [line.strip() for line in stripped.splitlines()]
    return "\n".join(line for line in lines if line)


def compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def write_typed_text(master: int, text: str, delay_seconds: float = 0.02) -> None:
    for char in text:
        os.write(master, char.encode("utf-8"))
        time.sleep(delay_seconds)


def type_prompt_and_enter(master: int, text: str) -> None:
    write_typed_text(master, text)
    time.sleep(0.1)
    os.write(master, b"\r")


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def is_original_session_rollout_path(relative_path: str) -> bool:
    return ROLLOUT_RE.search(relative_path) is not None


class DelayedMockResponsesServer(MockResponsesServer):
    def __init__(self, delay_seconds: float) -> None:
        super().__init__(RUNNING_ASSISTANT_TEXT)
        self.delay_seconds = delay_seconds

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        time.sleep(self.delay_seconds)
        return sse_response(
            f"resp-cli-running-rejoin-smoke-{counter}",
            f"msg-cli-running-rejoin-smoke-{counter}",
            RUNNING_ASSISTANT_TEXT,
        )

    def summary(self) -> dict[str, Any]:
        bodies = response_request_bodies(self.requests)
        first_body = bodies[0] if bodies else {}
        return {
            "request_count": len(self.requests),
            "response_request_count": len(bodies),
            "paths": [request.get("path") for request in self.requests],
            "first_response_model": first_body.get("model"),
            "first_response_input_contains_running_user_text": body_contains(
                first_body, RUNNING_USER_TEXT
            ),
        }


class AppServerProcess:
    def __init__(
        self,
        codex_bin: pathlib.Path,
        workspace: pathlib.Path,
        codex_home: pathlib.Path,
        config_overrides: list[str],
    ) -> None:
        command = [str(codex_bin)]
        for override in config_overrides:
            command.extend(["--config", override])
        command.extend(["app-server", "--listen", "ws://127.0.0.1:0"])

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env.setdefault("RUST_LOG", "warn")

        self.command = command
        self.process = subprocess.Popen(
            command,
            cwd=str(workspace),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stderr is not None
        self._stderr_queue: queue.Queue[str] = queue.Queue()
        self._stderr_lines: list[str] = []
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stderr_thread.start()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self._stderr_lines.append(line)
            self._stderr_queue.put(line)

    def wait_for_remote_url(self, timeout_seconds: float = 20.0) -> str:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if self.process.poll() is not None and self._stderr_queue.empty():
                break
            try:
                line = self._stderr_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            stripped = ANSI_RE.sub("", line)
            match = WS_RE.search(stripped)
            if match:
                return f"ws://{match.group('addr')}"
        raise TimeoutError(
            "timed out waiting for app-server websocket address; "
            f"exit={self.process.poll()} stderr={self.stderr_tail()}"
        )

    def stderr_tail(self) -> str:
        return "".join(self._stderr_lines)[-6000:]

    def close(self) -> int | None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        return self.process.returncode


class TuiProcess:
    def __init__(
        self,
        command: list[str],
        workspace: pathlib.Path,
        codex_home: pathlib.Path,
        *,
        rows: int = 34,
        cols: int = 128,
    ) -> None:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["TERM"] = "xterm-256color"
        env.setdefault("RUST_LOG", "warn")

        master, slave = pty.openpty()
        try:
            import fcntl
            import termios

            winsize = struct.pack("HHHH", rows, cols, 0, 0)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)
        except OSError:
            pass

        self.command = command
        self.master = master
        self.output = b""
        self.started_at = time.time()
        self.state: dict[str, Any] = {
            "sent_probe_response": False,
            "sent_trust_answer": False,
            "sent_trust_continue": False,
            "sent_term_gate_answer": False,
            "sent_ctrl_c": False,
        }
        self.process = subprocess.Popen(
            command,
            cwd=str(workspace),
            env=env,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            text=False,
        )
        os.close(slave)

    def pump(self, timeout_seconds: float = 0.05) -> None:
        if self.process.poll() is not None:
            return
        readable, _, _ = select.select([self.master], [], [], timeout_seconds)
        if not readable:
            return
        try:
            chunk = os.read(self.master, 8192)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            return
        if chunk:
            self.output += chunk
            self._handle_terminal_probes()

    def _handle_terminal_probes(self) -> None:
        visible_tail = self.visible()[-2400:]
        compact_tail = compact(strip_ansi(visible_tail))
        if not self.state["sent_probe_response"] and (
            "\x1b[6n" in visible_tail
            or "]10;?" in visible_tail
            or "[?u" in visible_tail
        ):
            os.write(self.master, TERMINAL_PROBE_RESPONSE)
            self.state["sent_probe_response"] = True
        if (
            not self.state["sent_trust_answer"]
            and "Doyoutrustthecontentsofthisdirectory?" in compact_tail
        ):
            os.write(self.master, b"1\r\r")
            self.state["sent_trust_answer"] = True
            self.state["sent_trust_continue"] = True
        if (
            self.state["sent_trust_answer"]
            and not self.state["sent_trust_continue"]
            and "Pressentertocontinue" in compact_tail
        ):
            os.write(self.master, b"\r")
            self.state["sent_trust_continue"] = True
        if "Continue anyway?" in visible_tail and not self.state["sent_term_gate_answer"]:
            os.write(self.master, b"y\r")
            self.state["sent_term_gate_answer"] = True

    def visible(self) -> str:
        return self.output.decode(errors="replace")

    def stripped(self) -> str:
        return strip_ansi(self.visible())

    def compact_output(self) -> str:
        return compact(self.stripped())

    def write(self, data: bytes) -> None:
        os.write(self.master, data)

    def close(self) -> dict[str, Any]:
        if self.process.poll() is None:
            try:
                os.write(self.master, b"\x03")
                self.state["sent_ctrl_c"] = True
            except OSError:
                pass
            time.sleep(0.5)
        if self.process.poll() is None:
            self.process.terminate()
            time.sleep(0.5)
        if self.process.poll() is None:
            self.process.kill()
        try:
            exit_code = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            exit_code = self.process.wait(timeout=5)
        try:
            os.close(self.master)
        except OSError:
            pass
        stripped = self.stripped()
        return {
            "command": self.command,
            "exit_code": exit_code,
            "duration_seconds": round(time.time() - self.started_at, 3),
            **self.state,
            "raw_output_bytes": len(self.output),
            "output_tail_stripped": stripped[-4000:],
        }


def original_thread_ids(codex_home: pathlib.Path) -> list[str]:
    ids: list[str] = []
    for relative_path in summarize_original_storage(codex_home).get("rollout_files", []):
        match = ROLLOUT_RE.search(relative_path)
        if match:
            ids.append(match.group("thread_id"))
    return sorted(set(ids))


def chat_thread_ids(chat_root: pathlib.Path) -> list[str]:
    return sorted(
        package.get("conversation_id")
        for package in summarize_chat_packages(chat_root).get("packages", [])
        if package.get("conversation_id")
    )


def thread_ids_for_tree(
    tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path
) -> list[str]:
    if tree_name == "chat-backend":
        return chat_thread_ids(chat_root)
    return original_thread_ids(codex_home)


def durable_line_counts(
    tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path
) -> list[int]:
    if tree_name == "chat-backend":
        summary = summarize_chat_packages(chat_root)
        return sorted(
            package.get("journal_line_count")
            for package in summary.get("packages", [])
            if package.get("journal_line_count") is not None
        )
    summary = summarize_original_storage(codex_home)
    return sorted(
        rollout.get("line_count")
        for rollout in summary.get("rollouts", [])
        if rollout.get("line_count") is not None
        and is_original_session_rollout_path(rollout.get("path") or "")
    )


def chat_package_running_rejoin_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    files = set(package.get("files") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 8
        and package.get("journal_line_count", 0) >= 8
        and "message" in event_types
        and "runtime_context_snapshot" in event_types
        and "projections/chat-read.ndjson" in files
        and "projections/model-context.ndjson" in files
        and "projections/audit.ndjson" in files
    )


def tui_command(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    config_overrides: list[str],
    remote_url: str,
    extra_args: list[str] | None = None,
) -> list[str]:
    command = [str(codex_bin)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(["--remote", remote_url, "--cd", str(workspace)])
    if extra_args:
        command.extend(extra_args)
    return command


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with DelayedMockResponsesServer(delay_seconds=8.0) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        app_server = AppServerProcess(codex_bin, workspace, codex_home, config_overrides)
        first_tui: TuiProcess | None = None
        second_tui: TuiProcess | None = None
        app_server_exit: int | None = None
        try:
            remote_url = app_server.wait_for_remote_url()
            first_tui = TuiProcess(
                tui_command(codex_bin, workspace, config_overrides, remote_url),
                workspace,
                codex_home,
            )

            state = {
                "sent_first_prompt": False,
                "first_prompt_sent_at": None,
                "first_prompt_enter_retry_sent": False,
                "first_model_request_seen_at": None,
                "thread_id": None,
                "started_second_tui_at": None,
                "second_running_user_visible_at": None,
                "second_running_assistant_visible_at": None,
                "first_running_assistant_visible_at": None,
            }
            deadline = time.time() + 95
            while time.time() < deadline:
                first_tui.pump()
                if second_tui is not None:
                    second_tui.pump()

                first_compact = first_tui.compact_output()
                first_stripped = first_tui.stripped()
                ready_for_prompt = (
                    "OpenAICodex" in first_compact
                    and "mock-model" in first_compact
                    and (
                        "Togetstarted" in first_compact
                        or "/init-createanAGENTS" in first_compact
                    )
                    and (
                        first_tui.state["sent_trust_continue"]
                        or "Doyoutrustthecontentsofthisdirectory?" not in first_compact
                    )
                    and not state["sent_first_prompt"]
                )
                if ready_for_prompt:
                    type_prompt_and_enter(first_tui.master, RUNNING_USER_TEXT)
                    state["sent_first_prompt"] = True
                    state["first_prompt_sent_at"] = time.time()

                response_count = mock_server.summary()["response_request_count"]
                if (
                    state["sent_first_prompt"]
                    and response_count < 1
                    and state["first_prompt_sent_at"] is not None
                    and time.time() - state["first_prompt_sent_at"] > 2.0
                    and not state["first_prompt_enter_retry_sent"]
                ):
                    first_tui.write(b"\r")
                    state["first_prompt_enter_retry_sent"] = True

                if response_count >= 1 and state["first_model_request_seen_at"] is None:
                    state["first_model_request_seen_at"] = time.time()

                ids = thread_ids_for_tree(tree_name, codex_home, chat_root)
                if len(ids) == 1 and state["thread_id"] is None:
                    state["thread_id"] = ids[0]

                if (
                    state["first_model_request_seen_at"] is not None
                    and state["thread_id"] is not None
                    and second_tui is None
                ):
                    second_tui = TuiProcess(
                        tui_command(
                            codex_bin,
                            workspace,
                            config_overrides,
                            remote_url,
                            ["resume", state["thread_id"]],
                        ),
                        workspace,
                        codex_home,
                    )
                    state["started_second_tui_at"] = time.time()

                if second_tui is not None:
                    second_stripped = second_tui.stripped()
                    second_compact = second_tui.compact_output()
                    if (
                        state["second_running_user_visible_at"] is None
                        and (
                            RUNNING_USER_TEXT in second_stripped
                            or compact(RUNNING_USER_TEXT) in second_compact
                        )
                    ):
                        state["second_running_user_visible_at"] = time.time()
                    if (
                        state["second_running_assistant_visible_at"] is None
                        and (
                            RUNNING_ASSISTANT_TEXT in second_stripped
                            or compact(RUNNING_ASSISTANT_TEXT) in second_compact
                        )
                    ):
                        state["second_running_assistant_visible_at"] = time.time()

                if (
                    state["first_running_assistant_visible_at"] is None
                    and (
                        RUNNING_ASSISTANT_TEXT in first_stripped
                        or compact(RUNNING_ASSISTANT_TEXT) in first_compact
                    )
                ):
                    state["first_running_assistant_visible_at"] = time.time()

                if (
                    state["second_running_assistant_visible_at"] is not None
                    and state["first_running_assistant_visible_at"] is not None
                    and time.time() - state["second_running_assistant_visible_at"] > 1.0
                ):
                    break

                if first_tui.process.poll() is not None:
                    break
                time.sleep(0.05)

            first_result = first_tui.close()
            second_result = (
                second_tui.close()
                if second_tui is not None
                else {"not_started": True}
            )
        finally:
            app_server_exit = app_server.close()

        mock_summary = mock_server.summary()

    storage_summary = (
        summarize_chat_packages(chat_root)
        if tree_name == "chat-backend"
        else summarize_original_storage(codex_home)
    )
    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "app_server": {
            "command": app_server.command,
            "exit_code": app_server_exit,
            "stderr_tail": app_server.stderr_tail(),
        },
        "first_tui": first_result,
        "second_tui": second_result,
        "state": state,
        "mock_server_summary": mock_summary,
        "durable_line_counts": durable_line_counts(tree_name, codex_home, chat_root),
        "storage_summary": storage_summary,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    state = result["state"]
    mock = result["mock_server_summary"]
    return {
        "sent_first_prompt": state["sent_first_prompt"],
        "first_model_request_seen": state["first_model_request_seen_at"] is not None,
        "thread_id_present": state["thread_id"] is not None,
        "started_second_tui": state["started_second_tui_at"] is not None,
        "second_running_user_visible": state["second_running_user_visible_at"] is not None,
        "second_running_assistant_visible": (
            state["second_running_assistant_visible_at"] is not None
        ),
        "first_running_assistant_visible": (
            state["first_running_assistant_visible_at"] is not None
        ),
        "mock_response_request_count": mock["response_request_count"],
        "mock_first_request_contains_running_user": mock[
            "first_response_input_contains_running_user_text"
        ],
        "durable_line_counts": result["durable_line_counts"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Running Rejoin Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final R03 parity and not final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Second TUI saw running user message on both backends: `{summary['second_tui_saw_running_user_both']}`",
        f"- Second TUI saw final live assistant answer on both backends: `{summary['second_tui_saw_live_answer_both']}`",
        f"- Mock request counts equal and not duplicated: `{summary['mock_request_counts_equal_and_single']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        f"- `.chat` package valid for this slice: `{summary['chat_package_running_rejoin_ok']}`",
        "",
        "## Scope",
        "",
        "The smoke starts a shared WebSocket app-server, launches one real TUI to",
        "start a delayed model turn, then launches a second real TUI with",
        "`codex --remote <server> resume <thread-id>` before the delayed response",
        "completes. The second TUI must attach to the already-running thread, show",
        "the running user message, and receive the eventual assistant answer without",
        "causing another model request.",
        "",
        "## Not Proven",
        "",
    ]
    lines.extend(f"- {item}" for item in summary["not_yet_proven"])
    (output_dir / "report.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-running-rejoin-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
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
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_normalized = normalized_tree_summary(original_result)
    chat_normalized = normalized_tree_summary(chat_result)
    durable_line_counts_equal = (
        original_normalized["durable_line_counts"]
        == chat_normalized["durable_line_counts"]
        and len(original_normalized["durable_line_counts"]) == 1
    )
    normalized_summaries_equal = original_normalized == chat_normalized
    mock_request_counts_equal_and_single = (
        original_normalized["mock_response_request_count"]
        == chat_normalized["mock_response_request_count"]
        == 1
    )
    second_tui_saw_running_user_both = (
        original_normalized["second_running_user_visible"]
        and chat_normalized["second_running_user_visible"]
    )
    second_tui_saw_live_answer_both = (
        original_normalized["second_running_assistant_visible"]
        and chat_normalized["second_running_assistant_visible"]
    )
    first_tui_saw_live_answer_both = (
        original_normalized["first_running_assistant_visible"]
        and chat_normalized["first_running_assistant_visible"]
    )
    chat_package_summary = chat_result["storage_summary"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-running-rejoin-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "second_tui_saw_running_user_both": second_tui_saw_running_user_both,
        "second_tui_saw_live_answer_both": second_tui_saw_live_answer_both,
        "first_tui_saw_live_answer_both": first_tui_saw_live_answer_both,
        "mock_request_counts_equal_and_single": mock_request_counts_equal_and_single,
        "durable_line_counts_equal": durable_line_counts_equal,
        "chat_package_running_rejoin_ok": chat_package_running_rejoin_ok(
            chat_package_summary
        ),
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI/TUI running-rejoin slice: a "
            "second real TUI can resume an already-running thread through the "
            "same remote app-server, see the running user message, receive the "
            "eventual assistant answer, avoid a duplicate model request, and "
            "keep original-vs-.chat durable storage counts aligned."
        ),
        "not_yet_proven": [
            "full R03 running rejoin through every daemon/local/remote mode",
            "running rejoin via resume picker UI instead of explicit thread id",
            "goal snapshot and token usage visual parity for this TUI path",
            "stale path rejection and override warning through this TUI path",
            "unload race behavior through this TUI path",
            "fork/rollback/compaction/list/search/archive parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    summary["passed"] = all(
        [
            normalized_summaries_equal,
            second_tui_saw_running_user_both,
            second_tui_saw_live_answer_both,
            first_tui_saw_live_answer_both,
            mock_request_counts_equal_and_single,
            durable_line_counts_equal,
            summary["chat_package_running_rejoin_ok"],
        ]
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    write_markdown_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
