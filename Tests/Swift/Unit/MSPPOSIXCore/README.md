# MSPPOSIXCore Unit Tests

These tests target individual POSIX command implementations and the command
pack registry. They should avoid pulling in the full `ModelShellProxy` facade
unless the behavior truly depends on integration with the shell runtime.

Directory map:

- `Registry`: command-pack registration and command availability.
- `Commands/Filesystem`: filesystem mutation and metadata commands.
- `Commands/Path`: path-normalization and path-reporting commands.
- `Commands/ShellBuiltins`: shell built-ins that mutate or inspect shell state.
- `Commands/Data`: byte, checksum, encoding, and binary stream commands.
- `Commands/Text`: text filters, record streams, layout, and language tools.
- `Commands/ComparisonMetadata`: comparison and metadata oracle units.
- `Commands/Core100Expansion`: Core100 expansion commands that span multiple
  command families.
- `Performance/Streaming`: streaming, early-close, cancellation, and
  large-input behavior.

If a test needs pipelines, redirection, workspace mounting, or agent-visible
output, move it to `Tests/Swift/Integration/ModelShellProxy`.
