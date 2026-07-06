# `.chat` Runtime Journal Guide

Status: draft advanced developer guidance.

Goal: add heavy-runtime recovery, replay, and checkpoint data without making
lightweight readers understand heavy runtime internals.

## When To Use Runtime Journal

Do not declare `runtime-journal` for ordinary chat export.

Use it when the implementation needs replay, fork, rollback, crash recovery,
active turn rejoin, source transport retention, state snapshots, or lifecycle
repair.

A package can be valid without `journal.ndjson`. If the manifest declares
`runtime-journal`, the journal must exist and link back to timeline events or
durable ordering markers.

## Source Of Truth

`timeline.ndjson` remains the portable canonical timeline.

`journal.ndjson` may contain heavy details, but it must not hide conversation
facts needed by a lightweight reader. If a fact affects portable display,
audit, migration, or continuation, put a standard event in the timeline and link
journal detail to it.

## Journal Links

Each journal entry should link through one or more of:

- `timeline_event_id`;
- `event_id`;
- `commit_seq`;
- `log_offset`.

This link lets validators and repair tools detect whether journal data is ahead
of or behind canonical timeline data.

## What Belongs In Journal

Typical journal data:

- session or conversation metadata;
- writer state;
- pending write retry state;
- durable barriers;
- runtime state snapshots;
- runtime state patches;
- active turn overlay;
- live attachment snapshot;
- source transport retention;
- replay markers;
- crash repair records;
- lifecycle filesystem operations;
- retention and redaction policy.

Unknown runtime-specific state should be namespaced and preserved by lossless
editors.

## Writer Durability

For multi-file packages:

1. Make canonical timeline or journal writes durable before derived projections
   and indexes claim to include them.
2. Keep pending writes until durability succeeds.
3. Mark or rebuild projections and indexes after crashes if they are ahead of
   canonical data.
4. Use `commit_seq`, `log_offset`, or an equivalent marker to explain package
   write order.

The standard allows append-only files, atomic rewrites, or transaction logs as
long as the package-level invariants hold.

## Replay Controls

Replay-capable packages should preserve:

- runtime context snapshots;
- state snapshots and patches;
- durable compaction checkpoints;
- context window lineage;
- fork records;
- rollback markers;
- resume capability assessments;
- lifecycle and cold-history transitions.

Rollback must be represented by control events, not physical deletion of
canonical history. Compaction checkpoints must record source range, fingerprint,
replacement projection id, retained/discarded counts, and the policy used to
generate the replacement.

## Active Turns

Running turn rejoin is not pure replay. If supported, preserve or link:

- active turn status;
- active turn snapshot;
- live attachment snapshot;
- subscription or rejoin boundary;
- stale package rejection;
- runtime status replay;
- usage replay when applicable.

This data may live in journal entries or live-stream events, but it must not
corrupt committed canonical timeline events.

## Acceptance

A runtime journal implementation is acceptable when it can prove journal linkage,
writer durability, pending retry safety, state replay, compaction baseline,
rollback without deletion, fork source preservation, lifecycle discoverability,
and stale projection/index repair.
