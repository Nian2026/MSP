#!/usr/bin/env python3
"""Run a minimal app-server thread/start + thread/list smoke for both trees.

This is source-backed validation tooling for the MSP `.chat` Codex CLI evidence
package. It drives the real `codex app-server` JSON-RPC stdio path rather than
calling Rust unit-test helpers directly.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
ORIGINAL_CODEX_RS = VALIDATION_DIR / "upstream/openai-codex-original/codex-rs"
CHAT_BACKEND_CODEX_RS = (
    VALIDATION_DIR / "upstream/openai-codex-chat-backend/codex-rs"
)


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run_command(command: list[str], cwd: pathlib.Path) -> dict[str, Any]:
    started_at = time.time()
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return {
        "command": command,
        "cwd": str(cwd),
        "exit_code": completed.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def ensure_binary(codex_rs: pathlib.Path, build_if_missing: bool) -> dict[str, Any]:
    binary = codex_rs / "target/debug/codex"
    if binary.exists():
        return {
            "built": False,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
        }

    if not build_if_missing:
        raise RuntimeError(
            f"missing {binary}; run `cargo build -p codex-cli --bin codex` first"
        )

    result = run_command(["cargo", "build", "-p", "codex-cli", "--bin", "codex"], codex_rs)
    if result["exit_code"] != 0 or not binary.exists():
        raise RuntimeError(f"failed to build {binary}: {result}")
    result.update(
        {
            "built": True,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
        }
    )
    return result


class JsonRpcClient:
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
        command.append("app-server")

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env.setdefault("RUST_LOG", "warn")

        self.command = command
        self.process = subprocess.Popen(
            command,
            cwd=str(workspace),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.sent: list[dict[str, Any]] = []
        self.received: list[dict[str, Any]] = []

    def send(self, message: dict[str, Any]) -> None:
        payload = json.dumps(message, separators=(",", ":"))
        self.sent.append(message)
        assert self.process.stdin is not None
        self.process.stdin.write(payload + "\n")
        self.process.stdin.flush()

    def receive_until_response(self, request_id: int, timeout_seconds: int) -> dict[str, Any]:
        deadline = time.time() + timeout_seconds
        assert self.process.stdout is not None
        while time.time() < deadline:
            line = self.process.stdout.readline()
            if line:
                payload = line.strip()
                try:
                    message = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                self.received.append(message)
                if message.get("id") == request_id and (
                    "result" in message or "error" in message
                ):
                    return message
            elif self.process.poll() is not None:
                break
        raise TimeoutError(
            f"timed out waiting for response id {request_id}; "
            f"process status={self.process.poll()}"
        )

    def close(self) -> str:
        try:
            self.process.terminate()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()
            self.process.wait(timeout=5)
        assert self.process.stderr is not None
        return self.process.stderr.read()


def normalize_thread_start_response(response: dict[str, Any]) -> dict[str, Any]:
    result = response.get("result", {})
    thread = result.get("thread", {})
    sandbox = result.get("sandbox", {})
    active_permission_profile = result.get("activePermissionProfile")
    return {
        "has_error": "error" in response,
        "model": result.get("model"),
        "model_provider": result.get("modelProvider"),
        "approval_policy": result.get("approvalPolicy"),
        "approvals_reviewer": result.get("approvalsReviewer"),
        "sandbox_type": sandbox.get("type"),
        "sandbox_network_access": sandbox.get("networkAccess"),
        "active_permission_profile_id": (
            active_permission_profile or {}
        ).get("id"),
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_status_type": (thread.get("status") or {}).get("type"),
        "thread_turn_count": len(thread.get("turns") or []),
        "thread_source": thread.get("source"),
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    started_thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result", {})
    threads = result.get("data") or []
    listed_thread = None
    if started_thread_id is not None:
        listed_thread = next(
            (thread for thread in threads if thread.get("id") == started_thread_id),
            None,
        )
    if listed_thread is None and threads:
        listed_thread = threads[0]

    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_started_thread": listed_thread is not None
        and listed_thread.get("id") == started_thread_id,
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }

    if listed_thread is not None:
        normalized.update(
            {
                "listed_thread_ephemeral": listed_thread.get("ephemeral"),
                "listed_thread_model_provider": listed_thread.get("modelProvider"),
                "listed_thread_name": listed_thread.get("name"),
                "listed_thread_preview": listed_thread.get("preview"),
                "listed_thread_source": listed_thread.get("source"),
                "listed_thread_status_type": (listed_thread.get("status") or {}).get(
                    "type"
                ),
                "listed_thread_turn_count": len(listed_thread.get("turns") or []),
            }
        )
    return normalized


def summarize_path_observation(response: dict[str, Any], thread_id: str | None) -> dict[str, Any]:
    result = response.get("result", {})
    threads = result.get("data") or []
    listed_thread = None
    if thread_id is not None:
        listed_thread = next((thread for thread in threads if thread.get("id") == thread_id), None)
    path = (listed_thread or {}).get("path") if listed_thread is not None else None
    return {
        "thread_id": thread_id,
        "path_present": path is not None,
        "path_suffix": pathlib.Path(path).suffix if path else None,
    }


def summarize_chat_packages(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    summaries = []
    for package in packages:
        manifest_path = package / "manifest.json"
        timeline_path = package / "timeline.ndjson"
        journal_path = package / "journal.ndjson"
        index_path = package / "indexes/thread-metadata.json"

        timeline_lines = (
            timeline_path.read_text().splitlines() if timeline_path.exists() else []
        )
        journal_lines = journal_path.read_text().splitlines() if journal_path.exists() else []
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
        index = json.loads(index_path.read_text()) if index_path.exists() else None
        first_timeline_event = json.loads(timeline_lines[0]) if timeline_lines else None
        first_journal_entry = json.loads(journal_lines[0]) if journal_lines else None
        summaries.append(
            {
                "package": str(package),
                "files": sorted(
                    item.relative_to(package).as_posix()
                    for item in package.rglob("*")
                    if item.is_file()
                ),
                "manifest_exists": manifest_path.exists(),
                "timeline_exists": timeline_path.exists(),
                "journal_exists": journal_path.exists(),
                "index_exists": index_path.exists(),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "manifest_format": (manifest or {}).get("format"),
                "manifest_profiles": (manifest or {}).get("profiles"),
                "manifest_capabilities": (manifest or {}).get("capabilities"),
                "conversation_id": ((manifest or {}).get("conversation") or {}).get("id"),
                "index_thread_id": (index or {}).get("thread_id"),
                "index_rollout_path": (index or {}).get("rollout_path"),
                "first_timeline_event_type": (first_timeline_event or {}).get("type"),
                "first_timeline_event_source_ref": (first_timeline_event or {}).get(
                    "source_ref"
                ),
                "first_journal_entry_type": (first_journal_entry or {}).get(
                    "entry_type"
                ),
                "first_journal_source_schema": (
                    ((first_journal_entry or {}).get("source_transport") or {}).get("schema")
                ),
            }
        )
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "packages": summaries,
    }


def summarize_original_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    files = [
        path.relative_to(codex_home).as_posix()
        for path in codex_home.rglob("*")
        if path.is_file()
    ]
    rollout_files = [
        path for path in files if path.endswith(".jsonl") or path.endswith(".jsonl.zst")
    ]
    return {
        "codex_home": str(codex_home),
        "file_count": len(files),
        "rollout_files": sorted(rollout_files),
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

    client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    stderr = ""
    try:
        initialize = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "msp-chat-validation",
                    "title": "MSP Chat Validation",
                    "version": "0.0.0",
                },
                "capabilities": {
                    "experimentalApi": True,
                    "requestAttestation": False,
                    "optOutNotificationMethods": ["account/rateLimits/updated"],
                    "mcpServerOpenaiFormElicitation": False,
                },
            },
        }
        client.send(initialize)
        initialize_response = client.receive_until_response(1, timeout_seconds=30)
        client.send({"jsonrpc": "2.0", "method": "initialized"})
        thread_start = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/start",
            "params": {
                "cwd": str(workspace),
                "ephemeral": False,
                "historyMode": "legacy",
            },
        }
        client.send(thread_start)
        thread_start_response = client.receive_until_response(2, timeout_seconds=30)
        thread_list = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "thread/list",
            "params": {
                "limit": 10,
                "modelProviders": [],
                "archived": False,
            },
        }
        client.send(thread_list)
        thread_list_response = client.receive_until_response(3, timeout_seconds=30)
    finally:
        stderr = client.close()

    started_thread_id = (
        ((thread_start_response.get("result") or {}).get("thread") or {}).get("id")
    )
    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "thread_list_response": thread_list_response,
        "normalized_thread_start": normalize_thread_start_response(
            thread_start_response
        ),
        "normalized_thread_list": normalize_thread_list_response(
            thread_list_response,
            started_thread_id,
        ),
        "thread_list_path_observation": summarize_path_observation(
            thread_list_response,
            started_thread_id,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }

    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)

    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-thread-start-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_result = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=["model=\"gpt-5\""],
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
            'model="gpt-5"',
        ],
    )

    original_normalized = original_result["normalized_thread_start"]
    chat_normalized = chat_result["normalized_thread_start"]
    original_list_normalized = original_result["normalized_thread_list"]
    chat_list_normalized = chat_result["normalized_thread_list"]
    chat_summary = chat_result["chat_package_summary"]
    chat_package_pre_persist_ok = chat_summary["package_count"] == 0

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-thread-start-list-smoke",
        "binary_checks": binary_checks,
        "original_response_exit_ok": "result" in original_result["thread_start_response"],
        "chat_backend_response_exit_ok": "result" in chat_result["thread_start_response"],
        "original_thread_list_exit_ok": "result" in original_result["thread_list_response"],
        "chat_backend_thread_list_exit_ok": "result" in chat_result["thread_list_response"],
        "normalized_thread_start_equal": original_normalized == chat_normalized,
        "normalized_thread_list_equal": original_list_normalized == chat_list_normalized,
        "original_normalized_thread_start": original_normalized,
        "chat_backend_normalized_thread_start": chat_normalized,
        "original_normalized_thread_list": original_list_normalized,
        "chat_backend_normalized_thread_list": chat_list_normalized,
        "thread_list_path_observations": {
            "original": original_result["thread_list_path_observation"],
            "chat-backend": chat_result["thread_list_path_observation"],
        },
        "chat_package_pre_persist_ok": chat_package_pre_persist_ok,
        "chat_package_expectation": (
            "thread/start without a durable turn should not materialize a .chat package"
        ),
        "chat_package_summary": chat_summary,
        "not_yet_proven": [
            "package creation during durable turn execution",
            "turn/start model execution",
            "normal conversation parity",
            "command/tool execution parity",
            "resume/running-rejoin/fork/rollback/compaction parity",
            "list/search/archive parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal usage",
        ],
    }

    write_json(output_dir / "original/thread-start-response.json", original_result)
    write_json(output_dir / "chat-backend/thread-start-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Thread Start/List Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path.

## Scope

This smoke covers `initialize`, `thread/start`, and `thread/list`. It proves that the
adapted Codex app-server can select the explicit `.chat` thread store through
normal CLI config loading and create a `.chat` package while servicing the
standard app-server thread lifecycle API. It also proves the created `.chat`
thread is discoverable through the same app-server list path.

It does not run a model turn and is not full parity evidence. Thread path
observations are recorded, but path shape is not part of the normalized equality
check because the backend storage layout is intentionally different.

## Result

- original `thread/start` response succeeded: `{summary['original_response_exit_ok']}`
- `.chat` backend `thread/start` response succeeded: `{summary['chat_backend_response_exit_ok']}`
- original `thread/list` response succeeded: `{summary['original_thread_list_exit_ok']}`
- `.chat` backend `thread/list` response succeeded: `{summary['chat_backend_thread_list_exit_ok']}`
- normalized original vs `.chat` thread/start fields equal: `{summary['normalized_thread_start_equal']}`
- normalized original vs `.chat` thread/list fields equal: `{summary['normalized_thread_list_equal']}`
- pre-persist `.chat` package lifecycle matches expectation: `{summary['chat_package_pre_persist_ok']}`

## Thread List Path Observation

```json
{json.dumps(summary['thread_list_path_observations'], indent=2, sort_keys=True)}
```

## `.chat` Package Pre-Persist Observation

This smoke intentionally stops before a durable model turn. Matching the
original local backend means `thread/start` alone should not make an empty
thread appear in `thread/list` and should not materialize a `.chat` package.

```json
{json.dumps(chat_summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/thread-start-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/thread-start-response.json
```

## Not Yet Proven

This smoke does not prove package creation during durable turn execution,
resume, fork, rollback, compaction, search/archive parity, crash recovery,
complete data fidelity, or user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return (
        0
        if summary["chat_package_pre_persist_ok"]
        and summary["normalized_thread_start_equal"]
        and summary["normalized_thread_list_equal"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
