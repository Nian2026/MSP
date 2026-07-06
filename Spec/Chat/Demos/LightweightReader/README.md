# Lightweight `.chat` Reader Demo

Status: executable demo slice.

This demo is intentionally small. It does not embed a heavy agent runtime, does
not execute MSP commands, and does not treat projections as canonical history.
It reads a `.chat` package shape, renders the canonical `timeline.ndjson` in
`seq` order, supports search, exports the in-memory package, and appends ordinary
message events for lightweight continuation.

## Run

```text
npm install
npm run test:ui
```

For manual inspection, serve this folder with any static HTTP server and open
`index.html`.

## Current Evidence

The UI fixture contains 15 canonical `timeline.ndjson` events. It intentionally
interleaves user messages, assistant intermediate messages, tool calls, tool
outputs, an MSP command call, stdout, stderr, a recoverable error, an artifact,
an unknown event, and a final answer.

`npm run test:ui` writes:

```text
results/lightweight-reader-ui-report.json
results/desktop-ui-conformance.png
results/mobile-ui-conformance.png
```

The current report checks true `seq` order, stdout/assistant/tool/stderr/final
interleaving, that messages and tool events are not grouped by type, search,
append/export preservation, projection truncation warning visibility, and
desktop/mobile non-overlap.

## Scope

Implemented:

- open bundled fixture packages;
- open a local directory-selected `.chat` package in browsers that support
  directory file inputs;
- render messages, message deltas, tools, MSP commands, stdout, stderr, errors,
  artifacts, control events, and unknown events in canonical timeline order;
- search timeline text;
- append ordinary message events;
- export a text bundle containing preserved package files;
- show projection truncation without implying canonical timeline truncation.

Not implemented:

- MSP command execution;
- runtime journal replay;
- heavy backend parity;
- binary package export.
