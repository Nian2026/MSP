# Codex CLI Validation Public Evidence Surface

This directory contains source-backed validation machinery for the `.chat`
backend experiments. The open-source surface is intentionally smaller than the
local validation workspace: it keeps reproducible inputs, scripts, tests, and
the current phase-close evidence, while treating long-form rerun reports as
local generated notes.

## Public Boundary

Keep these files in the public repository surface:

- `VENDOR_MANIFEST.md`
- `BASELINE_CHECKS.md`
- `CODEX_BACKEND_MAPPING.md`
- `PARITY_TEST_MATRIX.md`
- `PUBLIC_EVIDENCE.md`
- `patches/chat-backend-minimal-thread-store-2026-07-03.patch`
- `scripts/restore_source_snapshots.py`
- `tests/`
- `fixtures/gate-input/codex-validation-gate-note.txt`
- `phase-results/`

Keep these paths local or generated:

- `source-snapshots/`
- `upstream/`
- `instrumented-work/`
- `results/`
- `reports/`

The local `reports/` directory may contain useful rerun notes, recovery notes,
or large historical audits. Those notes are not the public evidence boundary
unless a future release explicitly promotes a report into this file.

## Current Phase-Close Evidence

The current retained Draft 0 evidence surface is:

```text
phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json
phase-results/cli-build-source-snapshots-2026-07-03-phase-close/report.md
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/report.md
phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json
```

The JSON summaries are the retained machine-readable evidence for this phase
close. The `report.md` files are retained human-readable companions for the CLI
build and running-rejoin slices. The inventory summary proves that the public
evidence index does not point at missing retained artifacts.

Only the files listed above are part of the retained public evidence set. Raw
per-tree response streams and rerun-only inventories are local diagnostics.

## Current Non-Claims

This evidence does not claim complete Codex CLI parity. It does not close full
resume/fork/rollback/search/archive behavior, full crash recovery, full
data-fidelity mapping, CLI/TUI user-indistinguishability, or final `.chat` v1
compatibility.

## Regeneration

Restore source snapshots locally before running source-backed checks:

```sh
python3 Conformance/Chat/CodexCliValidation/scripts/restore_source_snapshots.py
```

Run the inventory against the public evidence boundary:

```sh
python3 Conformance/Chat/CodexCliValidation/tests/evidence_artifact_inventory.py \
  --json-output Conformance/Chat/CodexCliValidation/phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json \
  --strict
```

Use `--scan-all-docs` only for local diagnostics over historical Markdown.
