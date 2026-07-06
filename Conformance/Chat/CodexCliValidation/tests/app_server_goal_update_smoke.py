#!/usr/bin/env python3
"""Run app-server ThreadGoalUpdated parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers the persisted
`EventMsg::ThreadGoalUpdated` path, proving that the original backend and the
`.chat` backend keep the same durable goal update fact and replay the same goal
snapshot on resume.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    normalize_thread_list_response,
    read_json_lines,
    summarize_chat_packages,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_fork_smoke import (  # noqa: E402
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_start,
)


GOAL_OBJECTIVE = "keep the .chat goal parity thread visible"
GOAL_STATUS = "paused"
GOAL_TOKEN_BUDGET = 12345


def write_goal_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write("\n[features]\ngoals = true\n")


def send_goal_set(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    start_index = len(client.received)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/goal/set",
            "params": {
                "threadId": thread_id,
                "objective": GOAL_OBJECTIVE,
                "status": GOAL_STATUS,
                "tokenBudget": GOAL_TOKEN_BUDGET,
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications = [
        message for message in client.received[start_index:] if message.get("method")
    ]
    notification_errors: list[str] = []
    if "error" not in response and not any(
        message.get("method") == "thread/goal/updated" for message in notifications
    ):
        try:
            notifications.append(
                client.receive_until_method(
                    "thread/goal/updated",
                    timeout_seconds=30,
                )
            )
        except TimeoutError as exc:
            notification_errors.append(str(exc))
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def send_goal_get(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/goal/get",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_resume(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    start_index = len(client.received)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/resume",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications = [
        message for message in client.received[start_index:] if message.get("method")
    ]
    notification_errors: list[str] = []
    if "error" not in response and not any(
        message.get("method") == "thread/goal/updated" for message in notifications
    ):
        try:
            notifications.append(
                client.receive_until_method(
                    "thread/goal/updated",
                    timeout_seconds=30,
                )
            )
        except TimeoutError as exc:
            notification_errors.append(str(exc))
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def normalize_goal(goal: dict[str, Any] | None) -> dict[str, Any]:
    goal = goal or {}
    return {
        "thread_id_present": goal.get("threadId") is not None
        or goal.get("thread_id") is not None,
        "objective": goal.get("objective"),
        "status": goal.get("status"),
        "token_budget": goal.get("tokenBudget", goal.get("token_budget")),
        "tokens_used": goal.get("tokensUsed", goal.get("tokens_used")),
        "time_used_seconds": goal.get(
            "timeUsedSeconds",
            goal.get("time_used_seconds"),
        ),
        "created_at_present": goal.get("createdAt", goal.get("created_at")) is not None,
        "updated_at_present": goal.get("updatedAt", goal.get("updated_at")) is not None,
    }


def normalize_goal_response(response: dict[str, Any]) -> dict[str, Any]:
    return {
        "has_error": "error" in response,
        "goal": normalize_goal(((response.get("result") or {}).get("goal") or {})),
    }


def normalize_goal_get_response(response: dict[str, Any]) -> dict[str, Any]:
    return normalize_goal_response(response)


def normalize_goal_notifications(result: dict[str, Any]) -> dict[str, Any]:
    notifications = result.get("notifications") or []
    goal_updates = [
        (message.get("params") or {})
        for message in notifications
        if message.get("method") == "thread/goal/updated"
    ]
    normalized_updates = [
        {
            "thread_id_present": update.get("threadId") is not None,
            "turn_id": update.get("turnId"),
            "goal": normalize_goal(update.get("goal") or {}),
        }
        for update in goal_updates
    ]
    return {
        "notification_methods": [message.get("method") for message in notifications],
        "goal_update_count": len(goal_updates),
        "goal_updates": normalized_updates,
        "notification_errors": result.get("notification_errors") or [],
    }


def normalize_thread_summary(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_rollout_goal_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    event_msg_types: list[str] = []
    goal_updates: list[dict[str, Any]] = []
    for item in items:
        if item.get("type") != "event_msg":
            continue
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        event_msg_types.append(nested_type)
        if nested_type == "thread_goal_updated":
            goal_updates.append(
                {
                    "turn_id": payload.get("turn_id"),
                    "goal": normalize_goal(payload.get("goal") or {}),
                }
            )
    return {
        "line_count": len(items),
        "event_msg_types": event_msg_types,
        "thread_goal_updated_count": len(goal_updates),
        "thread_goal_updates": goal_updates,
        "contains_expected_goal_update": any(
            update["goal"].get("objective") == GOAL_OBJECTIVE
            and update["goal"].get("status") == GOAL_STATUS
            and update["goal"].get("token_budget") == GOAL_TOKEN_BUDGET
            for update in goal_updates
        ),
    }


def summarize_original_goal_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    rollout_paths = sorted(codex_home.rglob("*.jsonl"))
    all_items: list[dict[str, Any]] = []
    rollouts = []
    for path in rollout_paths:
        lines = read_json_lines(path)
        all_items.extend(lines)
        rollouts.append(
            {
                "path": path.relative_to(codex_home).as_posix(),
                "line_count": len(lines),
            }
        )
    summary = summarize_rollout_goal_sources(all_items)
    summary.update(
        {
            "codex_home": str(codex_home),
            "rollouts": rollouts,
        }
    )
    return summary


def summarize_chat_goal_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_rollout_goal_sources([]),
            "timeline": {},
        }
    package = packages[0]
    journal_lines = read_json_lines(package / "journal.ndjson")
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_lines = read_json_lines(package / "timeline.ndjson")
    timeline_source_response_types = [
        ((line.get("body") or {}).get("source_response_type"))
        for line in timeline_lines
    ]
    timeline_summary = {
        "line_count": len(timeline_lines),
        "event_types": [line.get("type") for line in timeline_lines],
        "source_response_types": timeline_source_response_types,
        "thread_goal_status_event_count": sum(
            1 for value in timeline_source_response_types if value == "thread_goal_updated"
        ),
    }
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "package": str(package),
        "journal": summarize_rollout_goal_sources(source_items),
        "timeline": timeline_summary,
    }


def run_first_process(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: MockResponsesServer,
) -> dict[str, Any]:
    write_goal_mock_config(codex_home, mock_server.url)
    client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    stderr = ""
    try:
        initialize_response = send_initialize(client, 1)
        started_thread_id, thread_start_response = send_thread_start(client, 2, workspace)
        goal_set_result = send_goal_set(client, 3, started_thread_id)
        goal_get_response = send_goal_get(client, 4, started_thread_id)
        thread_read_response = send_thread_read(client, 5, started_thread_id)
        thread_list_response = send_thread_list(client, 6)
    finally:
        stderr = client.close()
    return {
        "command": client.command,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "started_thread_id": started_thread_id,
        "goal_set_result": goal_set_result,
        "goal_get_response": goal_get_response,
        "thread_read_response": thread_read_response,
        "thread_list_response": thread_list_response,
        "normalized_goal_set": normalize_goal_response(goal_set_result["response"]),
        "normalized_goal_set_notifications": normalize_goal_notifications(goal_set_result),
        "normalized_goal_get": normalize_goal_get_response(goal_get_response),
        "normalized_thread_read": normalize_thread_summary(thread_read_response),
        "normalized_thread_list": normalize_thread_list_response(
            thread_list_response,
            started_thread_id,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def run_resume_process(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    thread_id: str | None,
) -> dict[str, Any]:
    client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    stderr = ""
    try:
        initialize_response = send_initialize(client, 11)
        resume_result = send_thread_resume(client, 12, thread_id)
        goal_get_response = send_goal_get(client, 13, thread_id)
        thread_read_response = send_thread_read(client, 14, thread_id)
    finally:
        stderr = client.close()
    return {
        "command": client.command,
        "initialize_response": initialize_response,
        "resume_result": resume_result,
        "goal_get_response": goal_get_response,
        "thread_read_response": thread_read_response,
        "normalized_resume": normalize_thread_summary(resume_result["response"]),
        "normalized_resume_goal_notifications": normalize_goal_notifications(resume_result),
        "normalized_goal_get": normalize_goal_get_response(goal_get_response),
        "normalized_thread_read": normalize_thread_summary(thread_read_response),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
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

    with MockResponsesServer("unused goal smoke model response") as mock_server:
        first = run_first_process(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        resume = run_resume_process(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            first["started_thread_id"],
        )

    result = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "first_process": first,
        "resume_process": resume,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_goal_storage"] = summarize_chat_goal_package(chat_root)
    else:
        result["original_goal_storage"] = summarize_original_goal_storage(codex_home)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-goal-update-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_first = original_result["first_process"]
    chat_first = chat_result["first_process"]
    original_resume = original_result["resume_process"]
    chat_resume = chat_result["resume_process"]
    original_goal_storage = original_result["original_goal_storage"]
    chat_goal_storage = chat_result["chat_goal_storage"]
    chat_journal = chat_goal_storage["journal"]
    chat_timeline = chat_goal_storage["timeline"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-goal-update-smoke",
        "binary_checks": binary_checks,
        "original_goal_set_exit_ok": "result"
        in original_first["goal_set_result"]["response"],
        "chat_backend_goal_set_exit_ok": "result"
        in chat_first["goal_set_result"]["response"],
        "original_goal_get_exit_ok": "result" in original_first["goal_get_response"],
        "chat_backend_goal_get_exit_ok": "result" in chat_first["goal_get_response"],
        "original_resume_exit_ok": "result"
        in original_resume["resume_result"]["response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_resume["resume_result"]["response"],
        "normalized_goal_set_equal": original_first["normalized_goal_set"]
        == chat_first["normalized_goal_set"],
        "normalized_goal_set_notifications_equal": original_first[
            "normalized_goal_set_notifications"
        ]
        == chat_first["normalized_goal_set_notifications"],
        "normalized_goal_get_equal": original_first["normalized_goal_get"]
        == chat_first["normalized_goal_get"],
        "normalized_thread_read_equal": original_first["normalized_thread_read"]
        == chat_first["normalized_thread_read"],
        "normalized_thread_list_equal": original_first["normalized_thread_list"]
        == chat_first["normalized_thread_list"],
        "normalized_resume_equal": original_resume["normalized_resume"]
        == chat_resume["normalized_resume"],
        "normalized_resume_goal_notifications_equal": original_resume[
            "normalized_resume_goal_notifications"
        ]
        == chat_resume["normalized_resume_goal_notifications"],
        "normalized_resume_goal_get_equal": original_resume["normalized_goal_get"]
        == chat_resume["normalized_goal_get"],
        "normalized_resume_thread_read_equal": original_resume["normalized_thread_read"]
        == chat_resume["normalized_thread_read"],
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
            == 0
        ),
        "original_has_thread_goal_updated": original_goal_storage[
            "contains_expected_goal_update"
        ],
        "chat_journal_has_thread_goal_updated": chat_journal[
            "contains_expected_goal_update"
        ],
        "thread_goal_updated_counts_equal": original_goal_storage[
            "thread_goal_updated_count"
        ]
        == chat_journal["thread_goal_updated_count"],
        "thread_goal_updates_equal": original_goal_storage["thread_goal_updates"]
        == chat_journal["thread_goal_updates"],
        "line_counts_equal": original_goal_storage["line_count"]
        == chat_journal["line_count"],
        "chat_timeline_has_goal_status_mapping": chat_timeline.get(
            "thread_goal_status_event_count",
            0,
        )
        >= 1,
        "original_normalized_goal_set": original_first["normalized_goal_set"],
        "chat_backend_normalized_goal_set": chat_first["normalized_goal_set"],
        "original_normalized_goal_set_notifications": original_first[
            "normalized_goal_set_notifications"
        ],
        "chat_backend_normalized_goal_set_notifications": chat_first[
            "normalized_goal_set_notifications"
        ],
        "original_normalized_resume_goal_notifications": original_resume[
            "normalized_resume_goal_notifications"
        ],
        "chat_backend_normalized_resume_goal_notifications": chat_resume[
            "normalized_resume_goal_notifications"
        ],
        "original_goal_storage": original_goal_storage,
        "chat_goal_storage": chat_goal_storage,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "review mode events",
            "subagent activity",
            "tool-search and broader web-search dedicated parity",
            "runtime status variants beyond goal snapshot",
            "complete source transport inventory",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/goal-update-response.json", original_result)
    write_json(output_dir / "chat-backend/goal-update-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Goal Update Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and covers
`thread/goal/set`, `thread/goal/get`, `thread/list`, `thread/read`, process
restart, and `thread/resume` goal snapshot replay.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and persisted item inventory were read.

## Scope

This smoke covers a source-backed open gap from the persisted item inventory:
`EventMsg::ThreadGoalUpdated`. It proves that the original backend and `.chat`
backend both persist the same goal update for this app-server path, and that a
cold `thread/resume` replays the same goal snapshot notification.

It does not prove review mode events, subagent activity, tool-search/web-search
dedicated parity, every runtime-status variant, full source-transport inventory,
or final user-indistinguishability.

## Result

- original `thread/goal/set` response succeeded: `{summary['original_goal_set_exit_ok']}`
- `.chat` backend `thread/goal/set` response succeeded: `{summary['chat_backend_goal_set_exit_ok']}`
- original `thread/goal/get` response succeeded: `{summary['original_goal_get_exit_ok']}`
- `.chat` backend `thread/goal/get` response succeeded: `{summary['chat_backend_goal_get_exit_ok']}`
- original `thread/resume` response succeeded: `{summary['original_resume_exit_ok']}`
- `.chat` backend `thread/resume` response succeeded: `{summary['chat_backend_resume_exit_ok']}`
- normalized original vs `.chat` goal set fields equal: `{summary['normalized_goal_set_equal']}`
- normalized original vs `.chat` goal set notifications equal: `{summary['normalized_goal_set_notifications_equal']}`
- normalized original vs `.chat` goal get fields equal: `{summary['normalized_goal_get_equal']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- normalized original vs `.chat` resume fields equal: `{summary['normalized_resume_equal']}`
- normalized original vs `.chat` resume goal notifications equal: `{summary['normalized_resume_goal_notifications_equal']}`
- normalized original vs `.chat` resume goal get fields equal: `{summary['normalized_resume_goal_get_equal']}`
- normalized original vs `.chat` resume `thread/read` fields equal: `{summary['normalized_resume_thread_read_equal']}`
- mock Responses request counts equal and zero: `{summary['mock_response_request_counts_equal']}`
- original rollout has expected `ThreadGoalUpdated`: `{summary['original_has_thread_goal_updated']}`
- `.chat` journal has expected `ThreadGoalUpdated`: `{summary['chat_journal_has_thread_goal_updated']}`
- `ThreadGoalUpdated` counts equal: `{summary['thread_goal_updated_counts_equal']}`
- `ThreadGoalUpdated` normalized payloads equal: `{summary['thread_goal_updates_equal']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- `.chat` timeline has neutral goal status mapping: `{summary['chat_timeline_has_goal_status_mapping']}`

## Normalized Goal Set

```json
{json.dumps({'original': summary['original_normalized_goal_set'], 'chat-backend': summary['chat_backend_normalized_goal_set']}, indent=2, sort_keys=True)}
```

## Normalized Goal Set Notifications

```json
{json.dumps({'original': summary['original_normalized_goal_set_notifications'], 'chat-backend': summary['chat_backend_normalized_goal_set_notifications']}, indent=2, sort_keys=True)}
```

## Normalized Resume Goal Notifications

```json
{json.dumps({'original': summary['original_normalized_resume_goal_notifications'], 'chat-backend': summary['chat_backend_normalized_resume_goal_notifications']}, indent=2, sort_keys=True)}
```

## Original Goal Storage

```json
{json.dumps(original_goal_storage, indent=2, sort_keys=True)}
```

## `.chat` Goal Storage

```json
{json.dumps(chat_goal_storage, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/goal-update-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/goal-update-response.json
```
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return (
        0
        if summary["original_goal_set_exit_ok"]
        and summary["chat_backend_goal_set_exit_ok"]
        and summary["original_goal_get_exit_ok"]
        and summary["chat_backend_goal_get_exit_ok"]
        and summary["original_resume_exit_ok"]
        and summary["chat_backend_resume_exit_ok"]
        and summary["normalized_goal_set_equal"]
        and summary["normalized_goal_set_notifications_equal"]
        and summary["normalized_goal_get_equal"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["normalized_resume_equal"]
        and summary["normalized_resume_goal_notifications_equal"]
        and summary["normalized_resume_goal_get_equal"]
        and summary["normalized_resume_thread_read_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["original_has_thread_goal_updated"]
        and summary["chat_journal_has_thread_goal_updated"]
        and summary["thread_goal_updated_counts_equal"]
        and summary["thread_goal_updates_equal"]
        and summary["line_counts_equal"]
        and summary["chat_timeline_has_goal_status_mapping"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
