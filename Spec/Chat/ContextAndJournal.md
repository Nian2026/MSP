# `.chat` Context And Journal

Status: draft standard candidate.

This document defines resumable context, runtime context snapshots, compaction
checkpoints, resume degradation, runtime journals, writer durability, source
transport retention, lifecycle, fork, rollback, and crash recovery semantics.

## 1. Boundary

The `.chat` package preserves context and evidence. It does not promise that a
different runtime, model, tool set, permission policy, network state, or
filesystem can perform the same work.

Cross-software continuation means a compatible implementation can reconstruct
conversation context and evidence, assess the current environment, and continue
where feasible.

Behavioral equivalence is required only when the same implementation claims a
storage backend has been replaced by `.chat` without user-visible regression.

## 2. Runtime Context Snapshot

`runtime_context_snapshot` describes the context needed for continuation,
replay, audit, or capability assessment.

Recommended facets:

- conversation identity;
- parent or fork relation;
- runtime origin;
- instruction inventory;
- tool capability inventory;
- command capability inventory;
- history contract;
- context window root;
- current working directory;
- workspace roots;
- date and timezone;
- approval, sandbox, filesystem, and network policy;
- model and reasoning settings;
- realtime or collaboration facets;
- unknown runtime facets.

Unknown facets must be preserved by implementations that claim lossless editing.

## 3. Permission And Environment Snapshots

`permission_snapshot` and `environment_snapshot` may be standalone events or
facets of a runtime context snapshot.

They should record enough information to explain why a command/tool/action was
allowed, denied, degraded, or no longer executable.

Environment data may include process environment, shell options, shell
variables, aliases, functions, file descriptor table, current directory, stdin
state, external runner policy, device/application capability state, and touched
path set.

## 4. Resume Assessment

Before continuing an old package in a changed environment, a runtime should write
or expose `resume_capability_assessment`.

If continuation is degraded, it should write `resume_degraded`.

Degradation reasons include:

- missing document;
- missing blob;
- missing artifact;
- unsupported command;
- unsupported tool;
- permission denied;
- model unavailable;
- policy changed;
- network disabled;
- workspace changed;
- runtime capability missing.

Resume degradation is not package failure. It is an auditable statement that the
saved context was restored but the current environment differs.

## 5. Compaction Checkpoint

`durable_compaction_checkpoint` records a context replacement boundary. It must
not delete old canonical timeline events.

Required fields:

- source event range;
- source hash or fingerprint;
- replacement projection id;
- retained count;
- discarded count;
- token or size model;
- generated summary or summary ref;
- lineage id.

Recommended fields:

- retention policy id or full retention parameters;
- compaction prompt hash;
- compaction model or generator;
- side-effect-free flag;
- tools disabled flag;
- network disabled flag;
- external side effects disabled flag;
- artifact/blob refs retained or dropped.

If compaction used tools, network, or external side effects, those side effects
must be recorded in the timeline, journal, or audit projection. They must not be
hidden inside a plain summary checkpoint.

## 6. Context Window Lineage

`context_window_lineage` records how context projections, checkpoints, summaries,
and surviving timeline suffixes relate.

It should allow a runtime to answer:

- which timeline range was summarized;
- which projection replaced it for model context;
- which original events remain canonical;
- which events were retained after checkpoint;
- which events were excluded from a model-facing projection.

## 7. Runtime Journal

`journal.ndjson` is a logical append-oriented recovery and audit layer for heavy
runtimes. It is optional for lightweight readers, but required for an
implementation that declares `runtime-journal` and depends on it for replay.

Journal entries may include:

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

Journal entries that correspond to canonical timeline facts must link to
timeline `event_id`, `commit_seq`, or `log_offset`.

## 8. Writer Durability

Multi-file packages require durable ordering rules.

Required invariants:

- timeline or journal writes that define canonical facts must become durable
  before derived projections and indexes claim to include them;
- pending writes must not be dropped until durability succeeds;
- crash recovery must detect projection/index state that is ahead of canonical
  data;
- stale projection/index state must be rebuilt, ignored, or marked stale.

Writers may use append-only files, atomic rewrite, transaction logs, or another
durable strategy if the resulting package satisfies these invariants.

## 9. Active Turn Overlay

Some runtimes support rejoining a running turn. This is not pure replay.

The package model must be able to represent or link:

- active turn status;
- active turn snapshot;
- live attachment snapshot;
- subscription/rejoin boundary;
- stale path or stale package rejection;
- runtime status replay;
- token or usage replay when applicable.

Live overlays may be journal data, live-stream events, or runtime extension data,
but they must not corrupt canonical committed timeline events.

## 10. Source Transport Retention

Heavy runtimes may need to preserve raw provider/tool/runtime items for lossless
replay. This belongs in `source_transport`, journal entries, or extension data.

Source transport retention must be linked to standard timeline events when it
explains messages, tools, commands, outputs, or errors.

Source transport retention is not a substitute for canonical timeline semantics.

## 11. Fork

`conversation_fork` records that a new package or conversation branch was derived
from an existing timeline boundary.

Recommended fields:

- source package id;
- source event id or seq boundary;
- source fingerprint;
- new package id;
- fork reason;
- materialization mode;
- copied-history fingerprint.

Fork must not mutate the source package's canonical history.

## 12. Rollback

`timeline_rollback` records that later replay should ignore or supersede a
timeline segment. It must not physically delete canonical events.

Recommended fields:

- rollback id;
- affected event range;
- affected turn ids;
- reason;
- created by;
- resulting replay boundary.

Validators must be able to distinguish rollback markers from deleted history.

## 13. Lifecycle And Cold History

Conversation lifecycle may include archive, unarchive, delete, compress, restore,
repair, or move operations. These operations may affect filesystem layout,
indexes, or history representation.

Lifecycle records should explain:

- operation;
- previous representation;
- new representation;
- affected indexes;
- stale path repair;
- transparent read behavior;
- materialize-before-append behavior;
- delete-both-representations behavior when multiple physical forms exist.

Lifecycle events are not ordinary status labels when they affect discoverability,
history loading, or replay.
