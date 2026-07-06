# App-Server Running Rejoin Smoke - 2026-07-03T11:30:32.145632Z

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local delayed
mock Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server running-resume and listener code was also read.

## Scope

This smoke covers one completed seed turn, a second delayed `turn/start`, the
`turn/started` notification, `thread/resume` while that turn is still running,
the eventual `turn/completed`, and final `thread/read` / `thread/list`.

It proves R03 running rejoin, R04 stale-path rejection, and an R05
override-mismatch warning slice for this harness. It does not prove fork,
rollback, compaction, command/tool execution, archive/search/delete, crash
recovery, complete data fidelity, or final user-indistinguishability.

## Result

- original running `thread/resume` response succeeded: `True`
- `.chat` backend running `thread/resume` response succeeded: `True`
- normalized original vs `.chat` running `thread/resume` fields equal: `True`
- original running resume saw the in-progress turn: `True`
- `.chat` backend running resume saw the in-progress turn: `True`
- original stale-path running `thread/resume` was rejected: `True`
- `.chat` backend stale-path running `thread/resume` was rejected: `True`
- normalized original vs `.chat` stale-path error fields equal: `True`
- original override-mismatch warning was present in stderr: `True`
- `.chat` backend override-mismatch warning was present in stderr: `True`
- normalized original vs `.chat` override-mismatch warning fields equal: `True`
- normalized original vs `.chat` final `thread/read` fields equal: `True`
- normalized original vs `.chat` final `thread/list` fields equal: `True`
- mock Responses request counts equal: `True`
- second model request included seed user/assistant context and running user text: `True`
- durable `.chat` package remained readable after running rejoin: `True`
- `.chat` journal line count matched original rollout line count: `True`

## Normalized Running Resume

```json
{
  "chat-backend": {
    "contains_running_assistant_text": false,
    "contains_running_user_text": false,
    "contains_seed_assistant_text": true,
    "contains_seed_user_text": true,
    "has_error": false,
    "initial_turns_page_backwards_cursor_present": true,
    "initial_turns_page_contains_running_turn": true,
    "initial_turns_page_count": 2,
    "initial_turns_page_items_views": [
      "summary",
      "summary"
    ],
    "initial_turns_page_next_cursor_present": false,
    "initial_turns_page_present": true,
    "initial_turns_page_statuses": [
      "inProgress",
      "completed"
    ],
    "item_count_by_turn": [
      2,
      0
    ],
    "item_types_by_turn": [
      [
        "userMessage",
        "agentMessage"
      ],
      []
    ],
    "model": "mock-model",
    "model_provider": "mock_provider",
    "path_present": true,
    "preview": "Seed history before running rejoin.",
    "running_turn_item_count": 0,
    "running_turn_items_view": "summary",
    "running_turn_status": "inProgress",
    "thread_ephemeral": false,
    "thread_history_mode": "legacy",
    "thread_id_matches": true,
    "thread_source": "vscode",
    "thread_status_type": "active",
    "turn_count": 2,
    "turn_statuses": [
      "completed",
      "inProgress"
    ]
  },
  "original": {
    "contains_running_assistant_text": false,
    "contains_running_user_text": false,
    "contains_seed_assistant_text": true,
    "contains_seed_user_text": true,
    "has_error": false,
    "initial_turns_page_backwards_cursor_present": true,
    "initial_turns_page_contains_running_turn": true,
    "initial_turns_page_count": 2,
    "initial_turns_page_items_views": [
      "summary",
      "summary"
    ],
    "initial_turns_page_next_cursor_present": false,
    "initial_turns_page_present": true,
    "initial_turns_page_statuses": [
      "inProgress",
      "completed"
    ],
    "item_count_by_turn": [
      2,
      0
    ],
    "item_types_by_turn": [
      [
        "userMessage",
        "agentMessage"
      ],
      []
    ],
    "model": "mock-model",
    "model_provider": "mock_provider",
    "path_present": true,
    "preview": "Seed history before running rejoin.",
    "running_turn_item_count": 0,
    "running_turn_items_view": "summary",
    "running_turn_status": "inProgress",
    "thread_ephemeral": false,
    "thread_history_mode": "legacy",
    "thread_id_matches": true,
    "thread_source": "vscode",
    "thread_status_type": "active",
    "turn_count": 2,
    "turn_statuses": [
      "completed",
      "inProgress"
    ]
  }
}
```

## Normalized Stale Path Error

```json
{
  "chat-backend": {
    "code": -32600,
    "has_error": true,
    "message_contains_cannot_resume": true,
    "message_contains_running_thread": true,
    "message_contains_stale_path": true
  },
  "original": {
    "code": -32600,
    "has_error": true,
    "message_contains_cannot_resume": true,
    "message_contains_running_thread": true,
    "message_contains_stale_path": true
  }
}
```

## Normalized Override Warning

```json
{
  "chat-backend": {
    "contains_active_workspace": true,
    "contains_cwd_mismatch": true,
    "contains_model_mismatch": true,
    "has_override_warning": true
  },
  "original": {
    "contains_active_workspace": true,
    "contains_cwd_mismatch": true,
    "contains_model_mismatch": true,
    "has_override_warning": true
  }
}
```

## Final Thread Read

```json
{
  "chat-backend": {
    "contains_running_assistant_text": true,
    "contains_running_user_text": true,
    "contains_seed_assistant_text": true,
    "contains_seed_user_text": true,
    "has_error": false,
    "item_count_by_turn": [
      2,
      2
    ],
    "item_types_by_turn": [
      [
        "userMessage",
        "agentMessage"
      ],
      [
        "userMessage",
        "agentMessage"
      ]
    ],
    "model": null,
    "model_provider": "mock_provider",
    "path_present": true,
    "preview": "Seed history before running rejoin.",
    "thread_ephemeral": false,
    "thread_history_mode": "legacy",
    "thread_id_matches": true,
    "thread_source": "vscode",
    "thread_status_type": "idle",
    "turn_count": 2,
    "turn_statuses": [
      "completed",
      "completed"
    ]
  },
  "original": {
    "contains_running_assistant_text": true,
    "contains_running_user_text": true,
    "contains_seed_assistant_text": true,
    "contains_seed_user_text": true,
    "has_error": false,
    "item_count_by_turn": [
      2,
      2
    ],
    "item_types_by_turn": [
      [
        "userMessage",
        "agentMessage"
      ],
      [
        "userMessage",
        "agentMessage"
      ]
    ],
    "model": null,
    "model_provider": "mock_provider",
    "path_present": true,
    "preview": "Seed history before running rejoin.",
    "thread_ephemeral": false,
    "thread_history_mode": "legacy",
    "thread_id_matches": true,
    "thread_source": "vscode",
    "thread_status_type": "idle",
    "turn_count": 2,
    "turn_statuses": [
      "completed",
      "completed"
    ]
  }
}
```

## `.chat` Package Observation

```json
{
  "chat_root": "<codex-chat-validation-run-root>/app-server-running-rejoin-smoke-2026-07-03-phase-close/chat-backend/chat-store",
  "package_count": 1,
  "packages": [
    {
      "conversation_id": "019f27be-8c44-7a23-b1f6-e9ed8081fc3d",
      "files": [
        "indexes/thread-metadata.json",
        "journal.ndjson",
        "manifest.json",
        "projections/audit.ndjson",
        "projections/chat-read.ndjson",
        "projections/model-context.ndjson",
        "timeline.ndjson"
      ],
      "index_exists": true,
      "index_rollout_path": "<codex-chat-validation-run-root>/app-server-running-rejoin-smoke-2026-07-03-phase-close/chat-backend/chat-store/019f27be-8c44-7a23-b1f6-e9ed8081fc3d.chat",
      "index_thread_id": "019f27be-8c44-7a23-b1f6-e9ed8081fc3d",
      "journal_exists": true,
      "journal_line_count": 20,
      "journal_source_schemas": [
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null
      ],
      "manifest_capabilities": [
        "read_core",
        "write_core",
        "generate_projection",
        "replay_journal",
        "preserve_unknown_events"
      ],
      "manifest_exists": true,
      "manifest_format": "msp.chat",
      "manifest_profiles": [
        "core-timeline",
        "agent-timeline",
        "projection-cache",
        "resumable-context",
        "runtime-journal"
      ],
      "package": "<codex-chat-validation-run-root>/app-server-running-rejoin-smoke-2026-07-03-phase-close/chat-backend/chat-store/019f27be-8c44-7a23-b1f6-e9ed8081fc3d.chat",
      "timeline_event_types": [
        "runtime_context_snapshot",
        "status_changed",
        "message",
        "message",
        "state_snapshot",
        "runtime_context_snapshot",
        "message",
        "status_changed",
        "status_changed",
        "message",
        "status_changed",
        "status_changed",
        "status_changed",
        "runtime_context_snapshot",
        "message",
        "status_changed",
        "status_changed",
        "message",
        "status_changed",
        "status_changed"
      ],
      "timeline_exists": true,
      "timeline_line_count": 20
    }
  ]
}
```

## Evidence Files

```text
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json
```

## Not Yet Proven

This smoke does not prove fork, rollback, compaction, command/tool execution,
archive/search/delete, crash recovery, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
