# Batch 03 Closure Draft: head, tail, paste, tee

Scope: local Batch 03 closure notes for `head`, `tail`, `paste`, and `tee`.
This draft records command-local evidence only; capture scripts, registry,
Package.swift, and shared runtime remain untouched.

## head

- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/head.c`
  - option table: `long_options`
  - help surface: `usage`
  - headers: `write_header`
  - stdout failure path: `xwrite_stdout`
  - main parser: `main`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPHeadTailCommands.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - Existing local behavior covers `-n`, `--lines`, `-c`, `--bytes`, signed counts, suffix counts, `-q`, `--quiet`, `--silent`, `-v`, `--verbose`, `-z`, multi-file headers, diagnostics for unreadable operands, and obsolete numeric forms.
  - `MSPTextInputCommandTests.testHeadAndTailHeaderSpacingStdinAndPolicyDiagnostics` covers GNU `write_header` blank-line spacing, repeated `-` stdin operands, and invalid old-form trailing-option diagnostics.
  - Tests: `MSPTextInputCommandTests.testHeadAndTailSupportGNUSelectionOptions`, `MSPTextInputCommandTests.testHeadAndTailHeaderSpacingStdinAndPolicyDiagnostics`, `MSPTextInputCommandTests.testHeadAndTailSupportHelpAndVersion`, `MSPTextStreamOracleTests.testLinuxTextStreamOracleCases`, and byte preservation coverage in `MSPTextStreamOracleTests.testByteOrientedTextCommandsPreserveNonUTF8OutputBytes`.
- Safe oracle case suggestions:
  - `head --help`
  - `head --version`
  - `head -v -n1 a b`
  - `head -z -n2` with NUL-delimited stdin
  - `head -c -2 file`
- Command-local closure disposition:
  - No local noninteractive `head` gap remains after the header/stdin/old-form diagnostic coverage.
  - Exact broken-pipe/stdout write diagnostics and exit behavior remain a cross-command pipeline policy topic matching `xwrite_stdout`.

## tail

- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tail.c`
  - option table: `long_options`
  - help surface: `usage`
  - headers: `write_header`
  - stdout failure path: `xwrite_stdout`
  - obsolete parser: `parse_obsolete_option`
  - main parser/follow setup: `main`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPHeadTailCommands.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - Existing local behavior covers `-n`, `--lines`, `-c`, `--bytes`, `+NUM` from-start selection, suffix counts, `-q`, `--quiet`, `--silent`, `-v`, `--verbose`, `-z`, multi-file headers, diagnostics for unreadable operands, and obsolete numeric forms.
  - `MSPTextInputCommandTests.testHeadAndTailHeaderSpacingStdinAndPolicyDiagnostics` covers GNU `write_header` blank-line spacing, repeated `-` stdin operands, invalid old-form numeric context diagnostics, and explicit MSP policy rejection for `-f`, `-F`, `--follow`, `--retry`, `--pid`, `--sleep-interval`, and `--max-unchanged-stats`.
  - Tests: `MSPTextInputCommandTests.testHeadAndTailSupportGNUSelectionOptions`, `MSPTextInputCommandTests.testHeadAndTailHeaderSpacingStdinAndPolicyDiagnostics`, `MSPTextInputCommandTests.testHeadAndTailSupportHelpAndVersion`, `MSPTextStreamOracleTests.testLinuxTextStreamOracleCases`, and byte preservation coverage in `MSPTextStreamOracleTests.testByteOrientedTextCommandsPreserveNonUTF8OutputBytes`.
- Safe oracle case suggestions:
  - `tail --help`
  - `tail --version`
  - `tail -v -n1 a b`
  - `tail -z -n +2` with NUL-delimited stdin
  - `tail -c +4 file`
- Command-local closure disposition:
  - No local non-follow `tail` gap remains after the header/stdin/old-form diagnostic coverage.
  - Follow-related options are intentionally disabled with policy-shaped diagnostics because GNU `tail.c` routes them into long-running file watching, process identity checks, retry, and sleep-loop behavior.
  - Exact broken-pipe/stdout write diagnostics and exit behavior remain a cross-command pipeline policy topic matching `xwrite_stdout`.

## paste

- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/paste.c`
  - delimiter escape parser: `collapse_escapes`
  - parallel merge: `paste_parallel`
  - serial merge: `paste_serial`
  - help surface: `usage`
  - main parser: `main`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPPasteCommand.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - `-d`/`--delimiters` now recognizes the GNU escape set used by `collapse_escapes`: `\0`, `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, and `\\`.
  - A delimiter list ending in an unescaped backslash now fails before input processing.
  - Empty delimiter list preserves the GNU `EMPTY_DELIM` effect for local output.
  - Eager and streaming records/delimiters are now `Data` based, preserving non-UTF-8 bytes instead of passing through replacement-character `String` decoding.
  - Streaming now uses a local delimiter-aware record reader, so `-z`/`--zero-terminated` does not fall back to eager mode.
  - Repeated `-` operands in streaming mode share one stdin reader, matching coreutils' repeated `stdin` FILE* consumption in `paste_parallel` and `paste_serial`.
  - Existing local behavior covers `-s`, `--serial`, `-z`, `--zero-terminated`, stdin `-`, repeated stdin operands, binary records, multiple files, missing-file diagnostics, and streaming for multi-file operands.
  - Tests: `MSPTextStreamOracleTests.testLinuxTextStreamOracleCases`, `MSPTextStreamOracleTests.testByteOrientedTextCommandsPreserveNonUTF8OutputBytes`, `MSPWorkerCRecordStreamCommandTests.testPasteStreamsMultipleFileOperandsThroughWorkspaceRangeReads`, `MSPWorkerCRecordStreamCommandTests.testPasteStreamsRepeatedStandardInputOperandsSequentially`, `MSPWorkerCRecordStreamCommandTests.testPasteStreamsZeroTerminatedSerialStandardInput`, `MSPWorkerCRecordStreamCommandTests.testPasteRunPreservesBinaryRecordsAndEmptyDelimiter`, and `MSPWorkerCRecordStreamCommandTests.testPasteStreamsZeroTerminatedBinaryRecords`.
- Safe oracle case suggestions:
  - `paste --help`
  - `paste --version`
  - `paste -s -d '\\b\\f\\r\\v\\\\' -`
  - `paste -d '\\' -`
  - `paste -z -s -d ',' -` with NUL-delimited stdin
- Needs shared owner action:
  - exact byte-for-byte behavior is command-local for current paste paths; a shared byte-record joiner may still be useful if other commands need the same primitive.
  - shared NUL-record streaming may still be useful for reuse by other commands, but paste now has a command-local `-z` streaming reader.

## tee

- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tee.c`
  - option table: `long_options`
  - output policy enum: `enum output_error`
  - mode parser: `XARGMATCH("--output-error", ...)`
  - help surface: `usage`
  - write loop: `main`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPTeeCommand.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - `-p` and `--output-error[=MODE]` parse locally; accepted modes are `warn`, `warn-nopipe`, `exit`, and `exit-nopipe`.
  - Invalid `--output-error=MODE` fails with exit 1 before input is copied.
  - Non-pipe file write failures diagnose and set exit 1 while default/warn modes continue to later files; `exit`/`exit-nopipe` stop later file writes.
  - Existing local behavior covers stdout copying, binary stdin to stdout/file mirror, `-a`/`--append`, `-i`/`--ignore-interrupts` as accepted no-op in the agent process, virtual `/dev/null`, `/dev/stdout`, `/dev/stderr`, file write diagnostics, and streaming chunk fanout to workspace append.
  - Tests: `MSPTextStreamOracleTests.testLinuxTextStreamOracleCases`, `MSPTextStreamOracleTests.testByteOrientedTextCommandsPreserveNonUTF8OutputBytes`, `MSPWorkerCRecordStreamCommandTests.testTeeStreamsInputToOutputChunks`, `MSPWorkerCRecordStreamCommandTests.testTeeStreamsFileTargetsThroughWorkspaceAppend`, and `MSPWorkerCRecordStreamCommandTests.testTeeAppendModeDoesNotReadExistingFile`.
- Safe oracle case suggestions:
  - `tee --help`
  - `tee --version`
  - `tee -p out`
  - `tee --output-error=warn out`
  - `tee --output-error=bad`
  - `tee dir` where `dir` is a case-local directory
- Needs shared owner action:
  - exact EPIPE and stdout/stderr broken-pipe handling needs shared stream write-error classification, including distinguishing pipe outputs from regular workspace files.
  - exact `exit` and `exit-nopipe` early termination on open/write errors should be aligned once shared streaming file sink policy can stop upstream reads deterministically.
  - signal behavior for `-i` is intentionally process-host policy, not a command-local implementation detail.

## Targeted Test Status

- Attempted: `swift test --filter MSPTextInputCommandTests/testHeadAndTailSupportHelpAndVersion`
- Attempted: `swift test --filter MSPTextStreamOracleTests/testLinuxTextStreamOracleCases`
- Attempted: `swift test --filter MSPWorkerCRecordStreamCommandTests/testPasteStreamsRepeatedStandardInputOperandsSequentially`
- Attempted: `swift test --filter MSPWorkerCRecordStreamCommandTests/testPasteStreamsZeroTerminatedSerialStandardInput`
- Passed: `swift build --target MSPPOSIXCore`
- Passed: `swift test --filter MSPTextInputCommandTests --jobs 1`
- Passed: `swift test --filter MSPWorkerCRecordStreamCommandTests --jobs 1`
- Passed: `swift test --filter MSPTextStreamOracleTests --jobs 1`

## Matrix Update Suggestion

For these four commands, the local command-level entries can cite the evidence above for help/version, header/NUL diagnostics, delimiter escape behavior, and `tee` output-error parsing. The shared owner actions above should be tracked outside command-local implementation work because they require pipeline, streaming, file-sink, or process-policy changes that are outside this batch subtask's write scope.
