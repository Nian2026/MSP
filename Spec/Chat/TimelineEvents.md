# `.chat` Timeline Events

Status: draft standard candidate.

This document defines the canonical event envelope, event durability classes,
timeline ordering invariants, core events, agent events, control events, and
unknown-event behavior for `.chat`.

## 1. Canonical Timeline

The canonical timeline records portable conversation facts in real occurrence
order. It must not collapse events into separate type buckets such as messages,
tool calls, command outputs, and final assistant messages.

A valid UI timeline can be derived from the canonical timeline without reading a
runtime journal. A heavy runtime may read additional journal data, but the core
conversation facts needed for display must remain in the timeline.

## 2. Event Envelope

Every timeline record is a JSON object with an event envelope and payload.

Required fields:

```json
{
  "id": "evt_...",
  "type": "message",
  "seq": 1,
  "created_at": "2026-06-30T00:00:00Z",
  "durability": "durable_replay",
  "payload": {}
}
```

Recommended fields:

- `commit_seq` or `log_offset`: durable package-level write order.
- `turn_id`: conversation turn or run span.
- `actor`: user, assistant, system, runtime, command, or tool actor.
- `parent_id`: event this event responds to or modifies.
- `correlation_id`: cross-event relation id.
- `call_id`: tool or command call/result pairing id.
- `source_transport`: reference to raw provider/tool/runtime transport data.
- `extensions`: namespaced implementation extension data.

Event ids must be stable. Rewriting, importing, or repairing a package must not
reuse an event id for a different fact.

## 3. Durability Classes

Each event must declare one durability class:

- `durable_replay`: durable event needed to display, continue, audit, or replay.
- `live_stream`: fine-grained live data such as stdout chunks, stderr chunks, or
  streaming assistant deltas.
- `projection_only`: derived data that must not be treated as canonical history.
- `runtime_journal`: heavy-runtime recovery detail that lightweight readers can
  preserve without understanding.

Minimal packages may omit most `live_stream` events if the durable replay events
preserve the committed user-visible and audit-relevant result.

## 4. Ordering Invariants

The timeline must satisfy:

- `seq` is unique and strictly increasing within `timeline.ndjson`.
- `created_at` records event time, but `seq` is the display-order authority.
- `commit_seq` or `log_offset`, when present, must not contradict `seq`.
- events from the same call must be pairable by `call_id` or `correlation_id`;
- output events must not appear before their call event;
- completion events must not appear before required started/call events;
- rollback and compaction must be represented by additional events, not by
  deleting old canonical events.

## 5. Core Events

The minimal `core-timeline` profile recognizes these events:

- `message`
- `status_changed`
- `error`
- `artifact_ref`

### `message`

Represents a committed user, assistant, system, or runtime-facing message.

Payload fields:

- `role`: `user`, `assistant`, `system`, `runtime`, or extension role.
- `content`: text or structured content blocks.
- `phase`: optional `intermediate`, `final`, `instruction`, or extension phase.
- `content_refs`: artifact/blob references for large content.
- `redacted`, `truncated`, `lossy`: loss flags when applicable.

Assistant intermediate output and final output are both first-class timeline
facts. A reader must not assume there is exactly one assistant message per turn.

### `status_changed`

Represents visible status change for a turn, call, command, projection, or
conversation lifecycle.

Payload fields:

- `subject_id`;
- `status`;
- `reason`;
- `visible`;
- `metadata`.

### `error`

Represents an error that affected the conversation, timeline, projection,
command, tool, artifact, or runtime.

Payload fields:

- `subject_id`;
- `code`;
- `message`;
- `recoverable`;
- `details_ref`;
- `redacted`.

### `artifact_ref`

References an artifact or blob from the canonical timeline.

Payload fields:

- `artifact_id` or `blob_id`;
- `source_event_id`;
- `kind`;
- `media_type`;
- `display_name`;
- `range`;
- `status`: `available`, `missing`, `redacted`, or `external_only`.

## 6. Agent Timeline Events

The `agent-timeline` profile adds:

- `message_delta`
- `message_commit`
- `message_aborted`
- `message_superseded`
- `turn_started`
- `turn_completed`
- `turn_aborted`
- `tool_call`
- `tool_output`

### Message Deltas

`message_delta` records live or incremental message output. It must eventually be
associated with exactly one of:

- `message_commit`;
- `message_aborted`;
- `message_superseded`.

A lightweight reader must be able to distinguish committed text from canceled or
superseded live output.

### Turn Lifecycle

`turn_started`, `turn_completed`, and `turn_aborted` describe a turn or run span.
They do not replace the interleaved events inside the turn.

### Tool Calls

`tool_call` and `tool_output` represent structured tool activity that is not a
shell-like command span.

Payload fields:

- `call_id`;
- `tool_name`;
- `input`;
- `input_ref`;
- `status`;
- `output`;
- `output_ref`;
- `duration_ms`;
- `error`;
- `artifact_refs`;
- `source_transport`.

Tool events may be mapped from external transport systems, but standard timeline
semantics must remain product-neutral.

## 7. Command Events

The `command-timeline` profile adds:

- `command_call`
- `command_input`
- `command_output`
- `command_stage_started`
- `command_stage_output`
- `command_stage_completed`
- `command_complete`
- `command_error`
- `policy_request`
- `policy_decision`

Command event rules are defined in `CommandTimeline.md`.

## 8. Context And Control Events

The `resumable-context` and `runtime-journal` profiles add:

- `turn_context_snapshot`
- `runtime_context_snapshot`
- `permission_snapshot`
- `environment_snapshot`
- `model_context_projection`
- `projection_created`
- `projection_invalidated`
- `durable_compaction_checkpoint`
- `live_compaction_progress`
- `context_window_lineage`
- `state_snapshot`
- `state_patch`
- `conversation_fork`
- `timeline_rollback`
- `resume_capability_assessment`
- `resume_degraded`
- `conversation_lifecycle`
- `active_turn_overlay`
- `live_attachment_snapshot`

Control events that affect portable display, audit, migration, or continuation
must appear in the timeline. Runtime-private recovery details may also appear in
the journal, but the journal must be linked back to timeline events by event id,
commit order, or log offset.

## 9. Unknown Events

A reader must preserve or safely fold unknown events. A renderer may show an
unknown event as a collapsed block with type, time, actor, and loss status.

An editor that cannot preserve unknown events must declare a lossy export. It
must not silently discard unknown events from the canonical timeline.
