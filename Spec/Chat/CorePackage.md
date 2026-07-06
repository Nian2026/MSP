# `.chat` Core Package

Status: draft standard candidate.

This document defines the product-neutral `.chat` package shape, manifest,
canonical timeline ownership, profiles, capabilities, unknown-data preservation,
loss markers, artifacts, blobs, and indexes.

Implementation evidence, migration notes, and product-specific validation work
belong in local `.chat` internal construction notes. This standard text must remain independent of
any one application, model provider, runtime, database, or storage backend.

## 1. Package

A `.chat` conversation is first validated as a directory package:

```text
<conversation-name>.chat/
  manifest.json
  timeline.ndjson
  projections/
    chat-read.ndjson
    model-context.ndjson
    audit.ndjson
  journal.ndjson
  artifacts/
  blobs/
  indexes/
```

Only `manifest.json` and `timeline.ndjson` are required for the smallest
`core-timeline` package. Other paths are present only when declared in the
manifest. A single-file container may be specified later, but it must preserve the
same logical package model.

## 2. Source Of Truth

`timeline.ndjson` is the canonical source of truth for portable conversation
facts. It records events in the order they actually occurred.

`projections/` contains rebuildable or explicitly materialized views. A
projection may be optimized for user interfaces, agent reads, model context, or
audit, but it must not replace canonical timeline data.

`journal.ndjson` is an optional heavy-runtime recovery and audit layer. It may
contain replay, checkpoint, recovery, and writer state details. It must not hide
portable conversation facts that a lightweight reader needs in order to display
the conversation faithfully.

`artifacts/` and `blobs/` contain structured evidence metadata and large content.

`indexes/` contains derived acceleration data. Indexes must be rebuildable from
canonical package data or marked as stale.

## 3. Manifest

`manifest.json` identifies the package and declares what data exists and what the
writer claims it can do.

Required manifest fields:

```json
{
  "format": "msp.chat",
  "version": 1,
  "package_id": "chatpkg_...",
  "created_at": "2026-06-30T00:00:00Z",
  "updated_at": "2026-06-30T00:00:00Z",
  "profiles": ["core-timeline"],
  "capabilities": ["read_core"],
  "timeline": {
    "path": "timeline.ndjson",
    "encoding": "utf-8",
    "record_format": "ndjson"
  }
}
```

Optional manifest fields include participants, title, locale, storage options,
declared projections, declared journal, artifact stores, blob stores, index
stores, compression, integrity metadata, and writer identity.

The manifest must not contain fields named after a product, vendor, or private
runtime. Implementation-specific data may be stored as an extension object, but
it must be namespaced and preserved according to the unknown-data rules below.

## 4. Profiles

Profiles describe the data present in the package. They do not describe what a
program can execute.

Standard profiles:

- `core-timeline`: package, manifest, event envelope, message, status, error,
  artifact reference, ordering, unknown preservation, and loss markers.
- `agent-timeline`: intermediate assistant output, tool calls, tool output,
  command records, command output, references, and richer status events.
- `command-timeline`: shell-like command spans, parse/expansion information,
  stdin, stdout, stderr, pipeline stages, exit status, and command state changes.
- `projection-cache`: materialized `chat-read`, `model-context`, `audit`, or UI
  projections with provenance and stale rules.
- `resumable-context`: context snapshots, context projections, compaction
  checkpoints, and resume degradation records.
- `runtime-journal`: heavy-runtime journal, replay, writer barriers, recovery
  ordering, state snapshots/patches, lifecycle, fork, rollback, and crash repair.

Profiles are additive but not hierarchical. A package can contain
`command-timeline` without allowing command execution.

## 5. Capabilities

Capabilities describe what an implementation can do.

Standard capabilities:

- `read_core`: read manifest and core timeline.
- `write_core`: append or write core timeline events.
- `read_command_timeline`: display command history and command output.
- `write_command_timeline`: write standard command events.
- `execute_msp_commands`: execute MSP command language and append resulting
  command events.
- `generate_projection`: generate or refresh standard projections.
- `replay_journal`: replay runtime journal state.
- `lossless_edit`: edit while preserving unknown data.
- `preserve_unknown_events`: keep unrecognized events and extension data.

Displaying command history is not command execution. An application may support
`read_command_timeline` without supporting `execute_msp_commands`.

## 6. Timeline File

`timeline.ndjson` is newline-delimited JSON. Each line is one event envelope. The
file is append-friendly, but the standard does not require every writer to use
append-only filesystem operations.

Every timeline event must have:

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

`seq` defines display order inside the canonical timeline. If two events share a
timestamp, `seq` remains the deterministic ordering key.

Packages that write multiple files must also use `commit_seq`, `log_offset`, or
an equivalent durable ordering marker to relate timeline, journal, projection,
and index writes. Projections and indexes must be updated only after the
canonical write they depend on is durable, or they must be marked stale.

## 7. Unknown Data

Readers must tolerate unknown standard event types, unknown extension event
types, unknown manifest fields, unknown projection files, unknown journal
entries, and unknown artifact/blob metadata.

An implementation that claims `lossless_edit` or `preserve_unknown_events` must
preserve unknown data byte-for-byte where practical, or preserve a semantically
equivalent representation with an explicit preservation note.

If an implementation cannot preserve unknown data, it must write an explicit
loss marker before saving the result, or export into a new lossy package.

## 8. Loss Markers

Loss must never be silent.

Standard loss flags:

- `lossy`: some source data was not preserved.
- `redacted`: data was intentionally removed.
- `truncated`: a projection or view is shortened.
- `external_only`: the referenced data was not embedded in the package.
- `missing`: the package refers to data that is unavailable.
- `transformed`: data was converted to another representation.

Projection truncation does not imply canonical timeline truncation. If canonical
data exists elsewhere in the package, the projection must point to it.

## 9. Artifacts And Blobs

Timeline events should reference large or structured evidence instead of
inlining large binary data.

An artifact or blob reference should include:

- source event id;
- package-relative path or content-addressed id;
- media type;
- byte size when known;
- hash when available;
- display name;
- page, time, text, frame, or byte range when applicable;
- extraction parameters when applicable;
- projection policy;
- missing, redacted, or external-only status when applicable.

A local filesystem path alone is not a portability guarantee.

## 10. Indexes

Indexes are derived data. A package may include search indexes, thread-list
indexes, relation indexes, UI acceleration data, or lifecycle indexes.

Each index must declare:

- source event range or fingerprint;
- generator;
- generated time;
- stale conditions;
- whether it is complete or partial.

If an index is stale, a conforming reader must ignore it, rebuild it, or clearly
report degraded index behavior.

## 11. Minimal Reader Contract

A minimal conforming reader needs only `read_core`:

1. Read `manifest.json`.
2. Verify the package declares `core-timeline`.
3. Read `timeline.ndjson` in `seq` order.
4. Render known core events.
5. Preserve or safely fold unknown events.
6. Treat projections and indexes as optional.
7. Never treat projection truncation as canonical data loss.

This contract is the low-entry path for new implementers.
