# `.chat` Conformance

Status: draft standard candidate.

This document defines conformance levels, validator requirements, required sample
packages, reports, and evidence requirements for lightweight readers, writers,
projection generators, command timelines, runtime journals, and source-level
backend validation.

## 1. Conformance Principle

A claim is conforming only when it is proven by current package data, validator
output, UI behavior where applicable, and reproducible reports. Intent,
documentation alone, or partial happy-path tests are not enough.

## 2. Conformance Classes

Standard classes:

- reader conformance;
- writer conformance;
- lossless-edit conformance;
- projection conformance;
- command-timeline conformance;
- command-execution conformance;
- journal-replay conformance;
- lightweight UI conformance;
- backend parity conformance.

An implementation should report exactly which classes, profiles, and
capabilities it claims.

## 3. Reader Conformance

A `read_core` reader must:

- read `manifest.json`;
- read `timeline.ndjson`;
- validate event envelope basics;
- render known core events in `seq` order;
- preserve or safely fold unknown events;
- display loss, redaction, truncation, missing, and external-only markers;
- avoid treating projections as canonical truth.

Acceptance: a new developer can implement this class without understanding
runtime journal, command execution, or backend replay.

## 4. Writer Conformance

A `write_core` writer must:

- write valid manifest fields;
- write valid event envelopes;
- maintain stable `seq`;
- append or rewrite without silently dropping canonical events;
- mark lossy saves;
- preserve unknown data when claiming preservation capabilities.

## 5. Lossless-Edit Conformance

An implementation claiming `lossless_edit` must preserve:

- unknown manifest fields;
- unknown timeline events;
- unknown event fields;
- unknown projection records;
- unknown journal entries;
- unknown artifact/blob metadata;
- unknown extension directories when practical.

If preservation is impossible, the output must be explicitly marked lossy.

## 6. Projection Conformance

Projection validators must check:

- projection provenance;
- source event range;
- source event ids;
- source fingerprint;
- stale conditions;
- loss matrix;
- machine-readable projection availability;
- Markdown projection not being the only machine path;
- cursor self-description or complete continuation command;
- model-context synthetic replay markers;
- call/output balance policy;
- projection truncation not modifying canonical data.

## 7. Command-Timeline Conformance

Command validators must check:

- command call/output/complete ordering;
- command id and call id pairing;
- raw command, parsed command, expanded invocation, and executed stage separation;
- pipeline stage ordering;
- skipped `&&` and `||` stages;
- pipefail behavior;
- negation behavior;
- final exit formula;
- stdout/stderr stream order;
- raw output vs model projection vs source transport separation;
- policy decision linkage;
- artifact refs;
- unsupported command errors.

## 8. Command-Execution Conformance

An implementation claiming `execute_msp_commands` must:

- declare supported command dialect/profile;
- declare command packs;
- declare external runner policy;
- execute only within declared capability and policy;
- write standard command timeline events;
- write unsupported-command errors instead of pretending execution happened;
- preserve command evidence and artifacts.

## 9. Journal-Replay Conformance

An implementation claiming `runtime-journal` or `replay_journal` must prove:

- journal entries link to timeline events or durable ordering markers;
- writer barriers are respected;
- pending write retry does not drop durable data;
- state snapshots and patches replay in order;
- compaction checkpoints define a valid replay baseline;
- rollback markers affect replay without deleting history;
- fork records preserve source history;
- lifecycle and cold-history transitions remain discoverable;
- stale projections and indexes are repaired, ignored, or marked stale.

## 10. Lightweight UI Conformance

A lightweight demo must be tested through UI automation, not only data
structure tests.

The UI tests must prove:

- user messages, assistant messages, intermediate replies, tool calls, tool
  outputs, MSP command calls, stdout, stderr, errors, artifacts, and final
  answers appear in true timeline order;
- tool calls are not grouped into one unrelated block;
- assistant messages are not grouped into one unrelated block;
- stdout and stderr are not swapped or misplaced;
- intermediate replies are visible or explicitly represented;
- artifact and attachment references render;
- unknown events fold or display without data loss;
- projection truncation does not look like canonical data truncation;
- mobile and desktop viewports have no overlap, overflow, or ordering breakage.

The UI test run must leave screenshots or a reviewable report.

## 11. Backend Parity Conformance

Source-level backend validation must prove that a heavy runtime can replace its
native storage backend with `.chat` without user-visible regression.

The validation package must preserve:

- original source snapshot;
- adapted source snapshot;
- common upstream commit;
- licenses and modification notes;
- build scripts;
- run scripts;
- parity fixtures;
- test results;
- user-visible behavior report;
- data fidelity report.

The original backend and `.chat` backend must be compared on the same inputs.

Required parity matrix:

- create thread;
- normal conversation;
- command execution;
- tool call;
- streaming output;
- stop / interrupt;
- resume;
- running thread rejoin;
- fork;
- rollback;
- compaction;
- context restore;
- list;
- search;
- archive / unarchive;
- cold history;
- crash recovery;
- metadata repair;
- permission / environment snapshot;
- token usage;
- goal / runtime status;
- error handling.

Acceptance:

```text
original backend behavior == .chat backend behavior
```

A normal user who does not inspect source code or disk layout must not be able to
distinguish the backend from output, command behavior, resume, fork, rollback,
search, list, archive, crash recovery, context continuity, error recovery,
permission prompts, obvious performance regression, or data loss.

## 12. Data Fidelity Report

Backend parity requires a data fidelity report mapping every persisted source
concept into `.chat` layers.

The report must cover at least:

- response items;
- event messages;
- command history;
- tool history;
- stdout / stderr / exit status;
- turn context;
- permission snapshot;
- environment snapshot;
- runtime state / world state;
- source transport;
- token usage;
- goal snapshot;
- compaction replacement history;
- rollback marker;
- fork metadata;
- thread metadata;
- indexes;
- archive state;
- cold history;
- crash recovery data.

Each item must identify whether it maps to timeline, projection, journal, index,
artifact/blob, extension data, or an explicitly lossy marker.

## 13. Required Sample Packages

The validator suite must include good and bad samples for:

- pure chat;
- assistant progress plus final answer;
- command call plus stdout/stderr plus final answer;
- command parse error;
- permission denied;
- non-zero exit code;
- long output plus projection truncation;
- artifact/blob reference;
- stale projection or index;
- unknown event preservation;
- lossy import marker;
- scope-bound cursor failure;
- Markdown-only projection failure;
- orphan tool output;
- inserted aborted output;
- synthetic replay call;
- missing artifact/blob;
- redacted artifact/blob;
- mismatched artifact/blob hash or unsafe package path;
- `&&` / `||` skipped stage;
- pipefail plus negation;
- stdout/stderr raw chunk order;
- compaction checkpoint missing source range/hash;
- continuation handle invalidated;
- fork package missing source package;
- cold history materialize-before-append.

Good samples must pass. Bad samples must fail with specific diagnostics.

## 14. Conformance Report

Validator output must be reviewable by humans and machines. A report should
include:

- package path;
- validator version;
- checked profiles;
- checked capabilities;
- passed checks;
- failed checks;
- warnings;
- stale projection/index notes;
- loss matrix summary;
- artifact/blob summary;
- unknown-data preservation summary.

Reports should be kept with fixtures and results for reproducibility.
