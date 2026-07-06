#!/usr/bin/env python3
"""Run real `codex exec --json` command side-effect parity smoke.

This source-backed validation covers a narrow user-facing CLI slice where the model
requests a shell command that creates a workspace file. It compares the
unmodified original backend with the adapted `.chat` backend for normalized CLI
events, model-visible command output round-trip, created file contents, durable
line counts, and neutral `.chat` command timeline mapping.

This proves a workspace side-effect command slice. It does not prove standard
`.chat` artifact/blob packaging for command-created files.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import hashlib
import http.server
import json
import os
import pathlib
import subprocess
import sys
import threading
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_command_execution_smoke import (  # noqa: E402
    ev_completed,
    ev_response_created,
    sse,
    summarize_command_timeline,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_command_execution_smoke import (  # noqa: E402
    completed_command_events,
    normalize_cli_events,
    parse_jsonl,
    response_request_bodies,
    thread_ids_from_events,
)


USER_TEXT = "Create the CLI command artifact smoke file."
FINAL_TEXT = "CLI command artifact smoke complete."
ARTIFACT_CALL_ID = "call-command-artifact"
ARTIFACT_FILE = "cli-command-artifact.txt"
ARTIFACT_CONTENT = "artifact payload from command\n"
ARTIFACT_COMMAND = (
    "python3 -c 'from pathlib import Path; import sys; "
    "p = Path(\"cli-command-artifact.txt\"); "
    "p.write_text(\"artifact payload from command\\n\", encoding=\"utf-8\"); "
    "print(\"ARTIFACT_STDOUT:\" + p.read_text(encoding=\"utf-8\").strip()); "
    "print(\"ARTIFACT_STDERR:\" + str(p), file=sys.stderr)'"
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
    "Conformance/Chat/CodexCliValidation/tests/cli_command_execution_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_execution_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/src/event_processor_with_jsonl_output.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def ev_shell_command_call(response_id: str, call_id: str, command: str) -> bytes:
    arguments = json.dumps(
        {
            "command": command,
            "workdir": None,
            "timeout_ms": 10000,
        },
        separators=(",", ":"),
    )
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": call_id,
                    "name": "shell_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-cli-command-artifact-final",
                    "content": [{"type": "output_text", "text": FINAL_TEXT}],
                },
            },
            ev_completed(response_id),
        ]
    )


class ArtifactResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_shell_command_call("resp-command-artifact-1", ARTIFACT_CALL_ID, ARTIFACT_COMMAND),
            ev_final_message("resp-command-artifact-2"),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "ArtifactResponsesServer":
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

    def next_sse_body(self) -> bytes:
        with self._lock:
            index = len(
                [request for request in self.requests if request["path"].endswith("/responses")]
            )
        if index < 1 or index > len(self.responses):
            return ev_final_message("resp-command-artifact-extra")
        return self.responses[index - 1]

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

    def _make_handler(self) -> type[http.server.BaseHTTPRequestHandler]:
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
                server: ArtifactResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        return Handler


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    serialized_bodies = [json.dumps(body, ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "contains_artifact_function_output": any(
            ARTIFACT_CALL_ID in body and "function_call_output" in body
            for body in serialized_bodies
        ),
        "contains_artifact_stdout": any("ARTIFACT_STDOUT" in body for body in serialized_bodies),
        "contains_artifact_stderr": any("ARTIFACT_STDERR" in body for body in serialized_bodies),
        "contains_artifact_filename": any(ARTIFACT_FILE in body for body in serialized_bodies),
    }


def run_cli_exec(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    command = [str(codex_bin)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(
        [
            "exec",
            "--skip-git-repo-check",
            "--json",
            "--color",
            "never",
            "--sandbox",
            "workspace-write",
            "--cd",
            str(workspace),
            USER_TEXT,
        ]
    )

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env.setdefault("RUST_LOG", "warn")

    started_at = time.time()
    completed = subprocess.run(
        command,
        cwd=str(workspace),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
        check=False,
    )
    events = parse_jsonl(completed.stdout) if completed.stdout else []
    return {
        "command": command,
        "exit_code": completed.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-6000:],
        "events": events,
        "normalized_events": normalize_cli_events(events),
        "completed_command_events": completed_command_events(events),
        "thread_ids": thread_ids_from_events(events),
    }


def summarize_rollout_line_counts(codex_home: pathlib.Path) -> dict[str, Any]:
    summary = summarize_original_storage(codex_home)
    line_counts = [rollout["line_count"] for rollout in summary.get("rollouts", [])]
    return {
        "summary": summary,
        "rollout_file_count": len(summary.get("rollouts", [])),
        "rollout_line_counts": line_counts,
        "total_rollout_lines": sum(line_counts),
    }


def summarize_chat_line_counts(chat_root: pathlib.Path) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    packages = summary.get("packages", [])
    return {
        "summary": summary,
        "package_count": summary.get("package_count"),
        "timeline_line_counts": [package.get("timeline_line_count") for package in packages],
        "journal_line_counts": [package.get("journal_line_count") for package in packages],
        "total_timeline_lines": sum(package.get("timeline_line_count", 0) for package in packages),
        "total_journal_lines": sum(package.get("journal_line_count", 0) for package in packages),
    }


def inspect_workspace_artifact(workspace: pathlib.Path) -> dict[str, Any]:
    path = workspace / ARTIFACT_FILE
    if not path.exists():
        return {
            "exists": False,
            "relative_path": ARTIFACT_FILE,
            "content": None,
            "sha256": None,
            "size": None,
        }
    data = path.read_bytes()
    return {
        "exists": True,
        "relative_path": ARTIFACT_FILE,
        "content": data.decode("utf-8"),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    }


def inspect_chat_package_files(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {"package_exists": False}
    package = packages[0]
    timeline = read_json_lines(package / "timeline.ndjson")
    journal = read_json_lines(package / "journal.ndjson")
    projections_dir = package / "projections"
    projections = (
        sorted(item.relative_to(package).as_posix() for item in projections_dir.glob("*.ndjson"))
        if projections_dir.exists()
        else []
    )
    command_events = [
        line for line in timeline if str(line.get("type")).startswith("command")
    ]
    artifact_files = sorted(
        item.relative_to(package).as_posix()
        for item in (package / "artifacts").glob("**/*")
        if item.is_file()
    )
    blob_files = sorted(
        item.relative_to(package).as_posix()
        for item in (package / "blobs").glob("**/*")
        if item.is_file()
    )
    artifact_refs = []
    blob_refs = []
    for line in timeline:
        body = line.get("body") or {}
        for artifact_ref in body.get("artifact_refs") or []:
            artifact_refs.append(
                {
                    "source_event_id": artifact_ref.get("source_event_id"),
                    "path": artifact_ref.get("path"),
                    "blob_path": artifact_ref.get("blob_path"),
                    "hash": artifact_ref.get("hash"),
                    "size": artifact_ref.get("size"),
                    "status": artifact_ref.get("status"),
                }
            )
        for blob_ref in body.get("blob_refs") or []:
            blob_path = blob_ref.get("path")
            blob_file = package / blob_path if isinstance(blob_path, str) else None
            blob_data = blob_file.read_bytes() if blob_file and blob_file.exists() else b""
            blob_text = blob_data.decode("utf-8", errors="replace")
            actual_hash = f"sha256:{hashlib.sha256(blob_data).hexdigest()}" if blob_data else None
            blob_refs.append(
                {
                    "source_event_id": blob_ref.get("source_event_id"),
                    "path": blob_path,
                    "hash": blob_ref.get("hash"),
                    "actual_hash": actual_hash,
                    "hash_matches": actual_hash == blob_ref.get("hash"),
                    "size": blob_ref.get("size"),
                    "actual_size": len(blob_data) if blob_file and blob_file.exists() else None,
                    "size_matches": (
                        blob_ref.get("size") == len(blob_data)
                        if blob_file and blob_file.exists()
                        else False
                    ),
                    "status": blob_ref.get("status"),
                    "exists": bool(blob_file and blob_file.exists()),
                    "contains_artifact_stdout": "ARTIFACT_STDOUT" in blob_text,
                    "contains_artifact_stderr": "ARTIFACT_STDERR" in blob_text,
                    "contains_artifact_filename": ARTIFACT_FILE in blob_text,
                }
            )
    artifact_metadata_refs = []
    for artifact_ref in artifact_refs:
        artifact_path = artifact_ref.get("path")
        artifact_file = package / artifact_path if isinstance(artifact_path, str) else None
        metadata = None
        if artifact_file and artifact_file.exists():
            metadata = json.loads(artifact_file.read_text())
        artifact_metadata_refs.append(
            {
                "path": artifact_path,
                "exists": bool(artifact_file and artifact_file.exists()),
                "source_event_id": metadata.get("source_event_id") if metadata else None,
                "blob_path": (metadata.get("blob") or {}).get("path") if metadata else None,
                "hash": metadata.get("hash") if metadata else None,
                "hash_matches_ref": (
                    metadata.get("hash") == artifact_ref.get("hash") if metadata else False
                ),
            }
        )
    return {
        "package_exists": True,
        "package": str(package),
        "artifact_files": artifact_files,
        "blob_files": blob_files,
        "artifact_ref_count": len(artifact_refs),
        "blob_ref_count": len(blob_refs),
        "artifact_refs": artifact_refs,
        "blob_refs": blob_refs,
        "artifact_metadata_refs": artifact_metadata_refs,
        "timeline_event_types": [line.get("type") for line in timeline],
        "journal_entry_count": len(journal),
        "projection_files": projections,
        "has_chat_read_projection": "projections/chat-read.ndjson" in projections,
        "has_model_context_projection": "projections/model-context.ndjson" in projections,
        "has_audit_projection": "projections/audit.ndjson" in projections,
        "command_event_types": [line.get("type") for line in command_events],
        "command_call_ids": [
            ((line.get("body") or {}).get("call_id")) for line in command_events
        ],
        "source_response_types": [
            ((line.get("body") or {}).get("source_response_type"))
            for line in command_events
        ],
    }


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

    with ArtifactResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        exec_result = run_cli_exec(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
        )

    result: dict[str, Any] = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "exec": exec_result,
        "workspace_artifact": inspect_workspace_artifact(workspace),
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
    }
    if tree_name == "chat-backend":
        result["chat_storage"] = summarize_chat_line_counts(chat_root)
        result["chat_package_files"] = inspect_chat_package_files(chat_root)
        result["command_timeline_summary"] = summarize_command_timeline(chat_root)
    else:
        result["original_storage"] = summarize_rollout_line_counts(codex_home)
    return result


def artifact_command_completed(events: list[dict[str, Any]]) -> bool:
    completed = completed_command_events(events)
    return any(
        event.get("exit_code") == 0
        and "ARTIFACT_STDOUT" in (event.get("output") or "")
        and "ARTIFACT_STDERR" in (event.get("output") or "")
        and ARTIFACT_FILE in (event.get("output") or "")
        for event in completed
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-command-artifact-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_events = original_result["exec"]["normalized_events"]
    chat_events = chat_result["exec"]["normalized_events"]
    original_completed = original_result["exec"]["completed_command_events"]
    chat_completed = chat_result["exec"]["completed_command_events"]
    original_artifact = original_result["workspace_artifact"]
    chat_artifact = chat_result["workspace_artifact"]
    original_lines = original_result["original_storage"]["total_rollout_lines"]
    chat_journal_lines = chat_result["chat_storage"]["total_journal_lines"]
    chat_package = chat_result["chat_package_files"]
    command_timeline_summary = chat_result["command_timeline_summary"]
    command_event_types = [
        event_type
        for package in command_timeline_summary["packages"]
        for event_type in package["command_event_types"]
    ]
    command_call_ids = [
        call_id
        for package in command_timeline_summary["packages"]
        for call_id in package["call_ids"]
    ]
    source_response_types = [
        source_response_type
        for package in command_timeline_summary["packages"]
        for source_response_type in package["source_response_types"]
    ]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-command-artifact-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_exec_exit_ok": original_result["exec"]["exit_code"] == 0,
        "chat_backend_exec_exit_ok": chat_result["exec"]["exit_code"] == 0,
        "normalized_cli_events_equal": original_events == chat_events,
        "completed_command_events_equal": original_completed == chat_completed,
        "original_command_completed_with_artifact_output": artifact_command_completed(
            original_result["exec"]["events"]
        ),
        "chat_backend_command_completed_with_artifact_output": artifact_command_completed(
            chat_result["exec"]["events"]
        ),
        "workspace_artifacts_equal": (
            original_artifact["exists"] is True
            and chat_artifact["exists"] is True
            and original_artifact["content"] == chat_artifact["content"] == ARTIFACT_CONTENT
            and original_artifact["sha256"] == chat_artifact["sha256"]
        ),
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
            == 2
        ),
        "mock_function_call_outputs_equal": (
            original_result["mock_server_summary"]
            == chat_result["mock_server_summary"]
        ),
        "mock_outputs_round_trip": (
            original_result["mock_server_summary"]["contains_artifact_function_output"]
            and original_result["mock_server_summary"]["contains_artifact_stdout"]
            and original_result["mock_server_summary"]["contains_artifact_stderr"]
            and original_result["mock_server_summary"]["contains_artifact_filename"]
            and chat_result["mock_server_summary"]["contains_artifact_function_output"]
            and chat_result["mock_server_summary"]["contains_artifact_stdout"]
            and chat_result["mock_server_summary"]["contains_artifact_stderr"]
            and chat_result["mock_server_summary"]["contains_artifact_filename"]
        ),
        "original_rollout_lines_equal_chat_journal_lines": (
            original_lines == chat_journal_lines and original_lines > 0
        ),
        "chat_package_materialized": (
            chat_result["chat_storage"]["package_count"] == 1
            and chat_package.get("package_exists") is True
        ),
        "chat_package_has_standard_projections": (
            chat_package.get("has_chat_read_projection") is True
            and chat_package.get("has_model_context_projection") is True
            and chat_package.get("has_audit_projection") is True
        ),
        "chat_timeline_has_command_call": "command_call" in command_event_types,
        "chat_timeline_has_command_output": "command_output" in command_event_types,
        "chat_timeline_has_artifact_call_id": ARTIFACT_CALL_ID in command_call_ids,
        "chat_timeline_has_source_transport_mapping": (
            "function_call" in source_response_types
            and "function_call_output" in source_response_types
        ),
        "chat_package_has_standard_artifact_blob_refs": (
            chat_package.get("artifact_ref_count", 0) > 0
            and chat_package.get("blob_ref_count", 0) > 0
            and all(ref.get("exists") for ref in chat_package.get("blob_refs", []))
            and all(ref.get("hash_matches") for ref in chat_package.get("blob_refs", []))
            and all(ref.get("size_matches") for ref in chat_package.get("blob_refs", []))
            and all(
                ref.get("exists") and ref.get("hash_matches_ref")
                for ref in chat_package.get("artifact_metadata_refs", [])
            )
        ),
        "chat_output_blob_contains_artifact_markers": any(
            ref.get("contains_artifact_stdout")
            and ref.get("contains_artifact_stderr")
            and ref.get("contains_artifact_filename")
            for ref in chat_package.get("blob_refs", [])
        ),
        "commands": {
            "artifact_call_id": ARTIFACT_CALL_ID,
            "artifact_file": ARTIFACT_FILE,
            "artifact_command": ARTIFACT_COMMAND,
        },
        "original": {
            "exec": {
                "command": original_result["exec"]["command"],
                "exit_code": original_result["exec"]["exit_code"],
                "normalized_events": original_events,
                "completed_command_events": original_completed,
                "thread_ids": original_result["exec"]["thread_ids"],
                "stderr_tail": original_result["exec"]["stderr_tail"],
            },
            "workspace_artifact": original_artifact,
            "mock_server_summary": original_result["mock_server_summary"],
            "storage": original_result["original_storage"],
        },
        "chat_backend": {
            "exec": {
                "command": chat_result["exec"]["command"],
                "exit_code": chat_result["exec"]["exit_code"],
                "normalized_events": chat_events,
                "completed_command_events": chat_completed,
                "thread_ids": chat_result["exec"]["thread_ids"],
                "stderr_tail": chat_result["exec"]["stderr_tail"],
            },
            "workspace_artifact": chat_artifact,
            "mock_server_summary": chat_result["mock_server_summary"],
            "storage": chat_result["chat_storage"],
            "chat_package_files": chat_package,
            "command_timeline_summary": command_timeline_summary,
        },
        "not_yet_proven": [
            "automatic packaging of arbitrary command-created workspace side-effect files as portable blobs",
            "approval/permission command flow",
            "crash recovery during command execution",
            "complete command data fidelity report",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_exec_exit_ok"],
            summary["chat_backend_exec_exit_ok"],
            summary["normalized_cli_events_equal"],
            summary["completed_command_events_equal"],
            summary["original_command_completed_with_artifact_output"],
            summary["chat_backend_command_completed_with_artifact_output"],
            summary["workspace_artifacts_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_function_call_outputs_equal"],
            summary["mock_outputs_round_trip"],
            summary["original_rollout_lines_equal_chat_journal_lines"],
            summary["chat_package_materialized"],
            summary["chat_package_has_standard_projections"],
            summary["chat_timeline_has_command_call"],
            summary["chat_timeline_has_command_output"],
            summary["chat_timeline_has_artifact_call_id"],
            summary["chat_timeline_has_source_transport_mapping"],
            summary["chat_package_has_standard_artifact_blob_refs"],
            summary["chat_output_blob_contains_artifact_markers"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow CLI command side-effect slice: `codex exec --json` "
        "runs a model-requested command that creates a workspace file, both "
        "backends produce matching normalized user-visible CLI events, the file "
        "contents match, the command output round-trips to the model, original "
        "rollout line count equals .chat journal line count, and the .chat "
        "timeline exposes neutral command_call/command_output events plus "
        "standard artifact/blob references for the persisted command-output "
        "evidence. It does not prove automatic portable packaging of arbitrary "
        "workspace side-effect files or final CLI parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)

    if not passed:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
