# `.chat` Projections

Status: draft standard candidate.

This document defines standard projection semantics for agent reads, human
reads, UI timelines, model context, and audit. Projections are not canonical
history. They are rebuildable views or explicitly materialized caches derived
from canonical timeline, artifacts, blobs, and optional journal data.

## 1. Projection Kinds

Standard projection kinds:

- `chat-read.machine`: machine-readable projection for agents, CLIs, validators,
  and lightweight tooling.
- `chat-read.markdown`: human-readable text or Markdown projection.
- `ui-timeline`: display-ready ordered view derived from canonical timeline.
- `model-context`: resumable context projection for continuing a conversation.
- `audit`: evidence, command, permission, error, loss, and degradation view.

A package may include additional projection kinds as extensions.

## 2. Materialized Projection Records

Every materialized projection must declare provenance.

Required metadata:

```json
{
  "projection_id": "proj_...",
  "projection_kind": "chat-read.machine",
  "projection_format": "ndjson",
  "source_event_range": {"from_seq": 1, "to_seq": 20},
  "source_event_ids": ["evt_..."],
  "source_fingerprint": "sha256:...",
  "generator": {"name": "implementation-neutral-name", "version": "1"},
  "generated_at": "2026-06-30T00:00:00Z",
  "lossy": false,
  "redacted": false,
  "truncated": false,
  "stale_if": []
}
```

Recommended metadata:

- `artifact_refs`;
- `blob_refs`;
- `context_policy`;
- `cursor`;
- `loss_matrix`;
- `call_output_balance_policy`;
- `synthetic_items`;
- `extensions`.

## 3. Staleness

A projection is stale if its declared source event range, source ids, source
fingerprint, artifact refs, blob refs, context policy, or generator assumptions
no longer match the canonical package state.

A reader must not treat stale projection content as canonical data. It may ignore
the projection, rebuild it, or display a degraded state.

## 4. Loss Matrix

Every materialized projection must explain what happened to source data.

Loss matrix categories:

- `preserved`;
- `transformed`;
- `truncated`;
- `redacted`;
- `dropped`;
- `external_only`;
- `missing`.

Projection truncation is a view-level property. It must not modify canonical
timeline events or canonical output refs.

## 5. Cursors

Projection cursors must be self-describing. A cursor must include or reference:

- projection kind;
- scope;
- filter;
- source event boundary;
- ordering mode;
- loss/truncation mode when relevant.

Alternatively, the projection output must include a complete continuation command
or request that contains all necessary scope and filter information.

A cursor must not depend on a caller remembering hidden state.

## 6. `chat-read.machine`

`chat-read.machine` is the standard agent-readable projection. It must be
machine-parseable and must preserve enough structure for tools to distinguish
messages, command calls, command outputs, tool calls, artifacts, errors,
truncation, and continuation cursors.

It may omit large outputs only if it marks them as truncated and points to the
canonical output or artifact/blob reference.

## 7. `chat-read.markdown`

`chat-read.markdown` is for human display. It may be optimized for readability.
It must not be the only projection required for machine conformance.

Markdown output must mark truncation, redaction, missing artifacts, and
external-only references.

## 7.1 Recommended `chat read <path>` Command

The standard recommended command projection is:

```text
chat read <path>
  [--scope full|recent]
  [--cursor <cursor>]
  [--turn-limit <n>]
  [--include-outputs]
  [--no-outputs]
  [--max-output-chars-per-item <n>]
  [--json]
```

The default output is Markdown, not JSON. The command is optimized for a model
or human to orient on a saved conversation without learning the storage schema
first.

Default behavior:

- `scope=full`;
- recent reads default to 5 turns;
- outputs are included by default;
- each output item is capped at 12000 characters by default;
- new cursors use stable anchors such as `full-after:<turn-id>` and
  `recent-before:<turn-id>`, not projection array offsets;
- cursor prefixes are self-describing, so output-provided cursors can be passed
  back as `--cursor <cursor>` without repeating `--scope`;
- `--json` is an additional programmatic projection mode and must not change
  the Markdown default.

The Markdown projection should include the next cursor only as a continuation
handle for an agent or command runner. The cursor itself does not need to be
human-readable, but it must be stable across projection rebuilds and must fail
closed when the anchor no longer exists.

The `--json` projection should expose a structured read shape suitable for UIs,
tests, indexes, and automation:

```text
schemaVersion
conversation { id, title, preview, status, path, cwd, createdAt, updatedAt }
page { order, scope, cursor, limit, nextCursor, hasMore, itemsView,
       includeOutputs, maxOutputCharsPerItem }
turns[] { id, status, error, startedAt, completedAt, durationMs, itemsView,
          items[] }
items[] { id, type, seq, createdAt, content/text/phase, tool/command/output,
          artifact/event metadata }
```

This shape deliberately follows the useful structure of mature thread-read
APIs: conversation metadata, explicit page metadata, turn lifecycle fields, and
stable item identities. MSP `.chat` still adds file-path reading, canonical
timeline `seq`, stdout/stderr stream preservation, unknown event preservation,
and explicit truncation/loss markers where available.

The command reads an MSP standard `.chat` package path, not a product-private
conversation JSON file. A conforming implementation must derive the projection
from canonical `manifest.json` and `timeline.ndjson` and must preserve real
`seq` order inside each displayed turn. Implementations may visually group
events into turns, but they must not bucket all messages, all tool calls, or all
outputs separately.

The first Swift command pack is:

```swift
try MSPChatCommandPack().registerCommands(into: registry)
```

Legacy import from other `.chat` JSON formats is a separate compatibility
problem and is not part of this command's Draft 0 contract.

## 8. UI Timeline Projection

`ui-timeline` is a display-ready view derived from canonical `seq` order. It may
group adjacent events visually, but it must preserve real ordering. It must not
move all tool calls into one bucket or all assistant messages into another.

UI projections must distinguish:

- user messages;
- assistant intermediate messages;
- assistant final messages;
- tool calls and outputs;
- command calls and outputs;
- stdout and stderr;
- errors;
- artifacts and attachments;
- unknown events.

## 9. Model Context Projection

`model-context` is used to continue a conversation. It is not canonical history.

It must declare:

- source event range and fingerprint;
- context policy;
- token or size budget when applicable;
- compaction checkpoint used, if any;
- artifact/blob inclusion policy;
- call/output balance policy;
- stale conditions;
- loss matrix.

If a model-context projection creates synthetic replay items to satisfy a model
or tool protocol, those items must be marked:

```json
{
  "synthetic": true,
  "derived_from_output_event_id": "evt_...",
  "not_canonical": true
}
```

Synthetic replay items must not be written back into the canonical timeline as
if they were real historical events.

## 10. Call/Output Balance

Model-facing projections may need paired call/output records. The projection
must declare its balancing policy:

- `preserve_unpaired`;
- `insert_aborted_output`;
- `drop_orphan_output`;
- `preserve_as_unpaired_evidence`;
- extension policy.

Validators must be able to explain why each synthetic, dropped, or preserved
call/output item exists.

## 11. Audit Projection

The `audit` projection should include:

- command spans;
- tool spans;
- policy requests and decisions;
- permission and environment snapshots;
- errors and degradation events;
- artifact/blob references;
- loss matrix;
- compaction checkpoints;
- fork and rollback events;
- journal linkage where present.

Audit projection is a view. It must link back to canonical event ids and must not
replace canonical data.
