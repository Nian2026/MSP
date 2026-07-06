# Codex `.chat` Backend Mapping

This is a retained backend-validation document for the Codex CLI validation package.
It is not part of the public `.chat` standard.

The public standard must stay product-neutral. This document may name Codex
because it explains how the vendored Codex source will be adapted and tested.

## Gate Read Record

Before writing this document, the following required gate files were read:

- `Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt`
- `Spec/Chat/README.md`
- `Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md`
- `Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md`

The vendored Codex source was read from
`upstream/openai-codex-original/` only. The original snapshot must remain
unmodified.

## Source Evidence Read This Pass

Key source files inspected:

- `codex-rs/thread-store/src/store.rs`
- `codex-rs/thread-store/src/types.rs`
- `codex-rs/thread-store/src/lib.rs`
- `codex-rs/thread-store/src/local/mod.rs`
- `codex-rs/thread-store/src/local/live_writer.rs`
- `codex-rs/thread-store/src/local/read_thread.rs`
- `codex-rs/thread-store/src/local/list_threads.rs`
- `codex-rs/thread-store/src/local/search_threads.rs`
- `codex-rs/thread-store/src/local/archive_thread.rs`
- `codex-rs/thread-store/src/local/unarchive_thread.rs`
- `codex-rs/thread-store/src/local/delete_thread.rs`
- `codex-rs/thread-store/src/in_memory.rs`
- `codex-rs/state/src/extract.rs`
- `codex-rs/rollout/src/recorder.rs`
- `codex-rs/rollout/src/policy.rs`
- `codex-rs/rollout/src/compression.rs`
- `codex-rs/protocol/src/protocol.rs`
- `codex-rs/core/src/session/session.rs`
- `codex-rs/core/src/session/rollout_reconstruction.rs`
- `codex-rs/core/src/thread_manager.rs`
- `codex-rs/core/src/config/mod.rs`
- `codex-rs/config/src/config_toml.rs`
- `codex-rs/app-server/src/request_processors/thread_processor.rs`
- `codex-rs/app-server/src/request_processors/thread_lifecycle.rs`

## Core Finding

Codex already has a storage-neutral persistence seam:

```text
codex-thread-store::ThreadStore
```

The trait covers the behavior that a `.chat` backend must preserve:

- create thread
- resume thread
- append items
- persist / flush / shutdown / discard
- load history
- read thread
- read by rollout path
- list threads
- search threads
- list turns / items
- update metadata
- archive / unarchive
- delete

This means the first serious adaptation should not scatter `.chat` writes across
the app-server or session code. The natural source-level proof is to add a
`.chat`-backed `ThreadStore` implementation and select it through configuration,
then drive the same app/server/session code through that backend.

The current local backend is:

```text
LocalThreadStore
  -> RolloutRecorder JSONL durable history
  -> optional SQLite state DB as derived metadata/index
  -> active and archived rollout collections
  -> optional compressed cold history
```

The `.chat` backend must preserve the same externally visible `ThreadStore`
contract while replacing the durable backend shape with `.chat` packages.

## Source Of Truth Mapping

Codex local storage currently has this source-of-truth relation:

```text
Rollout JSONL       durable replay history
SQLite state DB     derived metadata/index
name index          legacy title/name index
archived folder     lifecycle collection
.jsonl.zst          cold-history representation
live recorder       in-process writer and retry state
```

The `.chat` backend target relation is:

```text
timeline.ndjson     canonical ordered conversation timeline
journal.ndjson      runtime recovery / audit journal
projections/        materialized projections, never canonical
indexes/            derived thread list/search/query data
artifacts/ blobs/   large evidence and attachments
manifest.json       package metadata, profiles, capabilities, lifecycle
```

Rules:

- `.chat` timeline must be the canonical cross-software truth.
- Codex-specific replay details may be represented only through neutral
  timeline/journal/projection concepts.
- Lightweight readers must be able to ignore runtime journal details and still
  see the core conversation facts.
- The adapted Codex runtime must be able to reconstruct the same internal
  replay state it can reconstruct today.

## ThreadStore Adaptation Plan

Add a new backend in the adapted source tree only:

```text
codex-rs/thread-store/src/chat/
  mod.rs
  package.rs
  writer.rs
  reader.rs
  index.rs
  lifecycle.rs
  mapper.rs
```

The backend should export something equivalent to:

```text
ChatThreadStore
ChatThreadStoreConfig
```

The adapted config path should add:

```text
ThreadStoreConfig::Chat { root: PathBuf }
ThreadStoreToml::Chat { root: Option<PathBuf> }
```

The initial config must be explicit. The default backend should remain the
original local backend until parity evidence is strong enough to flip defaults.

## Required Backend Behavior

`ChatThreadStore` must implement every `ThreadStore` method that ordinary
Codex CLI usage depends on.

### create_thread

Current behavior:

- opens live persistence;
- creates session metadata lazily;
- records session identity, fork/parent relation, originator, model provider,
  base instructions, dynamic tools, capability roots, memory mode, history
  mode, and initial context window.

`.chat` mapping:

- create `<thread-id-or-name>.chat/`;
- write `manifest.json`;
- write initial `timeline.ndjson` events for thread/session identity using
  product-neutral lifecycle and context events;
- record enough journal data to reconstruct Codex session identity exactly;
- initialize indexes only after durable timeline/journal write succeeds.

Hard acceptance:

- new Codex CLI thread starts normally;
- list/read can discover the new thread;
- the original session id, thread id, fork/parent ids, cwd, model provider,
  base instructions, dynamic tools, selected capability roots, memory mode,
  history mode, and context window are recoverable.

### resume_thread

Current behavior:

- accepts an explicit rollout path or resolves by thread id;
- rejects unsupported paginated history mode;
- materializes compressed rollout before append;
- opens a live recorder for future appends.

`.chat` mapping:

- resolve package by thread id or package path;
- verify package history contract;
- open a live `.chat` writer;
- if cold/compressed representation exists, materialize or reopen in a way that
  preserves the current Codex append semantics;
- keep the package path stable for app-server stale-path checks.

Hard acceptance:

- cold resume and path-addressed resume behave the same as the original backend;
- stale path rejection and override mismatch behavior remain visible to callers;
- future appends land in the same package without losing prior history.

### append_items

Current behavior:

- applies `persisted_rollout_items`;
- writes only durable replay items;
- flushes before metadata/index updates can get ahead of JSONL.

`.chat` mapping:

- apply the same Codex persistence policy before writing;
- map persisted items into standard `.chat` events and journal entries;
- preserve source transport and replay information using product-neutral
  extension envelopes where needed;
- flush timeline/journal before projection/index update.

Hard acceptance:

- no persisted `RolloutItem` that original Codex would keep may disappear;
- no live-only event is forced into durable core unless the `.chat` profile
  declares live-stream retention;
- command/tool/message ordering remains the true order of append.

### persist / flush / shutdown / discard

Current behavior:

- pending items are drained only after successful write;
- `persist()` materializes lazy storage;
- `flush()` is a durability barrier;
- shutdown closes the writer after durable write;
- discard releases live writer state without forcing pending items durable.

`.chat` mapping:

- keep writer state with pending event batches;
- maintain package-level `commit_seq` or equivalent durable ordering;
- update projections/indexes only after durable write;
- recover stale or ahead-of-timeline projection/index state after crash.

Hard acceptance:

- metadata/index must never get ahead of canonical `.chat` timeline;
- failed writes are retryable without silently dropping pending items;
- crash recovery can identify and repair stale derived files.

### load_history / read_thread / read_thread_by_path

Current behavior:

- loads persisted rollout items for resume/fork/rollback/memory jobs;
- read path prefers SQLite metadata, but can fallback to rollout;
- include-history reads the durable replay stream;
- path reads verify the path resolves to the requested thread.

`.chat` mapping:

- load canonical `.chat` timeline plus required journal/projection data;
- produce the same internal `StoredThreadHistory` replay items needed by
  existing Codex session reconstruction;
- derive `StoredThread` from `.chat` package data and indexes;
- fallback to canonical timeline if indexes are missing or stale.

Hard acceptance:

- resume, fork, rollback, memory jobs, and cold history reads receive equivalent
  persisted history;
- metadata repair is possible from `.chat` canonical data;
- path-addressed reads cannot accidentally open the wrong thread.

### list / search

Current behavior:

- list can use state DB, rollout scan, or mixed fallback;
- relation filters require state DB;
- search scans rollout contents and combines matches with list ordering;
- titles/names may come from metadata or legacy name indexes.

`.chat` mapping:

- build `indexes/threads` from canonical timeline/journal;
- support fallback scan of `.chat` packages when indexes are missing or stale;
- implement relation filters using derived index data that can be rebuilt;
- search canonical timeline/projections in a way that preserves original
  snippets and ordering.

Hard acceptance:

- list ordering, filters, archived views, search snippets, and title/name
  behavior match original user-visible behavior.

### archive / unarchive / delete

Current behavior:

- archive moves a rollout file into an archived collection and updates metadata;
- unarchive restores dated session path and touches modified time;
- delete removes active and archived plain/compressed representations plus name
  index entries.

`.chat` mapping:

- represent lifecycle through package location and/or lifecycle metadata;
- preserve user-visible active/archived list behavior;
- delete every representation needed by `.chat` backend, including package,
  compressed/cold representation, and derived index entries.

Hard acceptance:

- archive/unarchive/delete produce the same app-visible results as original
  Codex;
- no orphan package or stale index makes deleted or archived threads visible.

## Codex Item To `.chat` Layer Mapping

| Codex source concept | `.chat` target layer | Required treatment |
|---|---|---|
| `SessionMetaLine` | `manifest.json`, timeline lifecycle/context events, journal context | Preserve session/thread identity, fork/parent relation, originator, cwd, model provider, instructions, dynamic tools, capability roots, memory mode, history mode, context window. |
| `ResponseItem::Message` / `AgentMessage` | `timeline.ndjson` `message` / progress/final message events | Preserve role, phase, content, ids, ordering, and source transport link when present. |
| `ResponseItem::Reasoning` | `timeline.ndjson` or journal depending durability class | Preserve what original Codex persists; classify live deltas separately from durable reasoning records. |
| `ResponseItem::LocalShellCall` | `timeline.ndjson` `command_call` / `command_complete`, plus source transport | Normalize as command timeline, not generic tool call. Preserve raw source item for replay if needed. |
| `ResponseItem::FunctionCall` / `CustomToolCall` / search / image calls | `timeline.ndjson` `tool_call` or specialized neutral event plus source transport | Keep call id, name, arguments, status, output linkage, runtime source envelope. |
| `FunctionCallOutput` / custom/search outputs | `timeline.ndjson` `tool_output` / artifact refs | Preserve output, errors, ids, ordering, and large content refs. |
| `CompactedItem` | `durable_compaction_checkpoint`, `context_window_lineage`, projection baseline, journal | Preserve message, replacement history, window number, first/previous/current window ids. |
| `TurnContextItem` | `runtime_context_snapshot`, `permission_snapshot`, `environment_snapshot`, journal | Preserve cwd, workspace roots, date/timezone, approval/sandbox/permissions, network, model, effort, collaboration, realtime, multi-agent facets. |
| `WorldStateItem` | `state_snapshot` / `state_patch` in runtime journal and control timeline | Preserve full/patch distinction and merge-patch replay order. |
| persisted `EventMsg` | timeline/control/journal events according to durability class | Preserve user-visible events, token count, goal updates, rollback, turn lifecycle, errors, completion signals. |
| non-persisted live `EventMsg` | optional live-stream profile only | Do not force into durable core; keep original live behavior in running sessions. |
| SQLite `ThreadMetadata` | `indexes/` and repairable derived metadata | Must be rebuildable from timeline/journal. Cannot become canonical truth. |
| compressed rollout | cold-history storage profile | Preserve transparent read and materialize-before-append behavior or an equivalent `.chat` package transition. |

## Source Transport Rule

The `.chat` standard layer must not define Codex-specific fields.

The adapted Codex backend may need to retain original runtime/provider payloads
for replay parity. That retention must be represented as a neutral
`source_transport` / runtime-journal envelope with declared provenance, not as
public standard fields named after Codex internals.

Hard rule:

```text
standard event semantics remain product-neutral;
runtime-specific exact replay state is retained only as optional runtime data;
lightweight readers can ignore it and still render the core timeline.
```

## Replay Invariants The Backend Must Preserve

Codex resume/fork reconstruction is not a simple message array replay.

The adapted backend must preserve:

- reverse scan for compaction, rollback, turn context, and world state;
- newest surviving replacement history checkpoint;
- pending rollback user-turn skip count;
- chronological replay of the surviving suffix;
- rollback markers without physical deletion;
- world-state full snapshot and patch ordering;
- previous turn settings;
- reference context baseline;
- context window lineage.

These invariants should be tested before any user-visible parity claim.

## Running Rejoin Invariants

Running thread resume is live overlay plus subscription behavior, not only
history replay.

The adapted backend must preserve:

- active turn snapshot;
- live attachment snapshot;
- running/idle status distinction;
- stale path rejection;
- override mismatch logging/ignore behavior;
- atomic listener attach after resume;
- pending unload rejection;
- token usage replay;
- goal snapshot replay;
- runtime status replay.

These cases belong in parity tests even if the first backend implementation can
pass cold resume.

## Implementation Sequence

1. Add config enum support for an explicit `.chat` thread store.
2. Add `ChatThreadStore` skeleton implementing `ThreadStore`.
3. Add a `.chat` package reader/writer inside the adapted Codex tree, scoped to
   Codex validation and backed by the public `.chat` spec shape.
4. Implement create/resume/append/persist/flush/shutdown/load/read for a minimal
   durable replay package.
5. Map Codex persisted items to standard timeline/journal/projection layers.
6. Add index/list/search/archive/unarchive/delete behavior.
7. Add cold-history representation handling.
8. Add running rejoin parity tests.
9. Add original-vs-chat-backend test harness.
10. Generate diff, data fidelity report, and parity report.

The implementation is not complete until ordinary Codex CLI behavior is
indistinguishable from the original backend.
