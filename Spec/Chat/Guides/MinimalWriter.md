# Minimal `.chat` Writer Guide

Status: draft developer guidance.

Goal: implement `write_core` so an application can create or append a valid
core `.chat` package.

## Minimal Package

Create:

```text
<name>.chat/
  manifest.json
  timeline.ndjson
```

Minimal `manifest.json`:

```json
{
  "format": "msp.chat",
  "version": 1,
  "package_id": "chatpkg_example",
  "created_at": "2026-06-30T00:00:00Z",
  "updated_at": "2026-06-30T00:00:00Z",
  "profiles": ["core-timeline"],
  "capabilities": ["read_core", "write_core"],
  "timeline": {
    "path": "timeline.ndjson",
    "encoding": "utf-8",
    "record_format": "ndjson"
  }
}
```

Each `timeline.ndjson` line is one event object:

```json
{"id":"evt_001","type":"message","seq":1,"created_at":"2026-06-30T00:00:00Z","durability":"durable_replay","payload":{"role":"user","content":"Hello"}}
```

## Event Rules

For every event:

- generate a stable `id`;
- set a product-neutral `type`;
- assign a unique, strictly increasing `seq`;
- set `created_at`;
- set `durability`;
- write object `payload`;
- include `turn_id`, `actor`, `correlation_id`, or `call_id` when the event
  participates in a turn, stream, tool call, or command span.

Use `durable_replay` for committed facts needed to display or continue the
conversation. Use `live_stream` only for fine-grained deltas that may be omitted
from minimal durable packages.

## Appending

When appending:

1. Read the existing manifest and timeline.
2. Find the highest `seq`.
3. Append new events with higher `seq` values.
4. Update `updated_at`.
5. Preserve unknown manifest fields, projection files, journal entries,
   artifacts, blobs, and indexes if claiming `lossless_edit` or
   `preserve_unknown_events`.

If the writer rewrites the file instead of appending, the resulting timeline must
still preserve stable event ids and canonical order.

## Loss

Loss must be explicit.

If data is dropped, transformed, redacted, or truncated, mark it in the affected
event or in the package manifest:

```json
{
  "lossy": true,
  "loss_reason": "exported without unknown extension data",
  "loss_matrix": {
    "preserved": ["core messages"],
    "dropped": ["unknown extension records"],
    "truncated": [],
    "redacted": [],
    "external_only": [],
    "missing": []
  }
}
```

## Do Not

- Do not write product-specific field names into standard payloads.
- Do not store command output only inside a projection.
- Do not replace canonical timeline data with a shortened display view.
- Do not delete unknown data silently.
- Do not mark `execute_msp_commands` unless the implementation actually executes
  MSP commands and writes standard command events.

## Acceptance

A minimal writer is acceptable when a newly written package passes
`msp-chat-validate`, opens in a minimal reader, and exposes only capabilities it
actually supports.
