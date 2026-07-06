# `.chat` Projection Guide

Status: draft developer guidance.

Goal: generate useful derived views without confusing them with canonical
history.

## Projection Kinds

Standard projection kinds:

- `chat-read.machine`: machine-readable agent or CLI view.
- `chat-read.markdown`: human-readable text or Markdown.
- `ui-timeline`: display-ready ordered view.
- `model-context`: context used to continue a conversation.
- `audit`: evidence, command, permission, error, and loss view.

Projection files live under `projections/`. They are derived from
`timeline.ndjson`, artifacts, blobs, and optional journal data.

## Required Metadata

Every materialized projection record needs provenance:

```json
{
  "projection_id": "proj_001",
  "projection_kind": "chat-read.machine",
  "projection_format": "ndjson",
  "source_event_range": {"from_seq": 1, "to_seq": 10},
  "source_event_ids": ["evt_001"],
  "source_fingerprint": "sha256:...",
  "generator": {"name": "example-generator", "version": "1"},
  "generated_at": "2026-06-30T00:00:00Z",
  "lossy": false,
  "redacted": false,
  "truncated": false,
  "stale_if": ["timeline_changed"],
  "loss_matrix": {
    "preserved": ["messages"],
    "transformed": [],
    "truncated": [],
    "redacted": [],
    "dropped": [],
    "external_only": [],
    "missing": []
  }
}
```

## Staleness

A projection is stale if the source range, source ids, source fingerprint,
artifact refs, blob refs, context policy, or generator assumptions no longer
match the package.

When stale:

- do not treat the projection as canonical;
- rebuild it, ignore it, or show degraded behavior;
- never overwrite canonical timeline events with projection content.

## Machine Versus Markdown

`chat-read.machine` is the machine path. `chat-read.markdown` is the human path.

If a package declares `projection-cache` and includes materialized chat-read
data, a machine-readable projection must exist. Markdown alone is not enough for
machine conformance.

## Cursors

Cursors must be self-describing. A cursor should include:

- projection kind;
- scope;
- filter;
- source event boundary;
- ordering mode;
- truncation or loss mode when relevant.

If the cursor is not self-describing, the projection must provide a complete
continuation request containing the same information.

## Model Context

`model-context` is for continuation. It is not canonical history.

It must declare:

- source range and fingerprint;
- context policy;
- artifact/blob inclusion policy;
- call/output balance policy;
- stale conditions;
- loss matrix.

If a projection creates synthetic replay items, mark each one:

```json
{
  "synthetic": true,
  "derived_from_output_event_id": "evt_...",
  "not_canonical": true
}
```

Synthetic items must not be written back to `timeline.ndjson` as if they really
happened.

## Acceptance

A projection implementation is acceptable when `msp-chat-validate` can verify
provenance, stale rules, loss matrix, cursor self-description, synthetic replay
markers, and machine-readable projection availability.
