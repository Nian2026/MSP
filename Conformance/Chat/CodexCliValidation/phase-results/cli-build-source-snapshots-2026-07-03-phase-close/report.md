# Codex CLI Source Snapshot Build Evidence - 2026-07-03T11:30:14.172949Z

This is retained validation evidence for the `.chat` Codex backend adaptation.
It documents build evidence and does not define the public `.chat` spec or prove full runtime parity.

## Gate Files Read

- `Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt`
- `Spec/Chat/README.md`
- `Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md`
- `Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md`
- `Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md`

## Scope

The runner checked both source snapshots:

```text
source-snapshots/openai-codex-original/codex-rs
source-snapshots/openai-codex-chat-backend/codex-rs
```

Cargo build output is kept outside the source snapshots and exposed
through the script-expected `target/debug/codex` entry points. Build
outputs are cache, not source evidence.

## Result

- status: `pass`
- original binary exists: `True`
- `.chat` backend binary exists: `True`
- version output equal: `True`
- help output hash equal: `True`

## Original

- snapshot entry: `<repo-root>/Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/target/debug/codex`
- resolved artifact: `<codex-chat-validation-build-root>/original/debug/codex`
- artifact size: `635865528`
- artifact sha256: `3abf919cc93027d37fd514dc8aea1a9238acc33af4c2eb54e40596a692e50530`
- cargo target dir: `<codex-chat-validation-build-root>/original`
- `codex --version` exit code: `0`
- `codex --version` stdout: `codex-cli 0.0.0`

## `.chat` Backend

- snapshot entry: `<repo-root>/Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/target/debug/codex`
- resolved artifact: `<codex-chat-validation-build-root>/chat-backend/debug/codex`
- artifact size: `640793320`
- artifact sha256: `335b9658561baed91d2770a1d160542705bc730fbfde513347ead2189fad3ff3`
- cargo target dir: `<codex-chat-validation-build-root>/chat-backend`
- `codex --version` exit code: `0`
- `codex --version` stdout: `codex-cli 0.0.0`

## Boundary

This runner did not read or modify PhotoSorter, Xcode projects, MLX
vendor paths, or any app package graph.

## Limits

- normal CLI session parity
- app-server runtime parity
- command/tool execution parity
- resume/running rejoin/fork/rollback/compaction parity
- list/search/archive/delete parity
- crash recovery parity
- complete data fidelity
- user-indistinguishability under normal Codex usage
