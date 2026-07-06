# Minimal `.chat` Reader Guide

Status: draft developer guidance.

Goal: implement `read_core` so a lightweight application can open and display a
`.chat` package without understanding command execution, projections, runtime
journals, or backend replay.

## Required Inputs

A minimal reader only needs:

```text
<name>.chat/
  manifest.json
  timeline.ndjson
```

It may ignore `projections/`, `journal.ndjson`, `artifacts/`, `blobs/`, and
`indexes/` for the first implementation, but it must not corrupt them if it later
saves the package.

In an MSP workspace, this package may be surfaced to users and agents as a
single ordinary path such as `/对话/history.chat`. The reader implementation may
resolve that path to the backing package internally, but file listings and shell
search should not require the model to know about `manifest.json` or
`timeline.ndjson`.

## Steps

1. Verify the path is a `.chat` conversation path and resolve its backing
   package if the workspace exposes package files through a file facade.
2. Read `manifest.json`.
3. Require `format: "msp.chat"`, integer `version`, and `core-timeline` in
   `profiles`.
4. Read the manifest timeline path, usually `timeline.ndjson`.
5. Parse each non-empty line as one JSON object.
6. Validate the event envelope enough to render safely: `id`, `type`, `seq`,
   `created_at`, `durability`, and object `payload`.
7. Display events in strictly increasing `seq` order.
8. Render known core events and fold unknown events without dropping them.
9. Show loss markers such as `lossy`, `redacted`, `truncated`, `missing`, and
   `external_only`.
10. Treat every projection and index as derived data, never as canonical truth.

## Minimal Rendering

Render these event types first:

- `message`: show `role`, `phase`, and text or content refs.
- `status_changed`: show a compact status row when `visible` is true or unknown.
- `error`: show code, message, recoverability, and redaction state.
- `artifact_ref`: show display name, media type, range, and availability status.

If the package also contains agent or command events, a minimal reader may fold
them as unknown blocks. A better lightweight reader can display them using the
same timeline order without executing anything.

## Unknown Events

Unknown events are normal. A reader should display a collapsed row with:

- event type;
- `seq`;
- `created_at`;
- actor if present;
- loss/redaction/truncation markers;
- a note that the event was preserved but not interpreted.

Do not delete unknown events during read-only display. If the reader later
saves and cannot preserve unknown data, it must export a new lossy package or
write an explicit loss marker.

## Do Not

- Do not read `projections/` first and treat it as history.
- Do not group all messages, all tool calls, or all command outputs into
  separate buckets.
- Do not assume there is only one assistant message per turn.
- Do not treat projection truncation as canonical timeline truncation.
- Do not execute command events just because they appear in the timeline.

## Acceptance

A minimal reader is acceptable when it can open `good/pure-chat.chat`, render the
core timeline in order, preserve or fold unknown event data, and pass
`msp-chat-validate` for packages it writes.
