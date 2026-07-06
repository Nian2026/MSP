# `.chat` Validator Evidence

Status: Draft 0 runnable validator slice.

This report records the current executable validation evidence. It is not the
final `.chat` conformance report and does not claim heavy-runtime backend
parity.

## Gate Read Before This Work

This validator slice was implemented after reading the public `.chat` spec files and Codex CLI baseline evidence:

```text
Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt
Spec/Chat/README.md
Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md
Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md
Spec/Chat/CorePackage.md
Spec/Chat/TimelineEvents.md
Spec/Chat/CommandTimeline.md
Spec/Chat/Projections.md
Spec/Chat/ContextAndJournal.md
Spec/Chat/Conformance.md
```

Reused conclusions:

- `timeline.ndjson` is the canonical source of truth.
- Projections, journals, and indexes cannot override the timeline.
- Command spans must be validated as MSP shell-like runtime spans, not as
  generic shell-named tool calls.
- Machine-readable projection is required for machine conformance; Markdown is
  only a human projection.
- Projection truncation and staleness are view-level facts and must not imply
  canonical data loss.
- Heavy runtime validation remains source-level backend parity work and is not
  satisfied by this validator.

## Implemented Artifacts

```text
Implementations/Swift/Sources/MSPChat/
Implementations/Swift/Sources/MSPChatValidatorCLI/
Tests/Swift/Unit/MSPChat/
Spec/Chat/Samples/
Spec/Chat/Guides/
Spec/Chat/Demos/LightweightReader/
```

The Swift package now exposes:

```text
MSPChat
msp-chat-validate
```

`MSPChat` now includes a minimal core helper API in addition to the validator:

```text
MSPChatJSONValue
MSPChatManifest
MSPChatTimelineEvent
MSPChatPackage
MSPChatCoreReader
MSPChatCoreWriter
```

This helper layer reads `manifest.json` and the canonical `timeline.ndjson`,
preserves unknown JSON event shape, creates minimal `core-timeline` packages,
and appends new core events without claiming MSP command execution capability.
It deliberately does not execute commands, replay journals, or treat
projections as canonical history.

The lightweight demo under `Spec/Chat/Demos/LightweightReader/` adds a browser
reader/writer surface that:

- opens bundled `.chat` fixtures and local directory-selected packages;
- renders canonical `timeline.ndjson` in `seq` order;
- displays messages, intermediate assistant output, tool calls, tool output,
  MSP command calls, stdout, stderr, errors, artifacts, control events, and
  unknown events without executing commands;
- searches timeline text;
- appends ordinary message events for lightweight continuation;
- exports a preserved text bundle containing unchanged projection files;
- warns when a projection is truncated without implying canonical timeline
  truncation.

## Draft 0 Phase-Close Checks

These checks are the current phase-close gate for the `.chat` validator and
lightweight UI slice:

```text
swift test --filter MSPChatTests
swift build --product msp-chat-validate
swift run msp-chat-validate Spec/Chat/Demos/LightweightReader/fixtures/ui-conformance.chat

cd Spec/Chat/Demos/LightweightReader
npm run test:ui
```

They prove the current Draft 0 validator/helper/UI slice only. They do not prove
complete backend parity, command execution conformance, or v1 compatibility.

Current retained lightweight UI evidence:

```text
Spec/Chat/Demos/LightweightReader/results/lightweight-reader-ui-report.json
Spec/Chat/Demos/LightweightReader/results/desktop-ui-conformance.png
Spec/Chat/Demos/LightweightReader/results/mobile-ui-conformance.png
```

Current source-level backend evidence retained under
`Conformance/Chat/CodexCliValidation/phase-results/` is listed in
`Spec/Chat/CurrentStatus.md`. Historical Markdown reports may mention older
`results/...` paths that are not present in this repository snapshot; those are
not accepted as current evidence until regenerated or restored.

## Current Validator Checks

The current validator checks:

- package directory shape;
- required `manifest.json`;
- required `timeline.ndjson`;
- manifest `format`, `version`, profiles, capabilities, and timeline metadata;
- lossy package markers requiring reason and loss matrix;
- known data profiles and capability flags;
- timeline event envelope fields;
- `seq` strict ordering;
- event id uniqueness;
- durability class;
- unknown event preservation warnings;
- lossy timeline events requiring reason or loss matrix;
- provider continuation handles staying out of canonical timeline payloads;
- message role/content basics;
- tool call/output ordering;
- command call/output/stage/complete ordering;
- command error terminal events;
- skipped command stages requiring skip reasons;
- stdout/stderr per-stream ordering;
- pipefail plus negation exit-status formula;
- command events requiring `command-timeline`;
- artifact references and missing package paths;
- inline `artifact_refs` / `blob_refs` on timeline events, including command
  and tool outputs;
- package-relative artifact/blob path safety;
- declared artifact/blob size and SHA-256 hash checks;
- redacted, missing, and external-only artifact states;
- projection provenance fields;
- projection source range validity;
- projection loss matrix requirements;
- machine-readable projection availability;
- projection cursor self-description;
- model-context call/output balance policy;
- synthetic model-context replay markers;
- provider continuation handle invalidation and scope metadata;
- index provenance and range validity;
- journal linkage where `journal.ndjson` exists;
- runtime-journal profile requiring `journal.ndjson`;
- compaction checkpoint source data;
- fork source/new package fields;
- rollback marker fields;
- resume degradation reasons;
- cold-history materialize-before-append lifecycle records.

## Verified Commands

```text
swift test --filter MSPChatTests
swift build --product msp-chat-validate
```

Both commands passed on 2026-06-30.

The artifact/blob validator slice was verified on 2026-07-02 with:

```text
swift test --filter MSPChatValidatorTests
swift build --product msp-chat-validate
```

Both commands passed. A focused CLI check also verified
`good/artifact-blob-refs.chat`, `bad/blob-hash-mismatch.chat`, and
`bad/unsafe-artifact-path.chat`.

The lightweight UI demo was refreshed on 2026-07-03 after strengthening the UI
fixture from 13 to 15 canonical timeline events. The fixture now includes a
second tool call/output pair between command stdout and command stderr, so the
UI evidence directly checks that messages and tool events are not grouped by
type.

It was verified with:

```text
cd Spec/Chat/Demos/LightweightReader
npm run test:ui
```

The UI test passed on 2026-07-03 and wrote:

```text
Spec/Chat/Demos/LightweightReader/results/lightweight-reader-ui-report.json
Spec/Chat/Demos/LightweightReader/results/desktop-ui-conformance.png
Spec/Chat/Demos/LightweightReader/results/mobile-ui-conformance.png
```

The UI report verifies true timeline event order, strict `seq` order,
stdout/assistant-intermediate/tool/stderr/final interleaving, explicit
non-grouping of messages and tool events, visible tool/command/error/artifact
and unknown events, search filtering, append/export preservation, and
desktop/mobile non-overlap checks.

The refreshed UI fixture was also checked with the validator:

```text
swift run msp-chat-validate Spec/Chat/Demos/LightweightReader/fixtures/ui-conformance.chat
```

Result on 2026-07-03:

```text
status: pass
timeline_events: 15
projection_records: 1
errors: 0
warnings: 0
```

After the UI fixture refresh and during Draft 0 phase-close, the validator
tests and CLI build were rerun on 2026-07-03:

```text
swift test --filter MSPChatTests
swift build --product msp-chat-validate
```

Both commands passed. The current `MSPChatTests` filter executed 21 XCTest tests
with 0 failures.

`swift test --filter MSPChatTests` was rerun after adding the minimal core
reader/writer helper. The added helper tests verify:

- reading `good/pure-chat.chat`;
- preserving the interleaved order in `good/interleaved-command.chat`;
- preserving an unknown extension event from `good/unknown-preserved.chat`;
- creating a minimal package that passes `msp-chat-validate`;
- appending a message with the next `seq` and updated manifest timestamp.

The unit test matrix now covers all current samples:

```text
good samples: 14
bad samples:  21
```

The broader CLI validation scan also includes the lightweight demo UI fixture:

```text
good packages including demo fixture: 15
bad samples:                       21
```

The built CLI was also run against all current good and bad samples on
2026-07-02 after adding artifact/blob path, size, and hash validation:

```text
Spec/Chat/Samples/good/artifact-blob-refs.chat                         pass
Spec/Chat/Samples/good/assistant-progress.chat                         pass
Spec/Chat/Samples/good/command-parse-error.chat                        pass
Spec/Chat/Samples/good/context-control.chat                            pass
Spec/Chat/Samples/good/interleaved-command.chat                        pass
Spec/Chat/Samples/good/long-output-truncation.chat                     pass
Spec/Chat/Samples/good/lossy-import-marker.chat                        pass
Spec/Chat/Samples/good/non-zero-exit.chat                              pass
Spec/Chat/Samples/good/permission-denied.chat                          pass
Spec/Chat/Samples/good/pure-chat.chat                                  pass
Spec/Chat/Samples/good/redacted-artifact.chat                          pass
Spec/Chat/Samples/good/runtime-journal.chat                            pass
Spec/Chat/Samples/good/skipped-stage.chat                              pass
Spec/Chat/Samples/good/unknown-preserved.chat                          pass
Spec/Chat/Demos/LightweightReader/fixtures/ui-conformance.chat         pass

Spec/Chat/Samples/bad/blob-hash-mismatch.chat                          fail: artifact-hash-mismatch
Spec/Chat/Samples/bad/cold-history-no-materialize.chat                 fail: cold-history-materialize-before-append
Spec/Chat/Samples/bad/command-output-before-call.chat                  fail: command-output-before-call
Spec/Chat/Samples/bad/compaction-missing-source.chat                   fail: compaction-source-range
Spec/Chat/Samples/bad/continuation-handle-in-core.chat                 fail: continuation-handle-in-core
Spec/Chat/Samples/bad/continuation-handle-invalidated.chat             fail: continuation-handle-invalidated-reason
Spec/Chat/Samples/bad/fork-missing-source.chat                         fail: fork-source-package
Spec/Chat/Samples/bad/inserted-aborted-output-missing-policy.chat      fail: projection-call-output-balance-policy
Spec/Chat/Samples/bad/lossy-missing-detail.chat                        fail: lossy-marker-detail
Spec/Chat/Samples/bad/markdown-only-projection.chat                    fail: markdown-only-projection
Spec/Chat/Samples/bad/missing-artifact.chat                            fail: artifact-path-missing
Spec/Chat/Samples/bad/missing-manifest.chat                            fail: missing-manifest
Spec/Chat/Samples/bad/out-of-order-seq.chat                            fail: timeline-seq-order
Spec/Chat/Samples/bad/pipefail-negation-mismatch.chat                  fail: command-exit-formula
Spec/Chat/Samples/bad/scope-bound-cursor.chat                          fail: projection-cursor-self-description
Spec/Chat/Samples/bad/stale-index.chat                                 fail: index-range-beyond-timeline
Spec/Chat/Samples/bad/stale-projection.chat                            fail: projection-range-beyond-timeline
Spec/Chat/Samples/bad/stdout-stderr-order.chat                         fail: command-stream-order
Spec/Chat/Samples/bad/synthetic-replay-missing-marker.chat             fail: projection-synthetic-marker
Spec/Chat/Samples/bad/tool-output-before-call.chat                     fail: tool-output-before-call
Spec/Chat/Samples/bad/unsafe-artifact-path.chat                        fail: artifact-path-unsafe
```

## Not Yet Covered

This is only the first executable slice. Still missing:

- developer-facing SDK examples beyond the minimal core helper API;
- fuller lightweight reader/writer demo coverage beyond the first web slice;
- Readex-mode importer;
- reading-mode conversation importer;
- Codex CLI `.chat` backend source modification;
- original-vs-adapted Codex parity test matrix;
- data fidelity report proving no persisted data loss;
- user-indistinguishable backend parity evidence.
