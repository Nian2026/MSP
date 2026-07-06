# Codex CLI Baseline Checks

Date: `2026-06-30`

## Commit Identity

Both source snapshots are pinned to:

```text
80f54d1266b4571ef649e7e5ecc382dd4e670937
[codex] Treat max as a first-class reasoning effort (#30467)
2026-06-29 09:38:49 -0700
```

## Snapshot Roles

```text
source-snapshots/openai-codex-original
  baseline source tree; must remain unmodified

source-snapshots/openai-codex-chat-backend
  adaptation source tree; initial branch is chat-backend-adaptation
```

## Clean Working Trees

At baseline creation:

- `openai-codex-original` had no local source changes.
- `openai-codex-chat-backend` had no local source changes.

## Content Equality

The following check produced no differences:

```text
diff -qr --exclude=.git \
  source-snapshots/openai-codex-original \
  source-snapshots/openai-codex-chat-backend
```

This means the two source snapshots were content-identical at baseline creation,
excluding Git metadata. Future differences should come only from `.chat` backend
adaptation work in `openai-codex-chat-backend`.

## Current Source Snapshot Integrity

Date: `2026-07-03`

The current local generated source-evidence path is:

```text
source-snapshots/openai-codex-original
source-snapshots/openai-codex-chat-backend
```

Restore it before running source-backed checks:

```text
python3 Conformance/Chat/CodexCliValidation/scripts/restore_source_snapshots.py
```

The current integrity verifier is:

```text
Conformance/Chat/CodexCliValidation/tests/source_snapshot_integrity.py
```

Latest command:

```text
python3 Conformance/Chat/CodexCliValidation/tests/source_snapshot_integrity.py \
  --upstream-repo $CODEX_UPSTREAM_REPO \
  --json-output Conformance/Chat/CodexCliValidation/phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
```

Latest result:

```text
status: pass
failed_check_count: 0
```

Current source-entry counts:

```text
openai-codex-original: 5313
openai-codex-chat-backend: 5314
```

These counts follow git tree/source-entry semantics and include the upstream
tracked symlink:

```text
codex-rs/vendor/bubblewrap/LICENSE -> COPYING
```

Current original-vs-adapted differences are expected only in:

```text
codex-rs/config/src/config_toml.rs
codex-rs/core/src/config/config_tests.rs
codex-rs/core/src/config/mod.rs
codex-rs/core/src/thread_manager.rs
codex-rs/core/src/thread_manager_tests.rs
codex-rs/thread-store/src/lib.rs
codex-rs/thread-store/src/chat/mod.rs
```

The verifier also checked, using the local upstream git checkout, that the
original source file list and selected sentinel file contents match pinned
commit:

```text
80f54d1266b4571ef649e7e5ecc382dd4e670937
```

Evidence:

```text
Conformance/Chat/CodexCliValidation/phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
```

## Current Patch Artifact Sync

Date: `2026-07-03`

The current adaptation patch is synchronized with the full root-path diff from
the original source snapshot to the adapted source snapshot:

```text
Conformance/Chat/CodexCliValidation/patches/chat-backend-minimal-thread-store-2026-07-03.patch
```

The root-path diff checksum and patch checksum match:

```text
177aa9a5a438c1dc40773965de8f12b281878e7164bff77e852caf19ab44c6fd
```

Public evidence:

```text
Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md
Conformance/Chat/CodexCliValidation/patches/chat-backend-minimal-thread-store-2026-07-03.patch
```

## Current Source Snapshot Build Evidence

Date: `2026-07-03`

The current build helper keeps Cargo build output outside the source snapshots
and restores the script-expected snapshot entry points:

```text
source-snapshots/openai-codex-original/codex-rs/target/debug/codex
source-snapshots/openai-codex-chat-backend/codex-rs/target/debug/codex
```

Latest command:

```text
python3 Conformance/Chat/CodexCliValidation/tests/cli_build_source_snapshots.py \
  --cargo-target-root <codex-chat-validation-build-root> \
  --build-if-missing \
  --output-dir Conformance/Chat/CodexCliValidation/phase-results/cli-build-source-snapshots-2026-07-03-phase-close \
  --report-output Conformance/Chat/CodexCliValidation/phase-results/cli-build-source-snapshots-2026-07-03-phase-close/report.md
```

Latest result:

```text
status: pass
version output equal: true
help output hash equal: true
```

Evidence:

```text
Conformance/Chat/CodexCliValidation/phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json
Conformance/Chat/CodexCliValidation/phase-results/cli-build-source-snapshots-2026-07-03-phase-close/report.md
```

## Current Evidence Inventory Boundary

Date: `2026-07-03`

Current retained phase-close machine-readable evidence is limited to:

```text
phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json
phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json
```

The phase-close inventory validates `PUBLIC_EVIDENCE.md`, which is the public
evidence boundary for this validation package. The public boundary may retain
human-readable `report.md` companions next to the machine-readable summaries, but
final parity still requires a separate complete `results/` package with
machine-readable artifacts for every accepted parity report.
