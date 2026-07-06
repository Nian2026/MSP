# `.chat` Draft 0 Stage Close Status

Status: Draft 0 phase-close candidate.

This document is the public orientation layer for the current `.chat` work. It
is not the final v1 standard, and it does not claim complete heavy-runtime
backend parity.

The purpose of this stage close is narrower:

- keep the current `.chat` validator, samples, lightweight reader, and UI tests
  green and reproducible;
- give developers a small, understandable entry path for reading and writing
  `.chat`;
- separate current evidence from historical notes and unfinished final-parity
  work.

## Gate Files Read

This phase-close pass was performed after reading the public `.chat` spec and evidence files:

```text
Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt
Spec/Chat/README.md
Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md
Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md
Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md
Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md
```

The public spec remains product-neutral. Local construction notes stay outside the publishable repository; executable source validation and retained backend evidence belong under `Conformance/Chat/`.

## What Draft 0 Closes

Draft 0 closes the basic shape of `.chat`:

- a `.chat/` directory package with `manifest.json` and canonical
  `timeline.ndjson`;
- `projections/`, `journal.ndjson`, `artifacts/`, `blobs/`, and `indexes/` as
  declared, non-canonical support layers;
- true timeline ordering for user messages, assistant messages, intermediate
  progress, tool calls, command calls, stdout, stderr, errors, artifacts,
  unknown events, and final answers;
- profile/capability separation so lightweight software can implement
  `read_core` without understanding heavy runtime replay;
- validator, sample packages, SDK helper APIs, and a lightweight UI demo that
  exercise the current Draft 0 rules.

## Developer Entry Path

A new implementation should start here:

1. Read `Guides/MinimalReader.md`.
2. Implement `read_core`: open `manifest.json`, parse `timeline.ndjson`, sort
   by `seq`, render known events, and preserve or fold unknown events.
3. Validate against `Spec/Chat/Samples/good/pure-chat.chat`.
4. Read `Guides/MinimalWriter.md` only when writing packages.
5. Add `read_command_timeline` before adding command execution.
6. Add projections and runtime journal only when the product needs them.

The Swift helper layer is:

```text
Implementations/Swift/Sources/MSPChat/
Implementations/Swift/Sources/MSPChatCommands/
Implementations/Swift/Sources/MSPAgentChatStore/
```

The Swift workspace layer now presents `.chat` directory packages as regular
workspace files by default: `find / -name '*.chat' -type f` can discover them,
normal directory traversal does not expose `manifest.json` or `timeline.ndjson`,
and `chat read <path>` remains the model-facing read path.

The lightweight UI reference is:

```text
Spec/Chat/Demos/LightweightReader/
```

The repository also contains an app-level integration example under
`Examples/iOS/PhotoSorter/Agent/ToolLoop/PhotoSorterChatPersistence.swift`.
This phase close does not modify or validate that app's Xcode, MLX, or package
graph.

The Draft 0 `chat read <path>` command implementation intentionally matches the
external saved-conversation reader behavior proven in Readex Mode: Markdown is
the default model-facing output, `--json` is opt-in, and the cursor/output
options use the same public contract. It reads MSP standard `.chat` packages
through the `MSPChat` core reader rather than reading legacy product-private
conversation JSON.

## Current Reproducible Checks

These are the phase-close checks that should be green before opening this
Draft 0 slice:

```text
swift test --filter MSPChatTests
swift test --filter MSPChatCommandsTests
swift build --product msp-chat-validate
swift run msp-chat-validate Spec/Chat/Demos/LightweightReader/fixtures/ui-conformance.chat

cd Spec/Chat/Demos/LightweightReader
npm run test:ui
```

Current lightweight UI evidence:

```text
Spec/Chat/Demos/LightweightReader/results/lightweight-reader-ui-report.json
Spec/Chat/Demos/LightweightReader/results/desktop-ui-conformance.png
Spec/Chat/Demos/LightweightReader/results/mobile-ui-conformance.png
```

Current source-level reference-backend evidence retained in the repository under
`Conformance/Chat/CodexCliValidation/` is bounded by `PUBLIC_EVIDENCE.md`:

```text
phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json
phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json
```

The first three are accepted phase-close evidence for source identity, basic
build availability, and one narrow running-rejoin backend slice. The inventory
result verifies that every machine-readable phase-close evidence file
referenced by the public evidence index exists in the repository snapshot.
`PUBLIC_EVIDENCE.md` also retains human-readable `report.md` companions for the
CLI build and running-rejoin slices; those reports are not additional
machine-readable parity results.

## Known Gaps

These gaps are not blockers for Draft 0, but they are blockers for v1/final:

- full backend parity is not proven;
- complete no-data-loss mapping is not proven;
- full final-parity evidence has not been regenerated under the future
  `results/` package; historical Markdown reports remain local notes until
  their machine-readable artifacts are restored or rerun and promoted into
  `PUBLIC_EVIDENCE.md`;
- command execution conformance is not equivalent to command timeline display;
- runtime journal replay and crash recovery remain advanced conformance work;
- single-file `.chat` containers are not specified yet;
- long-term compatibility and version migration rules need more implementation
  pressure before freezing.

## Phase-Close Acceptance

This stage is ready when:

- Draft 0 docs clearly say they are draft, not final v1;
- the developer entry path is visible from `README.md`;
- validator and lightweight UI checks pass;
- current machine-readable evidence files referenced by phase-close docs exist;
- final-parity gaps remain explicit instead of being hidden by historical notes.
