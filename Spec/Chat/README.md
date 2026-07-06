# MSP `.chat` Files

`.chat` is the proposed MSP file standard for agent conversations.

Status: Draft 0 preview. The core package model, developer entry path,
validator slice, and lightweight UI demo exist, but this is not a frozen v1
standard and does not claim complete heavy-runtime backend parity.

It is not a plain chat export, a UI transcript, or a JSON dump from one runtime.
A `.chat` package is meant to be a portable record of agent work: user intent,
assistant output, command and tool activity, intermediate progress, outputs,
errors, attachments, evidence, resumable context, and optional runtime history.

The minimum promise is compatibility: a conforming application should be able to
open a `.chat` package and display the core conversation faithfully.

That is only the floor. The larger goal is to make agent conversations
first-class workspace files, similar in importance to `.md`, `.pdf`, `.ipynb`,
or `.html`. A conversation should not be trapped inside one app, one database,
one model provider, or one runtime. It should be movable, inspectable,
searchable, auditable, replayable, continuable, trainable, and composable with
commands.

In MSP terms:

```text
Data as files.
Actions as commands.
Permissions as policy.
Execution as evidence.
```

`.chat` extends that model to the conversation itself: agent work becomes data,
and that data can be operated on by commands.

## Current Status

This folder is in Draft 0 stage-close work. Start with
`CurrentStatus.md` for the current acceptance boundary, runnable checks,
retained evidence, and known gaps.

The first product-neutral spec split now exists.

The public-facing draft spec files are:

- `CorePackage.md`: package, manifest, profiles, capabilities, source-of-truth
  rules, preservation, artifacts, blobs, and indexes.
- `TimelineEvents.md`: canonical event envelope, ordering, durability classes,
  core events, agent events, and control events.
- `CommandTimeline.md`: MSP command spans, parser/expansion/stage semantics,
  output layering, policy, command origins, and source transport.
- `Projections.md`: machine, Markdown, UI, model-context, and audit projection
  semantics.
- `ContextAndJournal.md`: runtime context, checkpoints, resume degradation,
  journal, writer durability, lifecycle, fork, rollback, and cold history.
- `Conformance.md`: conformance classes, validator requirements, sample
  packages, UI tests, backend parity, and data fidelity reports.

Developer entry guides now exist under `Guides/`:

- `Guides/MinimalReader.md`: implement `read_core` and display a canonical
  timeline without understanding heavy runtime data.
- `Guides/MinimalWriter.md`: create or append a valid core `.chat` package.
- `Guides/ProjectionGuide.md`: generate machine, Markdown, UI, model-context,
  and audit projections without treating them as canonical history.
- `Guides/CommandTimelineGuide.md`: read and write MSP command spans while
  keeping command history separate from command execution.
- `Guides/RuntimeJournalGuide.md`: add heavy-runtime recovery, replay, and
  checkpoint data without raising the cost for lightweight readers.

The first runnable validator slice now exists:

- `Implementations/Swift/Sources/MSPChat/`: Swift validator library plus a
  minimal core reader/writer helper.
- `Implementations/Swift/Sources/MSPChatValidatorCLI/`: `msp-chat-validate`
  command-line validator.
- `Spec/Chat/Samples/`: first good/bad `.chat` package fixtures.
- `Spec/Chat/Validation/`: current validation evidence and gaps.
- `Spec/Chat/Demos/LightweightReader/`: a lightweight web reader/writer demo
  with UI automation screenshots.
- `Conformance/Chat/CodexCliValidation/`: source-backed Codex CLI/backend
  parity evidence for heavier runtime behavior.

This validator is not the final conformance suite. It is the first executable
shape for checking package structure, manifest declarations, timeline ordering,
event envelopes, command/tool ordering, command exit formulas, projection
provenance, artifact references, journal linkage, and context-control events.

Local construction notes are intentionally ignored by Git and are not part of the public spec or publishable repository surface.

This README should stay high-level and should not duplicate event tables that
belong in the spec files.

## Developer Start

Developers do not need to implement the full runtime model first.

The smallest useful implementation is:

```text
read_core + core-timeline
```

That means:

- read `manifest.json`;
- read canonical `timeline.ndjson`;
- display events in `seq` order;
- render known core events;
- preserve or safely fold unknown events;
- treat projections, journals, and indexes as non-canonical support layers.

Recommended path:

1. Read `Guides/MinimalReader.md`.
2. Validate `Spec/Chat/Samples/good/pure-chat.chat`.
3. Add `Guides/MinimalWriter.md` when writing packages.
4. Add `Guides/CommandTimelineGuide.md` when displaying command history.
5. Add `Guides/ProjectionGuide.md` and `Guides/RuntimeJournalGuide.md` only
   when the product needs those layers.

Runnable implementation pieces:

- `Implementations/Swift/Sources/MSPChat/`: validator and minimal core helper.
- `Implementations/Swift/Sources/MSPChatCommands/`: `chat read <path>` command
  pack for Readex-style Markdown projection over MSP `.chat` packages.
- `Implementations/Swift/Sources/MSPAgentChatStore/`: agent chat store helper
  built on the core package layer.
- `Spec/Chat/Demos/LightweightReader/`: browser reader/writer demo with UI
  conformance screenshots.

An app-level integration example exists under
`Examples/iOS/PhotoSorter/Agent/ToolLoop/PhotoSorterChatPersistence.swift`. It
is useful for understanding product integration, but it is not required for a
minimal `.chat` reader and is not part of the Draft 0 validation gate.

## Core Promise

The canonical `.chat` record is an ordered agent conversation timeline.

User messages, assistant messages, intermediate assistant progress, command
calls, command outputs, tool calls, tool outputs, errors, attachments, context
control events, and runtime-relevant status must be preserved in the order they
actually occurred.

The canonical format must not collapse the conversation into separate buckets:

```text
messages[]
tool_calls[]
command_outputs[]
assistant_messages[]
```

Those views are useful as indexes or projections, but they are not the source of
truth. Real agent work is interleaved:

```text
user message
assistant progress
command call
stdout chunk
assistant progress
command completed
tool call
tool output
final answer
```

Faithful timeline preservation is what lets lightweight readers render the
conversation correctly and lets heavier runtimes recover the actual execution
path.

The standard command-level projection is:

```text
chat read <path>
```

It reads an MSP `.chat` package path and prints model-friendly Markdown by
default. Programmatic JSON projection is opt-in with `--json`; it is not the
default reader experience.

## Package Shape

The first validation target is a directory package. A single-file container can
be evaluated later.

The directory package is a storage shape, not something the model or ordinary
workspace UI has to understand. MSP-compatible workspace file systems should
present `<name>.chat` as a file path, hide package internals from normal
directory traversal, and route conversation reads through `chat read <path>` or
an equivalent projection API.

`<name>.chat/` means any conforming `.chat` conversation package. `<name>` is
the user- or application-provided conversation file name.

```text
<name>.chat/
  manifest.json
  timeline.ndjson
  projections/
    chat-read.ndjson
    model-context.ndjson
    audit.ndjson
  journal.ndjson
  artifacts/
  blobs/
  indexes/
```

The source-of-truth relation is:

- `timeline.ndjson` is the canonical ordered timeline.
- `projections/` contains rebuildable or explicitly materialized views.
- `journal.ndjson` is an optional heavy-runtime recovery and audit layer.
- `artifacts/` and `blobs/` hold structured evidence and large objects.
- `indexes/` are derived acceleration data and must be rebuildable.

All standard file names, field names, and event names must use product-neutral
semantics. The standard core must not contain fields named after a specific app,
runtime, model provider, or implementation.

## Capability Model

The standard should be easy to adopt in layers. Developers should not have to
understand every runtime field before they can read or write a useful `.chat`
package.

Data profiles describe what kind of data exists:

```text
core-timeline
agent-timeline
command-timeline
projection-cache
resumable-context
runtime-journal
```

Capability flags describe what an implementation can do:

```text
read_core
write_core
read_command_timeline
write_command_timeline
execute_msp_commands
generate_projection
replay_journal
lossless_edit
preserve_unknown_events
```

This separation matters. A lightweight reader may display command history
without executing commands. An MSP-capable runtime can additionally execute MSP
commands and append the resulting events back into the same standard timeline.

## Projections

Agents should not have to read raw package internals directly. `.chat` needs
standard projection semantics.

Important projections include:

- `chat-read.machine`: machine-readable projection for agents and CLIs.
- `chat-read.markdown`: human-readable Markdown projection.
- `model-context`: resumable context projection for continuing a conversation.
- `audit`: evidence, command, permission, error, and loss-summary projection.

Every materialized projection must declare provenance: source event range,
source fingerprint, generator, generated time, lossiness, redaction, truncation,
and stale conditions.

Cursor values must be self-describing, or the projection must return a complete
continuation command. A cursor must not depend on the caller remembering hidden
scope.

## Commands

MSP commands are not just tool calls named `shell`.

A command timeline has to describe a shell-like runtime span: raw command text,
parse result, expansion, cwd, stdin, stdout, stderr, pipeline stages, skipped
stages, exit status, pipefail behavior, state changes, artifacts, and policy
decisions.

MSP-native Linux-like commands and app-specific commands can be composed through
the same command model. App-specific commands should declare their input,
output, artifact, side-effect, and permission contracts so they can participate
in pipes, redirection, exit-code logic, and evidence tracking.

Transport details from model providers, tool calls, or MCP can be preserved as
source transport metadata, but the canonical command semantics should be
normalized into the command timeline.

## Preservation

Implementations may choose how much data to store.

Lightweight applications may write only core chat or agent timeline data.
Heavier runtimes may write context, checkpoints, journal entries, indexes, and
artifacts. Both are valid if the manifest states the supported profiles and
capabilities clearly.

The standard should prevent silent destruction:

- Lossless edits should preserve unknown data where possible.
- Lossy exports must be explicitly marked.
- Indexes and projections must be rebuildable from canonical data.
- Projection truncation must not overwrite canonical command output.
- Unsupported advanced data must not be confused with core timeline semantics.

## Continuation

`.chat` should let another compatible application recover the conversation
context and continue useful work from the saved record.

The file preserves the context and evidence. The runtime decides whether the
current environment still has the files, permissions, models, commands, network,
and platform capabilities needed to continue the original task.

If continuation is degraded, the runtime should record that assessment instead
of pretending the old environment still exists.

## Validation Strategy

The standard must be proven from both ends.

First, a lightweight reader demo should prove that `.chat` can be opened,
rendered, searched, exported, continued, and saved without implementing a heavy
runtime.

Second, a full agent runtime should be adapted at the source-code level so that
its storage backend can use `.chat` while preserving existing behavior. Users
should not be able to tell, from the product experience alone, whether the
backend is using the old storage implementation or the `.chat` backend.

The hard requirement is behavioral equivalence: no persisted data needed for
resume, running rejoin, fork, rollback, compaction, context restore,
command/tool history, runtime journal, crash recovery, audit, list/search,
archived history, metadata repair, lifecycle handling, or cold-history handling
can be lost.

That is the point of `.chat`: not just to remember what an agent said, but to
preserve what an agent did, why it did it, and what evidence it used.
