# `.chat` Developer Guides

Status: draft developer guidance.

These guides are the low-friction entry path for implementing `.chat`. They do
not replace the normative draft spec files; they explain the smallest useful
implementation slices and point back to the spec for exact rules.

Recommended reading order:

1. `MinimalReader.md`: open and display a `.chat` package with `read_core`.
2. `MinimalWriter.md`: create or append a valid core timeline.
3. `ProjectionGuide.md`: generate machine, UI, model-context, and audit views.
4. `CommandTimelineGuide.md`: read or write MSP command spans without executing
   commands accidentally.
5. `RuntimeJournalGuide.md`: add heavy-runtime replay, recovery, and checkpoint
   data without raising the cost for lightweight readers.

Implementation tiers:

```text
read_core
  Open manifest.json and timeline.ndjson, display known core events, preserve or
  fold unknown events, and ignore projections as source of truth.

write_core
  Write manifest.json and timeline.ndjson with stable event envelopes, seq
  ordering, and explicit loss markers.

read_command_timeline
  Display command history and stdout/stderr from canonical command events.

chat read <path>
  Register MSPChatCommandPack and expose a Markdown command projection over
  MSP standard .chat packages. JSON is opt-in with --json.

generate_projection
  Produce derived views with provenance, stale rules, and loss matrix.

runtime-journal / replay_journal
  Preserve or replay heavy runtime state while linking back to canonical events.
```

The guiding rule is simple: a lightweight implementation can stay small, but it
must not lie. If it cannot understand, preserve, or continue something, it must
fold it safely, mark degradation, or write an explicit lossy result.

## Existing Code Entry Points

The current Swift helper layer lives in:

```text
Implementations/Swift/Sources/MSPChat/
Implementations/Swift/Sources/MSPChatCommands/
Implementations/Swift/Sources/MSPAgentChatStore/
```

Use `MSPChat` for package-level reader, writer, and validation behavior. Use
`MSPChatCommands` when exposing the standard `chat read <path>` projection
command. Use `MSPAgentChatStore` only when building an agent-facing conversation
store on top of the core package layer.

The command pack is intentionally small:

```swift
try MSPChatCommandPack().registerCommands(into: registry)
```

It reads MSP `.chat` directory packages through the core reader and prints
Markdown by default so agents can consume the projection directly.

The repository also contains a product integration example in:

```text
Examples/iOS/PhotoSorter/Agent/ToolLoop/PhotoSorterChatPersistence.swift
```

That example is useful for seeing app-level persistence pressure, but it is not
required for a minimal reader and is not part of the Draft 0 validation gate.
