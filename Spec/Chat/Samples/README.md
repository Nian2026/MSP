# `.chat` Sample Packages

Status: validator fixtures.

These packages are intentionally small. They are not product examples and they
do not define the standard by themselves. Their job is to make the draft
conformance rules executable.

## Good Samples

- `good/pure-chat.chat/`: minimal `core-timeline` package.
- `good/assistant-progress.chat/`: assistant intermediate message followed by a
  committed final answer.
- `good/interleaved-command.chat/`: user message, assistant intermediate
  message, command call, stdout, assistant intermediate message, stderr,
  command completion, artifact reference, and final answer in real timeline
  order.
- `good/command-parse-error.chat/`: command span ending with a parse error
  terminal event.
- `good/permission-denied.chat/`: command span ending with a policy denial.
- `good/non-zero-exit.chat/`: command completes with a non-zero exit status that
  matches the stage exit formula.
- `good/long-output-truncation.chat/`: canonical output remains in the timeline
  while the materialized projection is marked truncated with a loss matrix.
- `good/artifact-blob-refs.chat/`: command output carries inline artifact and
  blob refs with package-relative paths, sizes, and SHA-256 hashes.
- `good/redacted-artifact.chat/`: artifact reference is explicitly redacted
  instead of pretending package content is available.
- `good/skipped-stage.chat/`: `&&` / `||` style skipped work is represented with
  a skip reason.
- `good/runtime-journal.chat/`: runtime-journal profile with a linked
  `journal.ndjson` entry.
- `good/lossy-import-marker.chat/`: lossy import is explicitly marked with
  reason and loss matrix.
- `good/unknown-preserved.chat/`: unknown extension event with preservation
  capabilities declared.
- `good/context-control.chat/`: compaction checkpoint, fork marker, rollback
  marker, resume degradation, and model-context/chat-read projections.

## Bad Samples

- `bad/missing-manifest.chat/`: missing required manifest.
- `bad/out-of-order-seq.chat/`: timeline `seq` order is invalid.
- `bad/command-output-before-call.chat/`: command output appears before the
  command call.
- `bad/pipefail-negation-mismatch.chat/`: final exit code does not match
  stage exits, `pipefail`, and negation.
- `bad/stale-projection.chat/`: projection source range points beyond the
  canonical timeline.
- `bad/compaction-missing-source.chat/`: compaction checkpoint lacks source
  range and fingerprint.
- `bad/missing-artifact.chat/`: available artifact reference points to a
  missing package path.
- `bad/blob-hash-mismatch.chat/`: available blob reference points to existing
  package content whose SHA-256 does not match the declared hash.
- `bad/unsafe-artifact-path.chat/`: available artifact reference attempts to
  escape the package with an unsafe path.
- `bad/markdown-only-projection.chat/`: projection-cache package contains only
  a Markdown projection and no machine-readable projection.
- `bad/tool-output-before-call.chat/`: tool output appears before the tool call.
- `bad/scope-bound-cursor.chat/`: projection cursor is not self-describing.
- `bad/synthetic-replay-missing-marker.chat/`: synthetic model-context replay
  item lacks required canonical-safety markers.
- `bad/inserted-aborted-output-missing-policy.chat/`: model-context projection
  inserts synthetic items without declaring a call/output balance policy.
- `bad/stdout-stderr-order.chat/`: command output stream sequence goes
  backwards.
- `bad/fork-missing-source.chat/`: fork event lacks source package metadata.
- `bad/continuation-handle-in-core.chat/`: provider continuation handle leaks
  into canonical timeline payload.
- `bad/continuation-handle-invalidated.chat/`: invalidated provider
  continuation handle lacks an invalidation reason.
- `bad/cold-history-no-materialize.chat/`: lifecycle append to compressed cold
  history omits materialize-before-append evidence.
- `bad/stale-index.chat/`: index source range points beyond the canonical
  timeline.
- `bad/lossy-missing-detail.chat/`: lossy package marker lacks reason and loss
  matrix.

This sample set now covers the required fixture families listed in
`Conformance.md`. It is still not the final conformance suite: lightweight UI
automation, importer fixtures, backend parity fixtures, and data-fidelity
fixtures remain separate work.
