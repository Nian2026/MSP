#!/usr/bin/env python3
"""Run an instrumented direct R06 pending-unload app-server smoke.

This smoke is intentionally not source-preserving evidence. It expects
`CODEX_CHAT_VALIDATION_SOURCE_ROOT` to point at temporary original and `.chat`
backend source copies that have both been instrumented in the same way:

- shorten `THREAD_UNLOADING_DELAY`;
- hold briefly after inserting the thread id into `pending_thread_unloads`.

That creates a stable window where `thread/resume` can observe the "thread is
closing" state. The result is direct behavioral evidence for the R06 rejection
path under equal instrumentation, while ordinary unmodified-binary evidence
remains open.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import re
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    USER_TEXT,
    JsonRpcClient,
    MockResponsesServer,
    run_command,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_read,
    send_thread_resume,
    send_thread_start,
    send_thread_unsubscribe,
    send_turn_start,
)


CLOSING_RE = re.compile(
    r"thread [0-9a-fA-F-]+ is closing; retry thread/resume after the thread is closed"
)


def ensure_app_server_binary(codex_rs: pathlib.Path, build_if_missing: bool) -> dict[str, Any]:
    binary = codex_rs / "target/debug/codex-app-server"
    if binary.exists():
        return {
            "built": False,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
        }

    if not build_if_missing:
        raise RuntimeError(
            f"missing {binary}; run `cargo build -p codex-app-server --bin codex-app-server` first"
        )

    result = run_command(
        ["cargo", "build", "-p", "codex-app-server", "--bin", "codex-app-server"],
        codex_rs,
    )
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


def normalize_pending_resume_response(response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error") or {}
    message = error.get("message")
    normalized_message = CLOSING_RE.sub(
        "thread <id> is closing; retry thread/resume after the thread is closed",
        message or "",
    )
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message": normalized_message,
        "is_pending_unload_error": bool(message and CLOSING_RE.fullmatch(message)),
    }


def receive_thread_closed(client: JsonRpcClient, timeout_seconds: float = 5) -> dict[str, Any] | None:
    try:
        return client.receive_until_method("thread/closed", timeout_seconds=timeout_seconds)
    except TimeoutError:
        return None


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def chat_package_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 5
        and package.get("journal_line_count", 0) >= 5
        and "runtime_context_snapshot" in event_types
        and "message" in event_types
    )


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    pending_window_sleep_seconds: float,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex-app-server"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            app_server_subcommand=False,
        )
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )
            turn_start_response = send_turn_start(client, 3, started_thread_id)
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )
            unsubscribe_response = send_thread_unsubscribe(
                client, 4, started_thread_id
            )
            time.sleep(pending_window_sleep_seconds)
            pending_resume_response = send_thread_resume(
                client, 5, started_thread_id, workspace
            )
            thread_closed_notification = receive_thread_closed(client)
            final_thread_read_response = send_thread_read(client, 6, started_thread_id)
        finally:
            stderr = client.close()

        result = {
            "tree": tree_name,
            "command": client.command,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "mock_server_summary": mock_server.summary(),
            "initialize_response": initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": turn_start_response,
            "turn_started_notification": turn_started_notification,
            "turn_completed_notification": turn_completed_notification,
            "unsubscribe_response": unsubscribe_response,
            "pending_window_sleep_seconds": pending_window_sleep_seconds,
            "pending_resume_response": pending_resume_response,
            "thread_closed_notification": thread_closed_notification,
            "final_thread_read_response": final_thread_read_response,
            "normalized_pending_resume": normalize_pending_resume_response(
                pending_resume_response
            ),
            "thread_closed_seen": thread_closed_notification is not None,
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
        / (
            "app-server-pending-unload-instrumented-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument("--pending-window-sleep-seconds", type=float, default=1.25)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    binary_checks = {
        "original": ensure_app_server_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_app_server_binary(
            CHAT_BACKEND_CODEX_RS, args.build_if_missing
        ),
    }

    run_root = output_dir / "run"
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
        pending_window_sleep_seconds=args.pending_window_sleep_seconds,
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        pending_window_sleep_seconds=args.pending_window_sleep_seconds,
    )

    original_pending = original_result["normalized_pending_resume"]
    chat_pending = chat_result["normalized_pending_resume"]
    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_lines = line_count(original_storage, "rollouts")
    chat_packages = chat_package.get("packages") or []
    chat_journal_lines = (
        chat_packages[0].get("journal_line_count") if len(chat_packages) == 1 else None
    )
    chat_timeline_lines = (
        chat_packages[0].get("timeline_line_count") if len(chat_packages) == 1 else None
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-pending-unload-instrumented-smoke",
        "instrumented": True,
        "instrumentation": {
            "thread_unloading_delay": "Duration::from_secs(1)",
            "pending_unload_hold": "tokio::time::sleep(Duration::from_secs(2)).await after pending_thread_unloads.insert",
            "source_preserving_binary_evidence": False,
        },
        "binary_checks": binary_checks,
        "pending_window_sleep_seconds": args.pending_window_sleep_seconds,
        "original_pending_resume_is_closing_error": original_pending[
            "is_pending_unload_error"
        ],
        "chat_backend_pending_resume_is_closing_error": chat_pending[
            "is_pending_unload_error"
        ],
        "normalized_pending_resume_equal": original_pending == chat_pending,
        "original_thread_closed_seen": original_result["thread_closed_seen"],
        "chat_backend_thread_closed_seen": chat_result["thread_closed_seen"],
        "thread_closed_seen_equal": original_result["thread_closed_seen"]
        == chat_result["thread_closed_seen"],
        "chat_package_ok": chat_package_ok(chat_package),
        "journal_line_count_matches_original": (
            original_lines is not None and original_lines == chat_journal_lines
        ),
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_pending_resume": original_pending,
        "chat_backend_normalized_pending_resume": chat_pending,
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "ordinary_binary_r06_still_open": True,
        "not_yet_proven": [
            "R06 direct pending-unload race on unmodified source-preserving binaries",
            "fork/rollback/compaction parity",
            "command/tool execution parity",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/pending-unload-response.json", original_result)
    write_json(output_dir / "chat-backend/pending-unload-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Pending Unload Instrumented Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It is direct R06 behavior evidence under equal temporary instrumentation, not
ordinary source-preserving binary evidence.

## Instrumentation

- `THREAD_UNLOADING_DELAY` was shortened to `Duration::from_secs(1)`.
- both temporary source copies sleep for 2 seconds immediately after
  `pending_thread_unloads.insert(conversation_id)`.
- preserved source snapshots under `source-snapshots/` were not modified.

## Result

- original `thread/resume` during pending unload returned closing error:
  `{summary['original_pending_resume_is_closing_error']}`
- `.chat` backend `thread/resume` during pending unload returned closing error:
  `{summary['chat_backend_pending_resume_is_closing_error']}`
- normalized pending-resume errors equal:
  `{summary['normalized_pending_resume_equal']}`
- original `thread/closed` notification observed:
  `{summary['original_thread_closed_seen']}`
- `.chat` backend `thread/closed` notification observed:
  `{summary['chat_backend_thread_closed_seen']}`
- `.chat` package remained valid:
  `{summary['chat_package_ok']}`
- `.chat` journal line count matched original rollout:
  `{summary['journal_line_count_matches_original']}`

## Normalized Pending Resume

```json
{json.dumps({'original': original_pending, 'chat-backend': chat_pending}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/pending-unload-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/pending-unload-response.json
```

## Boundary

This closes only the equally instrumented direct R06 rejection path. Ordinary
unmodified-binary R06 evidence remains open until a smoke observes the same
condition without temporary source instrumentation, or until a neutral upstream
test hook/runtime config exists.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_pending_resume_is_closing_error"],
            summary["chat_backend_pending_resume_is_closing_error"],
            summary["normalized_pending_resume_equal"],
            summary["thread_closed_seen_equal"],
            summary["chat_package_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
