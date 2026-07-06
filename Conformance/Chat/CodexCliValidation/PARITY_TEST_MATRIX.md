# Codex CLI Parity Test Matrix

This is a retained backend-validation document for checking whether the adapted
Codex CLI source tree can use a `.chat` backend without user-visible regression
or persisted data loss.

It is not part of the public `.chat` standard, and it is not final parity proof.

## Test Principle

Every parity case runs against both restored source trees from the same pinned
upstream commit:

```text
source-snapshots/openai-codex-original/
source-snapshots/openai-codex-chat-backend/
```

The original tree remains unmodified. The adapted tree may contain only the
tracked `.chat` backend adaptation.

Restore the snapshots with:

```sh
python3 Conformance/Chat/CodexCliValidation/scripts/restore_source_snapshots.py
```

## Public Evidence Boundary

The public evidence surface is defined in:

```text
PUBLIC_EVIDENCE.md
```

The current open-source surface keeps scripts, tests, the adaptation patch, and
bounded `phase-results/` evidence. Local `reports/` and full `results/`
directories are generated or historical validation notes unless a future
release explicitly promotes an artifact into `PUBLIC_EVIDENCE.md`.

Current retained machine-readable Draft 0 evidence:

```text
phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json
phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json
phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json
phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json
```

Only the first three are accepted behavior/source evidence for this
phase-close slice. The inventory summary proves that the public evidence index
does not point at missing machine-readable artifacts.

Run the current public evidence inventory with:

```sh
python3 Conformance/Chat/CodexCliValidation/tests/evidence_artifact_inventory.py \
  --json-output Conformance/Chat/CodexCliValidation/phase-results/evidence-artifact-inventory-2026-07-03-phase-close/summary.json \
  --strict
```

Use `--scan-all-docs` only for local diagnostics over historical Markdown.

## Final Parity Requirements

Final parity must compare:

- user-visible output;
- API and JSON-RPC response shape where applicable;
- command/tool call timeline behavior;
- resume, fork, rollback, list, search, archive, and delete behavior;
- persisted data needed for future operations;
- crash and recovery behavior;
- mapping from original backend concepts to `.chat` layers.

Disk layout may differ, but normal CLI usage must not reveal a behavioral
difference.

## Current Accepted Slice

The current Draft 0 retained evidence is intentionally narrow:

| Slice | Current evidence | Claim |
|---|---|---|
| Source identity | `phase-results/source-snapshot-integrity-2026-07-03-phase-close/summary.json` | Restored source snapshots match the pinned source/patch boundary. |
| CLI build metadata | `phase-results/cli-build-source-snapshots-2026-07-03-phase-close/summary.json` | Both source trees build the CLI entry point and expose matching version/help metadata. |
| Running rejoin app-server smoke | `phase-results/app-server-running-rejoin-smoke-2026-07-03-phase-close/summary.json` | One source-backed app-server running-rejoin slice matches normalized behavior. |

These slices do not prove full app-server behavior, full CLI/TUI behavior,
complete crash recovery, complete data fidelity, or final
user-indistinguishability.

## Matrix

| ID | Area | Required final equivalence |
|---|---|---|
| B01 | Build original CLI | Original source builds from the pinned commit without local modifications. |
| B02 | Build adapted CLI | Adapted source builds after applying only the `.chat` backend patch. |
| B03 | Source identity | Original and adapted source identity, license files, and adaptation diff are reproducible. |
| C01 | Thread creation | New thread/session creation, first read, and metadata match. |
| C02 | Basic conversation | User-visible transcript and persisted replay history match. |
| C03 | Multi-turn conversation | Resume context and future response context match across turns. |
| T01 | Command success | Command call, stdout, stderr, exit status, and visible output match. |
| T02 | Command failure | Non-zero command semantics and persisted history match. |
| T03 | Streaming command output | Visible streaming order and durable replay facts match. |
| T04 | Tool calls | Tool call/output history, ids, and visible transcript match. |
| T05 | Dynamic tools | Dynamic tool transport is retained enough for replay and UI parity. |
| T06 | Approval events | Prompt, decision, persistence, and resume state match. |
| T07 | Artifacts | Artifact references, display, export, and replay behavior match. |
| R01 | Cold resume | History, context, metadata, token usage, and goal snapshot match. |
| R02 | Explicit resume path | Accepted/rejected behavior and visible result match. |
| R03 | Running rejoin | Active turn overlay, listener attach, and final replay match. |
| R04 | Stale path rejection | Error class and duplicate-thread prevention match. |
| R05 | Override mismatch | Warning, shutdown, or ignore behavior matches. |
| F01 | Fork | Fork metadata, parent/child relation, and future context match. |
| RB01 | Rollback one turn | Visible history and future model context exclude rolled-back turns. |
| RB02 | Rollback many turns | Cumulative rollback behavior and durable markers match. |
| RB03 | Rollback after compaction | Compaction replacement history and rollback baseline match. |
| L01 | List | Active/archived list semantics and pagination match. |
| L02 | Relations | Parent/child/ancestor relation filters and lifecycle visibility match. |
| L03 | Search | Search result ordering, snippets, and pagination match. |
| L04 | Archive/unarchive | Lifecycle state, notifications, and future list/search behavior match. |
| L05 | Delete | Deletion semantics, missing read errors, and relation cleanup match. |
| H01 | Cold storage | Cold package discovery and materialization behavior match. |
| H02 | Crash recovery | Partial write, stale projection, and repair behavior match. |
| H03 | Data fidelity | `.chat` timeline, journal, artifacts, blobs, and indexes preserve required facts. |

## Final Evidence Shape

A final parity closure must regenerate a complete `results/` package and promote
the accepted machine-readable artifacts into `PUBLIC_EVIDENCE.md`. Until that
happens, historical local reports are useful investigation notes, not public
proof.
