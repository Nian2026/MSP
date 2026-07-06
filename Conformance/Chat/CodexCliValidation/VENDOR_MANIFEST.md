# Codex CLI Vendor Manifest

This directory preserves a restorable source-level validation baseline for
checking whether a Codex CLI-shaped runtime can use a `.chat` backend without
user-visible regression.

## Source

- Upstream repository: `https://github.com/openai/codex.git`
- Upstream default branch at fetch time: `main`
- Pinned upstream commit: `80f54d1266b4571ef649e7e5ecc382dd4e670937`
- Commit subject: `[codex] Treat max as a first-class reasoning effort (#30467)`
- Fetch date: `2026-06-30`
- License observed in vendored source: Apache License 2.0

## Restored Snapshots

```text
source-snapshots/
  openai-codex-original/
  openai-codex-chat-backend/
```

`source-snapshots/` is local generated material. It is restored from the pinned
upstream commit plus the tracked `.chat` backend patch by:

```sh
python3 Conformance/Chat/CodexCliValidation/scripts/restore_source_snapshots.py
```

`openai-codex-original/`

- Role: unmodified upstream baseline for parity testing.
- Required state: commit `80f54d1266b4571ef649e7e5ecc382dd4e670937`.
- Mutation rule: do not edit generated source files here.

`openai-codex-chat-backend/`

- Role: adapted source tree for `.chat` backend experiments.
- Base commit: `80f54d1266b4571ef649e7e5ecc382dd4e670937`.
- Patch: `patches/chat-backend-minimal-thread-store-2026-07-03.patch`.

Both snapshots are generated as exported source trees from the pinned upstream
commit. They do not preserve nested `.git` directories. Source identity is
preserved by this manifest, the pinned commit, upstream license files in the
restored trees, the tracked restoration script, and the adaptation patch.

## Public Evidence Boundary

The public evidence surface is defined in:

```text
PUBLIC_EVIDENCE.md
```

The open-source repository keeps reproducible inputs, scripts, tests, and the
current phase-close evidence. It does not publish every local rerun log or
historical recovery note. Local human-readable reports live under `reports/`
and are ignored by default.

## Current Phase-Close Evidence

Current retained machine-readable evidence lives under `phase-results/`:

```text
phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json
phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json
```

Only the first three summaries are accepted source/build/runtime-slice evidence
for this phase-close boundary. The inventory summary is accepted as evidence
that the public evidence index references present retained artifacts. The public
evidence index also keeps human-readable `report.md` companions for the CLI build
and running-rejoin slices; those reports are not counted as machine-readable
parity results.

## Evidence Requirements

Final parity work must eventually preserve:

- original Codex CLI source identity;
- `.chat` backend adaptation patch or equivalent source diff;
- build scripts for both source trees;
- parity test fixtures;
- machine-readable parity results;
- user-visible behavior comparison reports;
- persistence and data-loss comparison reports.

The adapted Codex CLI is accepted only if ordinary users cannot distinguish the
original backend from the `.chat` backend through normal CLI usage.

## License Duties

The upstream source is licensed under Apache License 2.0. Any public release of
this validation package must preserve upstream license notices and clearly mark
local modifications to the adapted tree.

Do not remove upstream `LICENSE` files from restored snapshots.

## Non-Claims

The current retained phase-close evidence is intentionally narrow. It does not
prove final app-server parity, CLI/TUI parity, complete crash recovery, complete
data fidelity, or final user-indistinguishability.
