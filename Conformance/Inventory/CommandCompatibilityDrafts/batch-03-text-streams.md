# Batch 03 - Text Streams

Source-backed Core100 compatibility matrix. This file is a working conformance
inventory, not a final compatibility certification.

Evidence read:
- `Conformance/Inventory/CommandCompatibilityDrafts/README.md`
- `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`
- `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text`
- `Implementations/Swift/Sources/MSPPOSIXCore/Support/MSPPOSIX{Command,Input,Option,Range,Record}Support.swift`
- `Implementations/Swift/Sources/ModelShellProxy`
- `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src`
- `References/LinuxSourceSnapshot/debian12-bookworm/sources/grep-3.8/src/grep.c`

Cross-cutting notes:
- Most Swift text commands read `Data` eagerly for file operands through `MSPPOSIXCommandSupport.inputData`; streaming only happens for selected stdin/pipeline shapes.
- `ModelShellProxy` falls back to Data-backed pipeline stages unless every stage is streaming-eligible; streaming pipelines use `MSPAsyncBytePipe(maxBufferedChunks: 32)`.
- `ModelShellProxyExecCommandBridge` emits stream chunks as UTF-8 text, so binary/NUL output can be correct inside MSP but still risky at the agent-visible bridge.
- `MSPPOSIXCommandSpec` does not automatically accept `--help` or `--version`; GNU standard options require a shared helper or per-command implementations.
- GNU `grep` is audited directly from the Debian 12 GNU grep 3.8 driver source (`grep.c`) rather than from help text alone.

## cat

- Command: `cat`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPCatCommand.swift` (`MSPCatCommand.run`, `runStreaming`, `renderCatOutput`, `visibleCatOutput`).
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cat.c` (`main`, `long_options`, `cat`, `simple_cat`).
- GNU/Linux parameter surface: `cat [OPTION] [FILE]...`; `-A/--show-all`, `-b/--number-nonblank`, `-e`, `-E/--show-ends`, `-n/--number`, `-s/--squeeze-blank`, `-t`, `-T/--show-tabs`, `-u`, `-v/--show-nonprinting`, `--help`, `--version`; `-` reads stdin; no-render path is byte passthrough.
- Currently supported by MSP: Accepts the core short/long display flags, `-u` as no-op, multiple operands and `-`; no-render stdin and plain file operands stream to `standardOutputStream` when available; plain file operands use `stat` + `readFileRange` chunks when size is available; rendered operands still materialize each input before rendering. Rendered `-E`/`-T` paths preserve invalid UTF-8/high-bit bytes unless `-v`-style quoting is active.
- Must implement: None for the current command-local Core100 surface.
- Deferred with reason: None; the missing surface is common command behavior.
- Forbidden by policy: None for read-only input; file access remains bounded by WorkspaceFS policy.
- Performance model: Plain stdin and plain file operands are streaming O(chunk) on the streaming path, and non-streaming `run` uses WorkspaceFS range reads before assembling the command result; rendered output remains eager O(total input) memory plus String growth risk; line numbering and visible rendering need cancellation and output byte limits.
- Oracle/stress gaps: None for command-local Core100 coverage. Shared output tests still own non-EBADF host sink failures beyond the covered closed stdout and downstream broken-pipe cases.
- Risk: medium - the option surface is close, but visible rendering and shared binary/output bridge behavior can still break parity.
- Closure status:
  - Implemented evidence: `MSPCatCommand.swift`; unit coverage in `MSPTextInputCommandTests` for `-A/-E/-T/-b/-n/-s/-t/-v`, repeated `-`, partial final lines, invalid-byte preservation under `-E/-T`, and cross-file numbering/squeeze state; streaming byte-preservation coverage in `MSPTextStreamCommandTests`; `MSPWorkerCRecordStreamCommandTests.testCatPlainFileOperandsUseRangeReads` proves plain large file operands use range reads without `readFile`; `testCatPlainFileOperandsStreamThroughRangeReads` proves plain file operands stream directly to `standardOutputStream`; `ModelShellProxyRedirectionTests.testClosedStandardInputIsNotTreatedAsEmptyInput` covers closed stdout write diagnostics from the shared redirection/output layer; direct parity has `cat cat.txt`.
  - Implementation disposition after this batch: Local implementation covers the visible flag set above, GNU standard options, byte-preserving rendered `-E/-T`, mixed missing+present operands, and range-read/streaming plain file operands in the shape of GNU `simple_cat` block reads within WorkspaceFS. The shared redirection/output layer now reports closed stdout as `cat: standard output: Bad file descriptor`; downstream early-close pipelines still stop traversal/streaming without turning normal consumer exit into a command-local error.
  - Oracle/stress evidence: Debian Core100 oracle now covers 11 primary `cat` cases: file input, numbering, show-all, stdin/file mixing, missing and mixed-missing files, `cat -A` byte sweep, binary passthrough through `od`, rendered huge-line stress, large-file short-consumer pipeline, and closed stdout EBADF write behavior. Targeted Core100 oracle passed for all 11 `cat` cases after the closed-stdout capture was merged.
  - Deferred/forbidden with reason: None beyond WorkspaceFS read policy; common GNU parameters are not deferred.

## comm

- Command: `comm`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPCommCommand.swift` (`MSPCommCommand.run`, `CommRecordCursor`).
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/comm.c` (`long_options`, `compare_files`, `main`).
- GNU/Linux parameter surface: `comm [OPTION] FILE1 FILE2`; `-1`, `-2`, `-3`, `--check-order`, `--nocheck-order`, `--output-delimiter=STR`, `--total`, `-z/--zero-terminated`, `--help`, `--version`; inputs must be sorted under locale collation.
- Currently supported by MSP: Accepts `-1`, `-2`, `-3`, `-z`, `--check-order`, `--nocheck-order`, `--output-delimiter`, `--total`, `--help`, and `--version`; exactly two operands; rejects `- -`; `-` consumes `context.standardInput` once; compares records bytewise with `Data.lexicographicallyPrecedes`; empty `--output-delimiter` emits NUL; default and explicit disorder diagnostics follow the `compare_files`/`check_order` source order for covered bytewise cases.
- Must implement: None for the current command-local Core100 byte/C-locale surface.
- Deferred with reason: Full host `LC_COLLATE` parity is deferred to a shared locale/collation service because implementing it inside `comm` would fork cross-command locale behavior; truly non-eager two-file merge is deferred to the shared WorkspaceFS streaming/range-read policy.
- Forbidden by policy: None for read-only comparison.
- Performance model: Current implementation is eager O(size(FILE1)+size(FILE2)) memory; GNU can stream a merge with O(record) plus group state; MSP needs cancellation on long files and bounded diagnostic accumulation.
- Oracle/stress gaps: None for the current command-local Core100 byte/C-locale surface.
- Risk: medium - the bytewise Core100 surface is covered, but full GNU locale collation and large-file streaming remain outside command-local closure.
- Closure status:
  - Implemented evidence: `MSPCommCommand.swift`; `MSPCatCommCutCommandTests` covers GNU standard options, `- -`, duplicate output delimiters, default/check/nocheck disorder ordering, `--total`, and `-z -12` with stdin plus file operands; `MSPTextStreamOracleTests` covers default, `-12`, default disorder diagnostics, `--check-order`, `--total`, empty output delimiter as NUL, missing file, and non-UTF8 common records; Core100 oracle fixture has 8 primary `comm` cases.
  - Implementation disposition after this batch: Command-local bytewise Core100 behavior is closed against `comm.c` for options, output columns, NUL records, totals, stdin guard, and covered sortedness diagnostics.
  - Parent oracle/stress request: sample host-locale collation and million-line/two-file streaming behavior only after shared locale and streaming policy are available.
  - Deferred/forbidden with reason: Full host-locale collation and true streaming merge are deferred for shared-service reasons above; no common GNU option is deferred.

## cut

- Command: `cut`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPCutCommand.swift` (`parse`, `streamCutOutput`, `selectedCutRecord`, `selectBytes`, `selectCharacters`, `selectFields`).
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cut.c` (`longopts`, `main`, field/byte writers, `set_fields` helpers).
- GNU/Linux parameter surface: `cut OPTION... [FILE]...`; `-b/--bytes=LIST`, `-c/--characters=LIST`, `-f/--fields=LIST`, `-d/--delimiter=DELIM`, `-n`, `-s/--only-delimited`, `--output-delimiter=STRING`, `--complement`, `-z/--zero-terminated`, `--help`, `--version`; `-d ''` and empty output delimiter have NUL semantics in coreutils.
- Currently supported by MSP: Supports `-b`, `-c`, `-f`, `-d`, `-n`, `-s`, `--output-delimiter`, `--complement`, `-z`, `--help`, and `--version`; stdin streams when operands are empty or `["-"]`; `-n` is the GNU no-op; `-c` follows the GNU 9.1 `byte_mode` path and preserves invalid UTF-8 bytes; `-d` and `--output-delimiter` use raw argument bytes with empty-string-as-NUL semantics; LIST parsing accepts comma and single blank/tab separators for covered `set-fields.c` forms.
- Must implement: None for the current command-local Core100 byte/C-locale surface.
- Deferred with reason: Exact overflow wording for enormous LIST numbers and true multi-file streaming are deferred to a source-backed range-diagnostic pass and shared WorkspaceFS streaming policy; covered normal and malformed LIST forms now follow `set-fields.c`.
- Forbidden by policy: None.
- Performance model: Streaming stdin is O(max record length) memory; file/multi-input path materializes all records O(total input); `selectedOffsets` allocates per-record boolean arrays proportional to record length.
- Oracle/stress gaps: None for the current command-local Core100 byte/C-locale surface.
- Risk: medium - common byte/field behavior is covered; exact diagnostics and multi-file streaming are still incomplete.
- Closure status:
  - Implemented evidence: `MSPCutCommand.swift`; `MSPCatCommCutCommandTests` covers GNU standard options, `-z`, raw delimiter/output-delimiter byte semantics, blank-separated LIST, `--output-delimiter` for byte/character ranges, complement, and invalid UTF-8 `-c` byte selection; `MSPTextLanguageCommandOracleTests` covers `-n`, empty delimiter NUL, and empty output delimiter NUL; Core100 oracle fixture has 10 primary `cut` cases.
  - Implementation disposition after this batch: Command-local byte and field selection are aligned with `cut.c`/`set-fields.c` for covered valid LIST forms, raw delimiter bytes, `-c` byte behavior, NUL records, and invalid-byte preservation.
  - Parent oracle/stress request: sample enormous LIST overflow wording, multi-file partial-failure ordering, and long-record stress through the approved capture flow.
  - Deferred/forbidden with reason: Exact overflow wording for enormous LIST values and true multi-file streaming are deferred for the source/shared reasons above; common valid LIST, malformed LIST, delimiter, byte, field, and NUL behavior is command-local covered.

## expand

- Command: `expand`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPExpandCommand.swift` plus `MSPTextLayoutSupport.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/expand.c` and `expand-common.c` (`longopts`, `shortopts`, `parse_tab_stops`, `main`).
- GNU/Linux parameter surface: `expand [OPTION]... [FILE]...`; `-i/--initial`, `-t/--tabs=LIST`, obsolete numeric `-N`/`-LIST` tab stop syntax, `--help`, `--version`; files and stdin.
- Currently supported by MSP: Supports `-i`, `--initial`, `-t N`, `-tN`, `--tabs=N`, obsolete numeric/list syntax, `/N` and `+N` tab-stop forms, default tab size 8, operands and stdin, byte-preserving invalid input, CR/BS column behavior, streaming stdin, and file operands through WorkspaceFS range reads.
- Must implement: None for the current Core100 noninteractive command-local surface.
- Deferred with reason: Full locale/display-width parity is deferred to the shared text-layout locale capability used by `fold`, `unexpand`, and `wc`; `expand` itself is byte/tab-stop driven for the current Core100 surface.
- Forbidden by policy: None.
- Performance model: Stdin streaming is O(chunk) memory; file operands read by `readFileRange` and render chunk-by-chunk with O(chunk + output chunk) memory, though non-streaming API calls still materialize returned stdout as required by `MSPCommandResult`.
- Oracle/stress gaps: None for the current Core100 noninteractive command-local surface.
- Risk: low for command-local Core100; medium only if future claims depend on full host-locale display width without the shared locale capability.
- Closure status:
  - Implemented evidence: `MSPExpandCommand.swift` and `MSPTextLayoutSupport.swift`; `MSPTextLayoutCommandTests` covers default, `-t 4`, obsolete `-4`, comma tab lists, obsolete `-2,6`, `/N` and `+N`, `-i`, file operand, invalid tab diagnostics including zero, overflow, bad `/`/`+`, CR/BS behavior, and invalid-byte preservation; `MSPTextStreamCommandTests` covers chunked stdin streaming and broken-pipe behavior; `MSPWorkerCRecordStreamCommandTests.testExpandAndUnexpandFileOperandsUseRangeReads` proves file operands avoid `readFile`; Core100 oracle fixture has 15 `expand` cases covering default, tab lists, file/multiple operands, invalid/missing paths, obsolete syntax, `/+` syntax, carriage returns, and binary invalid bytes.
  - Implementation disposition after this batch: Command-local Core100 surface is closed against `expand.c`/`expand-common.c` option and tab-stop shape; file operands now stream through WorkspaceFS range reads.
  - Parent oracle/stress request: none for command-local closure; future work should add shared locale/display-width oracle before claiming full host-locale parity.
  - Deferred/forbidden with reason: Full locale/display-width parity is deferred to shared text-layout locale support.

## fmt

- Command: `fmt`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPFmtCommand.swift` plus `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/Fmt/`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/fmt.c` (`long_options`, `main`, paragraph formatter).
- GNU/Linux parameter surface: `fmt [-WIDTH] [OPTION]... [FILE]...`; `-c/--crown-margin`, `-p/--prefix=STRING`, `-s/--split-only`, `-t/--tagged-paragraph`, `-u/--uniform-spacing`, `-w/--width=WIDTH`, `-g/--goal=WIDTH`, `--help`, `--version`.
- Currently supported by MSP: Supports `-c/--crown-margin`, `-p/--prefix=STRING`, `-s/--split-only`, `-t/--tagged-paragraph`, `-u/--uniform-spacing`, `-w/--width=WIDTH`, `-g/--goal=WIDTH`, old first-argument `-WIDTH`, GNU standard options, operands, stdin, byte-preserving invalid input, long words, multi-file diagnostics, and bounded paragraph formatting based on GNU `fmt.c`'s word/cost model.
- Must implement: None for the command-local Core100 GNU option surface above.
- Deferred with reason: True non-eager file/stdin ingestion is deferred to the shared text-layout input layer because `mspTextLayoutData` still materializes command input before `fmt` receives it; the formatter itself now bounds paragraph dynamic programming in the shape of GNU `MAXWORDS`/`flush_paragraph`.
- Forbidden by policy: None.
- Performance model: Formatter is byte-oriented and uses GNU-style dynamic programming over bounded word chunks, O(min(paragraph_words, 996)^2) per chunk, preserving invalid bytes and avoiding unbounded paragraph DP. The command result and shared input collector still materialize full input/output, so very large end-to-end streams remain a shared runtime/input-layer concern rather than a fmt option/parser gap.
- Oracle/stress gaps: None for the current command-local Core100 surface.
- Risk: medium - command-local GNU option behavior is covered, while full streaming ingestion/output backpressure remains shared runtime work.
- Closure status:
  - Implemented evidence: `MSPFmtCommand.swift` is now a thin command entry; `Text/Fmt/MSPFmtConfiguration.swift` follows `fmt.c`'s `long_options`, first-argument old `-WIDTH` rule, and `xdectoumax` goal/width diagnostics; `MSPFmtScanning.swift` owns byte line/word scanning; `MSPFmtRenderer.swift` owns prefix/crown/tagged paragraph grouping; `MSPFmtWordFormatting.swift` owns `base_cost`/`line_cost` break selection and bounded long-paragraph flushing. `MSPTextLayoutCommandTests` covers default wrapping, width/goal/old width, tagged paragraphs, split-only, uniform spacing, paragraphs, file/multi-file input, prefix/crown cases, invalid width, missing file, space paths, and long-paragraph chunking.
  - Oracle/stress evidence: Core100 Debian 12 oracle fixture has 25 primary `fmt` cases covering default, `-w`, `-s`, `-t -g`, old `-WIDTH`, `-u`, paragraph breaks, file/multiple operands, prefix/mail quote prefix, crown indentation, invalid width and goal-too-wide diagnostics, missing and mixed missing+present inputs, space paths, old width not first, long words, invalid bytes through `od`, and 1,200-word huge paragraph line-count stress. Targeted Core100 oracle passed for all 25 fmt cases after the source-backed formatter pass.
  - Implementation disposition after this batch: Command-local Core100 fmt surface is closed. Remaining large-stream concerns belong to shared input/output streaming and backpressure conformance, not to `fmt`-local option semantics.
  - Parent oracle/stress request: none for command-local closure; future shared-runtime work should add end-to-end streaming/backpressure fixtures once the common text input collector stops materializing full inputs.
  - Deferred/forbidden with reason: No visible GNU fmt option is deferred; only shared non-eager ingestion/output backpressure is deferred as described above.

## fold

- Command: `fold`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPFoldCommand.swift` plus `MSPTextLayoutSupport.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/fold.c` (`longopts`, `main`, `fold_file`).
- GNU/Linux parameter surface: `fold [OPTION]... [FILE]...`; `-b/--bytes`, `-s/--spaces`, `-w/--width=WIDTH`, obsolete numeric `-WIDTH`, `--help`, `--version`.
- Currently supported by MSP: Supports `-b`, `-s`, `-w N`, `-wN`, `--width=N`, obsolete `-WIDTH`, GNU standard options, operands, and stdin; streaming stdin folds incrementally across chunks; column model follows GNU `fold.c` byte handling for tab, CR, and BS.
- Must implement: None for the current Core100 noninteractive command-local surface.
- Deferred with reason: None for command-local Core100 behavior; downstream write-error status belongs to the shared output-stream contract.
- Forbidden by policy: None.
- Performance model: Streaming stdin uses O(width + pending line tail) state like GNU `fold_file`; non-streaming `run` still accumulates stdout for the command result, but the folding algorithm itself no longer requires whole-stdin buffering.
- Oracle/stress gaps: None for the current command-local Core100 surface. Shared output tests still own downstream broken-pipe/write-error status.
- Risk: medium-low - option surface is small and byte/column behavior is covered; remaining risk is shared output failure propagation.
- Closure status:
  - Implemented evidence: `MSPFoldCommand.swift` and `MSPTextLayoutSupport.swift`; `MSPTextLayoutCommandTests` covers default, `-w`, obsolete `-WIDTH`, `-s`, byte mode `-b`, file/multi-file/space-path input, invalid width, missing file, carriage-return, and backspace cases; `MSPTextStreamCommandTests.testFoldStreamsLineStateAcrossInputChunks` proves streaming state across chunk boundaries; Core100 oracle fixture has 13 primary `fold` cases including long line, old width, CR, and BS, and direct parity has `fold -w 3`.
  - Implementation disposition after this batch: Local implementation covers GNU standard options, obsolete width, file diagnostics, byte mode, tab/backspace/carriage-return column movement, common `-s` behavior, and stdin streaming in the shape of GNU `fold_file`. GNU coreutils 9.1 `fold.c` is byte/column based rather than wcwidth-based, so no separate multibyte display-width command-local requirement remains for this source baseline.
  - Oracle/stress evidence: Debian Core100 oracle covers default, width, spaces, byte mode, file/multiple files, invalid width, missing file, long line, space path, old width, carriage return, and backspace. Local streaming tests cover chunk boundaries; shared output tests own downstream close/broken-pipe behavior.
  - Deferred/forbidden with reason: None for command-local Core100 behavior; no policy-forbidden options.

## grep

- Command: `grep`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPGrepCommand.swift` (`GrepOptions`, `grepVisitSources`, `grepStreamStandardInput`, `grepFragments`).
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/grep-3.8/src/grep.c` (`short_options`, `long_options`, `usage`, `matchers`, `setmatcher`, `get_nondigit_option`, `context_length_arg`, `binary_files`, `directories_args`, `skipped_file`, `grepdirent`, `grepfile`, `grepdesc`, `grep`, `grepbuf`, `prtext`, `prline`).
- GNU/Linux parameter surface: `grep [OPTION]... PATTERNS [FILE]...`; option-table and usage-backed pattern modes `-G/--basic-regexp`, `-E/--extended-regexp`, `-F/--fixed-regexp`/`--fixed-strings`, `-P/--perl-regexp`, and undocumented matcher selector `-X`; pattern sources `-e/--regexp=PATTERNS`, `-f/--file=FILE`; match controls `-i/--ignore-case`, `--no-ignore-case`, `-v/--invert-match`, `-w/--word-regexp`, `-x/--line-regexp`, `-z/--null-data`; output controls `-m/--max-count`, `-b/--byte-offset`, `-n/--line-number`, `--line-buffered`, `-H/--with-filename`, `-h/--no-filename`, `--label=LABEL`, `-o/--only-matching`, `-q/--quiet/--silent`, `-s/--no-messages`, `-L/--files-without-match`, `-l/--files-with-matches`, `-c/--count`, `-T/--initial-tab`, `-Z/--null`; binary/device/directory controls `--binary-files=binary|text|without-match`, `-a/--text`, `-I`, `-U/--binary`, `-u/--unix-byte-offsets`, `-d/--directories=read|recurse|skip`, `-D/--devices=read|skip`, `-r/--recursive`, `-R/--dereference-recursive`; traversal filters `--include=GLOB`, `--exclude=GLOB`, `--exclude-from=FILE`, `--exclude-dir=GLOB`; context controls `-A/--after-context=NUM`, `-B/--before-context=NUM`, `-C/--context=NUM`, digit option `-NUM`, `--group-separator=SEP`, `--no-group-separator`; color/version/help controls `--color[=WHEN]`/`--colour[=WHEN]`, `-V/--version`, `--help`; old alias `-y` maps to ignore-case. With no FILE, source defaults to `.` only when recursive was requested, otherwise stdin; exit status is 0 for any selected line, 1 for none, 2 for errors except `-q` can return 0 on match.
- Currently supported by MSP: Accepts and implements `-i`, `-y`, `--no-ignore-case`, `-v`, `-n`, `-l`, `-L`, explicit matcher selection `-G`/`--basic-regexp`, `-E`/`--extended-regexp`, `-F`/`--fixed-regexp`/`--fixed-strings`, and the Core100 PCRE-compatible `-P`/`--perl-regexp` subset covered by Debian oracle, with GNU conflict diagnostics when different matcher kinds are combined. It also implements `-w`, `-x`, `-r`/`-R`/`--dereference-recursive` as WorkspaceFS-confined recursion, `-H`, `-h`, `--label`, `-c`, `-o`, `-q`/`--silent`, `-s`/`--no-messages`, `-b`, `-z`, `-Z`, `-e`, `-f FILE|-`, `-m`, context `-A/-B/-C/-NUM`, `--group-separator`, `--no-group-separator`, `--include`, `--exclude`, `--exclude-from=FILE|-`, `--exclude-dir`, `--binary-files`, `-I`, `-a`, `--directories`, `--devices`, `-T`, `-u`, `-U`, `--line-buffered` as the GNU noninteractive output-equivalent mode, `--color/--colour` including `--color=always` SGR output, operands, and `-` stdin. BRE translation covers the Core100 default-vs-ERE distinctions; non-fixed matching uses `NSRegularExpression` over UTF-8-decoded `String`, and fixed matching uses Swift string search.
- Must implement: None for the current Core100 noninteractive command-local surface.
- Deferred with reason: Full PCRE-only constructs beyond the sampled `-P` compatible subset require adding or binding a proven PCRE engine because GNU grep 3.8 routes that matcher through optional PCRE support; MSP does not declare that wider PCRE surface as complete yet. Undocumented `-X` stays outside Core100 because GNU usage intentionally hides the matcher-selection internals. Recursive search remains WorkspaceFS-confined by product safety policy even where host GNU grep can traverse device and symlink shapes outside a sandbox.
- Forbidden by policy: Recursive search must remain inside WorkspaceFS; no host-device traversal or uncontrolled symlink escape.
- Performance model: GNU grep streams page-aligned buffers, tracks byte offsets and context across reads, and flushes per line when `line_buffered` is set. MSP has command-result and streaming paths: simple stdin streaming writes selected rows incrementally, while file and feature-rich modes process bounded WorkspaceFS file data into rows before returning. Recursive traversal applies include/exclude/exclude-dir pruning inside WorkspaceFS and stops early for quiet/list modes through `GrepRunState.stopAll`; it intentionally avoids host-device traversal.
- Oracle/stress gaps: None for the current Core100 noninteractive command-local surface.
- Risk: medium - Core100 covers the GNU option combinations MSP currently declares, including BRE/ERE/FRE matcher selection, `-P` compatible basic matching, color, context, binary/text modes, directory policy, recursion filters, pattern files, `-z`, `-Z`, precedence, and `--line-buffered`. Wider PCRE engine fidelity and raw-byte grep internals are explicitly outside the current declared surface rather than silently accepted as complete GNU grep.
- Closure status:
  - Implemented evidence: `MSPGrepCommand.swift`; `MSPTextLanguageCommandOracleTests` covers help/version, matcher selection, conflicting matchers, case controls, labels, context, binary/text/directory modes, color, pattern files, recursion filters, `-z`, `-Z`, `-T`, `-u`, precedence, invalid options, and `--line-buffered`; `MSPGrepCommandTests` covers `-f -`, standard-input consumption, and `--exclude-from=-`; Core100 oracle fixture has 25 primary `grep` cases.
  - Implementation disposition after this batch: Closed for the Core100 noninteractive command-local surface.
  - Oracle/stress disposition after this batch: Closed for the Core100 noninteractive command-local surface.
  - Deferred/forbidden with reason: Full PCRE beyond the sampled compatible subset requires a proven PCRE engine; undocumented `-X` is outside Core100; recursive traversal must remain WorkspaceFS-confined.

## head

- Command: `head`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPHeadTailCommands.swift` (`MSPHeadCommand`, shared `MSPHeadTailCommand`).
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/head.c` (`long_options`, old option parser, `main`, byte/line output helpers).
- GNU/Linux parameter surface: `head [OPTION]... [FILE]...`; `-n/--lines=[-]NUM`, `-c/--bytes=[-]NUM`, size suffixes, `-q/--quiet/--silent`, `-v/--verbose`, `-z/--zero-terminated`, obsolete `-NUM[bkm][cqvlz]`, hidden `--presume-input-pipe`, `--help`, `--version`.
- Currently supported by MSP: Supports `-n`, `-c`, signed counts for all-but-last, common GNU size suffix multipliers, `-q`, `-v`, `-z`, GNU old `-NUM` forms with byte/line/header/NUL trailing letters, multiple operands with GNU blank-line header spacing, repeated `-` stdin operands, and stdin streaming for `head` and all-but-last paths.
- Must implement: No remaining local implementation gap for the current noninteractive MSP surface.
- Deferred with reason: Hidden `--presume-input-pipe` can be deferred because it is undocumented and tied to GNU internal I/O strategy.
- Forbidden by policy: None.
- Performance model: Simple stdin head streams O(chunk) and closes upstream; file operands use `stat` + `readFileRange` where available; all-but-last paths retain only the trailing byte/record window needed by the request.
- Oracle/stress gaps: No remaining head-local oracle/stress gap for the current noninteractive MSP surface. Debian oracle covers primary line/byte/NUL/header cases, while local stream tests cover early close and all-but-last buffering.
- Risk: low - local behavior now covers GNU noninteractive selection, headers, stdin operands, old-form diagnostics, and byte preservation; hidden GNU internal I/O knob remains deferred.
- Closure status:
  - Implemented evidence: `MSPHeadTailCommands.swift`; `MSPTextInputCommandTests` covers signed lines/bytes, old `-NUM` forms with `c/q` trailing letters, GNU header spacing, repeated `-` stdin operands, invalid old-form diagnostics, quiet mode, and missing+present file ordering; `MSPTextStreamCommandTests` covers early close and all-but-last streaming; Core100 oracle fixture has primary `head` cases and direct parity has `head -n 1`.
  - Implementation disposition after this batch: Local fixes added GNU standard options, common count suffix multipliers, range-based file operand selection, GNU `write_header` blank-line behavior, repeated standard input operand handling, and old-form diagnostic coverage, matching the source shape in `head.c` (`long_options`, `write_header`, `main`, `head_bytes`, `head_lines`, and seek/range paths where applicable) within the MSP workspace API.
  - Additional safe sampling candidates: invalid old-form diagnostics and large all-but-last byte/line stress can be added to the managed Debian capture set when the coordinator refreshes oracle fixtures.
  - Deferred/forbidden with reason: Hidden GNU `--presume-input-pipe` is deferred as an undocumented internal I/O knob.

## join

- Command: `join`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPJoinCommand.swift` plus `Commands/Text/Join/`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/join.c` (`longopts`, `main`, `join`, `prjoin`).
- GNU/Linux parameter surface: `join [OPTION]... FILE1 FILE2`; `-a FILENUM`, `-v FILENUM`, `-e STRING`, `-i/--ignore-case`, `-1 FIELD`, `-2 FIELD`, `-j FIELD`, `-o FORMAT` including `auto`, `-t CHAR`, `-z/--zero-terminated`, `--check-order`, `--nocheck-order`, `--header`, `--help`, `--version`; sorted input under locale collation.
- Currently supported by MSP: Supports GNU standard options plus `-i/--ignore-case`, `-t CHAR` including `-t ''` whole-line and `-t '\0'`, `-1`, `-2`, `-j`, `-a`, `-v`, `-e`, `-o FORMAT`, `-o auto`, `-z/--zero-terminated`, `--check-order`, `--nocheck-order`, and `--header`; exactly two operands; rejects `- -` with GNU's errno-suffixed diagnostic; parses fields, join keys, comparisons, and output as `Data` so invalid bytes and NUL separators are preserved; groups duplicate keys and emits Cartesian products in input order.
- Must implement: None for the current command-local Core100 byte/C-locale surface.
- Deferred with reason: Full host `LC_COLLATE` parity is deferred to a shared locale/collation service, and true non-eager file streaming is deferred to the shared WorkspaceFS range/record streaming layer. The command-local grouped merge semantics, stdin guard, byte field parsing, and diagnostics are covered.
- Forbidden by policy: None.
- Performance model: Current implementation materializes both inputs as row arrays and buffers output, O(rows1+rows2+output) memory; duplicate-key groups intentionally produce Cartesian output like GNU `join`. Core100 stress covers a 30x40 duplicate group count, but million-row streaming/backpressure remains shared runtime work.
- Oracle/stress gaps: None for the current command-local Core100 byte/C-locale surface.
- Risk: medium - byte/C-locale command semantics are covered; residual risk is shared locale collation and very-large input/output streaming.
- Closure status:
  - Implemented evidence: `MSPJoinCommand.swift` is now a thin command entry; `Text/Join/MSPJoinConfiguration.swift` owns GNU option/help parsing; `MSPJoinInput.swift` owns file/stdin input materialization; `MSPJoinRows.swift` owns byte field/key/group/order logic; `MSPJoinEngine.swift` owns grouped merge/default disorder behavior; `MSPJoinOutput.swift` owns default, explicit, and auto output rows. `MSPSortUniqCommandTests` covers GNU standard options, `--header`, `-z`, `--check-order`, `--nocheck-order`, `-o auto`, `-t ''`, `-t '\0'`, both-stdin diagnostics, multi-character separator diagnostics, and default disorder warnings; join rows/fields/keys/output are byte-based `Data` rather than UTF-8 `String`.
  - Oracle/stress evidence: Core100 Debian 12 oracle fixture has 18 primary `join` cases covering default join, explicit separator, unpairable output, missing file, header auto format, NUL records, check-order, whole-line separator, NUL field separator, duplicate-key Cartesian products, missing-field replacement with `-e`/`-o`, default disorder warning and final status, `--nocheck-order`, `--header`, both stdin, zero-terminated unpairables, invalid byte preservation through `od`, and huge duplicate-group line-count stress. Targeted Core100 oracle passed for all 18 join cases.
  - Implementation disposition after this batch: Command-local Core100 byte/C-locale behavior is closed against `join.c` option parsing and `join`/`prjoin` grouped output shape. Remaining host-locale and true non-eager streaming concerns are shared services.
  - Parent oracle/stress request: none for command-local closure; future shared-runtime work should add million-row streaming/backpressure and non-C locale collation once those shared capabilities exist.
  - Deferred/forbidden with reason: Full host locale collation and true file streaming are deferred to shared services; no visible GNU join option in the Core100 byte/C-locale surface is deferred.

## nl

- Command: `nl`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPNlCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/nl.c` (`longopts`, `build_type_arg`, `main`, section handling).
- GNU/Linux parameter surface: `nl [OPTION]... [FILE]`; `-h/--header-numbering=STYLE`, `-b/--body-numbering=STYLE`, `-f/--footer-numbering=STYLE`, `-v/--starting-line-number`, `-i/--line-increment`, `-p/--no-renumber`, `-l/--join-blank-lines`, `-s/--number-separator`, `-w/--number-width`, `-n/--number-format`, `-d/--section-delimiter`, regex style `pBRE`, `--help`, `--version`.
- Currently supported by MSP: Supports GNU standard options plus `-h/-b/-f a|t|n|pBRE`, `-v`, `-i`, `-p`, `-l`, `-s`, `-w`, `-n ln|rn|rz`, and `-d`; streams operands/stdin line by line; eager and streaming paths preserve whether each input record ended in LF and process file operands sequentially instead of concatenating them.
- Must implement: None remaining in the command-local Core100 surface covered by this batch.
- Deferred with reason: Exact GNU/POSIX BRE dialect parity for `pBRE` and byte/locale behavior need a shared regex and locale policy; signal/output-pipe behavior is not applicable to `nl`.
- Forbidden by policy: None.
- Performance model: Streaming path is O(max line) memory; eager path concatenates multiple inputs before numbering and can blur per-file behavior; regex styles add per-line matching cost.
- Oracle/stress gaps: None for command-local Core100 coverage.
- Risk: medium - command-local GNU surface is covered; residual risk is shared regex/locale parity.
- Closure status:
  - Implemented evidence: `MSPNlCommand.swift`; `MSPNlTrCommandTests` covers GNU standard options, section delimiters, header/body/footer styles, no-renumber, custom delimiters, `pBRE`, blank-line grouping, diagnostics, and final unterminated records in eager and streaming mode; `MSPTextStreamOracleTests` covers multi-file EOF boundary behavior; `MSPWorkerCRecordStreamCommandTests` covers streaming stdin and range-read file operands; Core100 oracle fixture has 8 primary `nl` cases.
  - Implementation disposition after this batch: Command-local `nl.c` behavior for options, logical pages, numbering state, blank-line joins, file sequencing, and final unterminated records is implemented and tested.
  - Oracle/stress evidence: Existing Linux fixture covers body numbering, format, separator, file input, sections, no-renumber, blank-line grouping, and pattern style; further huge-line and byte/locale stress belongs with the shared regex/locale policy.
  - Deferred/forbidden with reason: Exact GNU/POSIX BRE dialect and byte/locale behavior are deferred to shared regex/locale policy rather than patched ad hoc inside `nl`.

## paste

- Command: `paste`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPPasteCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/paste.c` (`longopts`, delimiter parser, `main`, `paste_parallel`, `paste_serial`).
- GNU/Linux parameter surface: `paste [OPTION]... [FILE]...`; `-d/--delimiters=LIST`, `-s/--serial`, `-z/--zero-terminated`, `--help`, `--version`; multiple `-` operands consume stdin as a stream.
- Currently supported by MSP: Supports `-d`, `--delimiters`, `-s`, `--serial`, `-z`/`--zero-terminated`, GNU standard options, default tab delimiter, empty delimiter, delimiter escapes for `\0`, `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, and `\\`, byte-preserving records, repeated `-` stdin operands, streaming `-z`, streaming file operands, and streaming repeated stdin columns through a shared record reader.
- Must implement: None for the current Core100 noninteractive command-local surface.
- Deferred with reason: None.
- Forbidden by policy: None.
- Performance model: Streaming path is O(number of columns * max record) memory; serial mode streams one file at a time; `run` necessarily materializes returned stdout for `MSPCommandResult`, while `runStreaming` preserves the GNU `paste_parallel` / `paste_serial` input-consumption shape.
- Oracle/stress gaps: None for the current Core100 noninteractive command-local surface.
- Risk: low for command-local Core100; future work should keep binary/NUL bridge tests at the agent-facing layer.
- Closure status:
  - Implemented evidence: `MSPPasteCommand.swift`; `MSPTextStreamOracleTests` covers serial mode, delimiter mode, empty delimiter, delimiter escape bytes, trailing-backslash diagnostics, zero-terminated serial input, missing file, uneven file lengths, and binary empty-delimiter preservation; `MSPWorkerCRecordStreamCommandTests` covers streaming repeated stdin operands, streaming `-z` serial stdin, streaming zero-terminated binary records, and streaming multiple file operands through WorkspaceFS range reads; Core100 Debian 12 oracle fixture has 10 `paste` cases covering files, custom delimiter, serial, stdin, repeated stdin, binary empty delimiter, delimiter escapes, trailing backslash, zero-terminated serial, and zero-terminated binary serial.
  - Implementation disposition after this batch: Command-local Core100 surface is closed against `paste.c` option, delimiter, `paste_parallel`, and `paste_serial` behavior. Remaining binary bridge concerns belong to agent-visible transport conformance rather than `paste` command-local implementation.
  - Parent oracle/stress request: none for command-local closure.
  - Deferred/forbidden with reason: None.

## sort

- Command: `sort`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPSortCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/sort.c` (`short_options`, `long_options`, key parser, merge/sort engine, `main`).
- GNU/Linux parameter surface: `sort [OPTION]... [FILE]...`; ordering `-b`, `-d`, `-f`, `-g`, `-h`, `-i`, `-M`, `-n`, `-R`, `-r`, `-V`, `--sort=WORD`; operation `-c/--check[=diagnose-first]`, `-C`, `-m`, `-o`, `-s`, `-S`, `-t`, `-T`, `-u`, `-z`; keys `-k POS1[,POS2][OPTS]`; input list/perf `--files0-from`, `--batch-size`, `--compress-program`, `--debug`, `--parallel`, `--random-source`, `--help`, `--version`; locale collation.
- Currently supported by MSP: Supports `-b`, `-d`, `-f`, `-g`, `-h`, `-i`, `-M`, `-m/--merge`, `-n`, `-R/--random-sort`, `-r`, `-s`, `-u`, `-V`, `-z`, `-c`, `-C`, `--check=quiet|silent|diagnose-first`, `--sort=general-numeric|human-numeric|month|numeric|random|version`, `--random-source=FILE`, `--debug`, `--files0-from=FILE|-`, `-S/--buffer-size` with GNU suffix validation for the covered surface, `-T/--temporary-directory`, `--batch-size`, `--parallel`, `-t`, `-k POS1[,POS2][OPTS]` with GNU field numbers, character offsets, inherited/global ordering, and per-key modifiers for the covered C.UTF-8 surface, plus `-o` including same-file output; eager read of all inputs; bytewise fallback via UTF-8 strings; no external merge/spill.
- Must implement: No remaining local implementation gap for the current Core100 noninteractive C.UTF-8 sort surface.
- Deferred with reason: Exact multi-threaded performance parity for `--parallel`, exact memory-budget enforcement for `-S`, fan-in enforcement for `--batch-size`, and actual temp-spill use of `-T` are staged behind the shared external-merge/temp-spill engine; the options are now accepted for in-memory Core100 sorting and covered by Debian oracle.
- Forbidden by policy: `--compress-program` must not spawn arbitrary host programs by default; `-T/--temporary-directory` must not write outside authorized WorkspaceFS/temp roots.
- Performance model: Current O(total records) memory and O(n log n) in-process sort; GNU uses bounded buffers, temp files, merge fan-in, and optional parallelism. Core100 now covers deterministic `--random-source`, debug annotations, same-file output, suffix diagnostics, and a 4000-line stress count; exact bounded spill/parallel throughput remains a shared temp-spill engine requirement rather than a command-local semantic gap.
- Oracle/stress gaps: No remaining sort-local oracle/stress gap for the current Core100 noninteractive C.UTF-8 surface.
- Risk: medium - sort is central to pipelines; semantics are covered for Core100, while exact GNU large-file spill/parallel performance remains shared engine work.
- Closure status:
  - Implemented evidence: `MSPSortCommand.swift`; `MSPSortUniqCommandTests` covers default, `-u`, `-n`, `-r`, `-f`, `-t`, GNU `-k` field/character offsets and per-key modifiers, check mode, `-o`, GNU-like unique-by-key behavior, `-b`, `-g`, `-i`, `-M`, `-V`, `--sort=general-numeric|month|random`, `-R`, `--random-source`, `--debug`, debug incompatibilities, GNU `-S` suffix diagnostics, ordering incompatibilities, `--files0-from=FILE|-` including mixed operands, empty lists, empty names, and `-` list members, `--batch-size`, `--parallel`, `-S`, `-T`, and `-m/--merge` preserving per-file order; `MSPTextStreamOracleTests` covers byte-preserving non-UTF8 sort; Core100 oracle fixture now has 38 primary `sort` cases including 6 `--files0-from`, one performance-knob, two merge cases, five GNU key-character/per-key cases, four deterministic random-source cases, three debug cases, one suffix/incompatibility case, same-file `-o`, and one long-input stress count captured from Debian 12.
  - Implementation disposition after this batch: Existing sort/unique-key coverage includes GNU standard options, `-C`, `--check=quiet|silent`, `-s/--stable`, common comparison modes, `--sort=WORD` including random, source-backed `-k` POS parsing for covered C.UTF-8 key ranges, `--files0-from` list ingestion, accepted no-side-effect performance knobs for in-memory sorting, deterministic GNU-shaped random-source hashing over `seed + key + NUL`, debug output for the Core100 surface, and eager in-memory merge of presorted inputs. No remaining command-local implementation gap is open for the Core100 noninteractive sort surface.
  - Parent oracle/stress request: No remaining sort-local parent oracle request for Core100; future shared-runtime work should add host-locale collation services and a bounded external merge/temp-spill engine before claiming exact GNU throughput parity for very large files.
  - Deferred/forbidden with reason: `--parallel` exact performance parity can be staged after semantics; `--compress-program` must not spawn arbitrary host programs by default, and `-T` must stay inside authorized temp/workspace roots.

## tail

- Command: `tail`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPHeadTailCommands.swift` (`MSPTailCommand`, shared `MSPHeadTailCommand`).
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tail.c` (`long_options`, `parse_options`, follow engine, `main`).
- GNU/Linux parameter surface: `tail [OPTION]... [FILE]...`; `-n/--lines=[+]NUM`, `-c/--bytes=[+]NUM`, size suffixes, `-q/--quiet/--silent`, `-v/--verbose`, `-z/--zero-terminated`, old numeric forms, follow `-f`, `-F`, `--follow[=name|descriptor]`, `--pid=PID`, `--retry`, `--max-unchanged-stats=N`, `-s/--sleep-interval=N`, hidden inotify/presume options, `--help`, `--version`.
- Currently supported by MSP: Supports `-n`, `-c`, signs, `+N` line operand, common GNU size suffix multipliers, `-q`, `-v`, `-z`, old numeric forms, GNU blank-line header spacing, repeated `-` stdin operands, stdin streaming windows, and range-based file operands for non-follow selection.
- Must implement: No remaining local implementation gap for the current noninteractive MSP surface.
- Deferred with reason: Hidden GNU inotify/presume flags can be deferred as undocumented internals.
- Forbidden by policy: `-f`, `-F`, `--follow`, `--pid`, `--retry`, `--sleep-interval`, and `--max-unchanged-stats` are explicitly rejected because GNU `tail.c` routes them to long-lived file watching, process polling, sleep loops, and retry behavior outside ordinary agent-safe text filtering.
- Performance model: Stdin last-bytes is O(count) memory; last-lines is O(count * average record) and preserves very long records; file operands use `stat` + `readFileRange` with reverse scans for tail records where available; follow is intentionally disabled.
- Oracle/stress gaps: No remaining tail-local oracle/stress gap for the current noninteractive MSP surface. Debian oracle covers primary line/byte/NUL/header cases, while local tests cover follow policy rejection and streaming windows.
- Risk: low - non-follow GNU selection, headers, stdin operands, old-form diagnostics, byte preservation, and policy-shaped follow rejection are covered locally.
- Closure status:
  - Implemented evidence: `MSPHeadTailCommands.swift`; `MSPTextInputCommandTests` covers `+N`, old `+N`/`-Nc` forms, signed bytes, `-z`, GNU header spacing, repeated `-` stdin operands, invalid old-form diagnostics, explicit rejection for `-f`, `-F`, `--follow`, `--retry`, `--pid`, `--sleep-interval`, and `--max-unchanged-stats`, plus missing file behavior; `MSPTextStreamCommandTests` covers streaming last-lines, from-start, and byte window; Core100 oracle fixture has primary `tail` cases and direct parity has `tail -n 1`.
  - Implementation disposition after this batch: Local fixes added GNU standard options, common count suffix multipliers, range-based file operand selection, reverse tail-lines scan, GNU `write_header` blank-line behavior, repeated standard input operand handling, old-form diagnostic coverage, and policy-shaped follow rejection, matching the source shape in `tail.c` (`long_options`, `write_header`, `parse_obsolete_option`, `parse_options`, `tail_bytes`, `tail_lines`, `file_lines`, pipe fallback, and follow setup) within the MSP workspace API.
  - Additional safe sampling candidates: large last-record stress and follow rejection diagnostics can be added to the managed Debian capture set when the coordinator refreshes oracle fixtures.
  - Deferred/forbidden with reason: Hidden GNU inotify/presume options are deferred; `-f`, `-F`, `--follow`, `--pid`, `--retry`, `--sleep-interval`, and `--max-unchanged-stats` are forbidden by default because they create long-lived host/process watchers outside ordinary agent-safe filtering.

## tac

- Command: `tac`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPTacCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tac.c` and `tac-pipe.c` (`longopts`, separator/regex handling, `main`).
- GNU/Linux parameter surface: `tac [OPTION]... [FILE]...`; `-b/--before`, `-r/--regex`, `-s/--separator=STRING`, `--help`, `--version`; stdin and files.
- Currently supported by MSP: Supports `-b`/`--before`, `-r`/`--regex`, `-s`/`--separator`, `--help`, and `--version`; reverses separator-delimited records per input eagerly; outputs with newline delimiter by default; byte-preserving reverse records are covered for simple newline input, and regex separators are covered for UTF-8 text records.
- Must implement: None for the Core100 noninteractive command-local surface.
- Deferred with reason: None.
- Forbidden by policy: None.
- Performance model: Current O(file size) memory per input; true reverse output inherently needs random access, buffering, or temp spill for streams.
- Oracle/stress gaps: None for the Core100 noninteractive command-local surface. Current evidence includes official Debian oracle cases for stdin, file, literal separator, and missing-file status, plus module tests for regex separator, separator-before, missing final delimiter, binary newline records, help, and version.
- Risk: medium - command-local options are covered, but the eager reverse strategy can still stress memory on very large inputs.
- Closure status:
  - Implemented evidence: `MSPTacCommand.swift`; `MSPTextStreamOracleTests` covers stdin, multiple file operands, `-s :`, `-b -s :`, `-r -s '[0-9]+'`, `-b -r`, trailing separators, empty regex separator diagnostics, help/version, missing file, and byte-preserving newline records; Core100 oracle fixture has 4 primary `tac` cases and direct parity has default `tac`.
  - Implementation disposition after this batch: Command-local Core100 surface is closed; future very-large-input spill/random-access optimization belongs with shared WorkspaceFS streaming policy rather than another tac parser change.
  - Parent oracle/stress request: none for command-local closure.
  - Deferred/forbidden with reason: None.

## tee

- Command: `tee`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPTeeCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tee.c` (`long_options`, `main`, output error modes).
- GNU/Linux parameter surface: `tee [OPTION]... [FILE]...`; `-a/--append`, `-i/--ignore-interrupts`, `-p`, `--output-error[=MODE]`, `--help`, `--version`; copies stdin to stdout and each file.
- Currently supported by MSP: Supports `-a`/`--append`; accepts `-i`/`--ignore-interrupts` as a no-op because there are no POSIX signals in MSP; supports `-p` and `--output-error[=warn|warn-nopipe|exit|exit-nopipe]`; treats `-` as an ordinary file operand; handles explicit virtual `/dev/null`, `/dev/stdout`, `/dev/stderr`; streams stdin to stdout and appends chunks to workspace files.
- Must implement: None remaining in the command-local Core100 surface covered by this batch.
- Deferred with reason: Signal-level `-i` behavior can only be a documented no-op unless MSP grows signal delivery; still keep the option accepted.
- Forbidden by policy: File operands must remain inside WorkspaceFS; arbitrary host device files beyond explicit virtual `/dev/null`, `/dev/stdout`, `/dev/stderr` should stay forbidden.
- Performance model: Streaming O(chunk * outputs) memory; current file writes append each chunk and may be expensive for many outputs; stderr mirror buffers if no stderr stream exists.
- Oracle/stress gaps: None for command-local Core100 coverage.
- Risk: medium-low - command-local copy and file error modes are covered; residual risk is shared pipe classification and WorkspaceFS append atomicity.
- Closure status:
  - Implemented evidence: `MSPTeeCommand.swift`; `MSPTextStreamOracleTests` covers stdout copy, `-a`, directory write error, `--output-error=warn`, `--output-error=exit` open failure exiting before stdin is copied, invalid `--output-error`, byte-preserving stdout/file writes, and `-` as an ordinary file operand; `MSPWorkerCRecordStreamCommandTests` covers streaming chunks and append targets without reading the existing file; Core100 oracle fixture has 7 primary `tee` cases.
  - Implementation disposition after this batch: Command-local `tee.c` behavior for append/overwrite, ordinary `-` operands, file open error continuation, exit-on-open-error, GNU standard options, `-p`, and `--output-error[=MODE]` parsing is implemented and tested.
  - Oracle/stress evidence: Existing Linux fixture covers stdout/file copy, append, multiple outputs, binary mirror, one output open error continuing, invalid `--output-error`, and `--output-error=warn`; real broken-pipe stdout behavior and append race semantics belong with shared output-stream and WorkspaceFS policy.
  - Deferred/forbidden with reason: Signal-level `-i` remains a documented no-op until MSP has signal delivery; file operands must stay inside WorkspaceFS and only explicit virtual `/dev/*` targets are allowed.

## tr

- Command: `tr`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPTrCommand.swift` plus `MSPPOSIXRangeSupport.swift` scalar set parser.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tr.c` (`long_options`, set parser, translation tables, `main`).
- GNU/Linux parameter surface: `tr [OPTION]... SET1 [SET2]`; `-c`/`-C`/`--complement`, `-d/--delete`, `-s/--squeeze-repeats`, `-t/--truncate-set1`, character classes, equivalence classes, ranges, repeats, octal escapes, locale classes, `--help`, `--version`; stdin only.
- Currently supported by MSP: Supports `-c`, `-C`, `-d`, `-s`, `-t`/`--truncate-set1`, GNU standard options, operand-count diagnostics, ranges, C-locale POSIX classes, simple C-locale equivalence classes, `[c*n]` repeats, octal escapes, NUL bytes, raw high bytes, complement delete+squeeze, and streaming stdin. ASCII/byte-eligible sets use a 0..255 `TrByteProcessor`; non-byte/multibyte-locale sets still fall back to the scalar path.
- Must implement: None for the current command-local Core100 C-locale byte surface.
- Deferred with reason: Full host locale collation/equivalence and locale-sensitive class expansion are deferred to a shared locale service; implementing that inside `tr` alone would fork cross-command locale behavior.
- Forbidden by policy: None.
- Performance model: Byte-eligible forms build fixed 256-byte translation, delete, and squeeze tables and stream O(1) state plus output chunk size, matching GNU `tr.c`'s table-driven single-byte shape. Non-byte/multibyte fallback remains scalar-based and is intentionally outside the closed Core100 C-locale claim.
- Oracle/stress gaps: None for the current command-local Core100 C-locale byte surface. Shared output-stream conformance still owns downstream broken-pipe/write-error status.
- Risk: medium - the byte/C-locale Core100 surface is closed, while full host-locale parity depends on the future shared locale capability.
- Closure status:
  - Implemented evidence: `MSPTrCommand.swift` now uses `TrByteProcessor` for byte-eligible sets and `MSPPOSIXRangeSupport.swift` covers C-locale POSIX classes plus simple equivalence classes; `MSPTextStreamOracleTests` covers translate, `-t`, delete+squeeze, and missing operand diagnostics; `MSPTextSetCommandPerformanceTests` covers streaming chunks and broken-pipe termination.
  - Oracle/stress evidence: Core100 Debian 12 oracle fixture has 18 primary `tr` cases covering translate, delete, squeeze, complement, octal escapes, raw high bytes, NUL delete/translate, repeats, operand-count diagnostics, POSIX classes, complement delete+squeeze, invalid-byte passthrough, huge byte stream count, and C-locale equivalence. Targeted Core100 oracle passed for all 18 `tr` cases after the equivalence capture was merged.
  - Implementation disposition after this batch: Command-local Core100 C-locale byte/table behavior is closed against `tr.c` for the option and set grammar above. Remaining full host-locale behavior is deferred to the shared locale service rather than a `tr`-local parser patch.
  - Deferred/forbidden with reason: Full host-locale collation/equivalence and locale-sensitive classes are deferred to shared locale capability; no common Core100 C-locale option is deferred.

## uniq

- Command: `uniq`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPUniqCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/uniq.c` (`longopts`, obsolete syntax parser, grouping, `main`).
- GNU/Linux parameter surface: `uniq [OPTION]... [INPUT [OUTPUT]]`; `-c/--count`, `-d/--repeated`, `-D/--all-repeated[=METHOD]`, `--group[=METHOD]`, `-i/--ignore-case`, `-u/--unique`, `-f/--skip-fields=N`, `-s/--skip-chars=N`, `-w/--check-chars=N`, `-z/--zero-terminated`, obsolete `+N`/`-N`, `--help`, `--version`.
- Currently supported by MSP: Supports `-c`, `-d`, `-D`, `-u`, `-i`, `-z`, `-f`, `-s`, `-w`, `--all-repeated[=METHOD]`, `--group[=METHOD]`, obsolete `-N`/`+N`, `--help`, `--version`, and optional input/output operands; streams stdin when no output path; compares adjacent records only; skip/check units are byte based; `-i` uses byte-wise ASCII folding rather than Unicode `String` lowercasing; `-z -f` treats newline as a field separator like `system.h:field_sep`.
- Must implement: None for the current command-local Core100 byte/C-locale surface.
- Deferred with reason: Full host-locale `LC_CTYPE` case folding for `-i` is deferred to a shared locale service; same-input/output safety needs a shared WorkspaceFS identity/write policy before it can match GNU diagnostics.
- Forbidden by policy: Output file stays in WorkspaceFS; no host path writes.
- Performance model: Streaming memory is O(current duplicate run size), which can grow unbounded for `-D`; eager file path is O(total input); output path writes materialized data.
- Oracle/stress gaps: None for the current command-local Core100 byte/C-locale surface.
- Risk: medium - command-local adjacent-record behavior is covered, but large duplicate runs can still grow memory and full locale casefold is shared.
- Closure status:
  - Implemented evidence: `MSPUniqCommand.swift`; `MSPSortUniqCommandTests` covers counts, filters, `-i`, `-w`, `-f`, `-s`, `-D`, `--group`, obsolete skips, output operand, byte-counted multibyte skip/check, byte-wise non-ASCII ignore-case behavior, and `-z -f` newline field separators; `MSPTextStreamOracleTests` covers byte-preserving non-UTF8 adjacent records; Core100 oracle fixture has 9 primary `uniq` cases.
  - Implementation disposition after this batch: Command-local byte/C-locale adjacent-record behavior is closed against `uniq.c` for option parsing, grouping, count output, skip/check byte units, NUL records, and covered invalid UTF-8 cases.
  - Parent oracle/stress request: sample huge duplicate runs and same input/output diagnostics after shared output identity policy is available.
  - Deferred/forbidden with reason: Full host-locale casefold and same-file output identity diagnostics are deferred to shared services above; output writes remain WorkspaceFS-confined.

## unexpand

- Command: `unexpand`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPUnexpandCommand.swift` plus `MSPTextLayoutSupport.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/unexpand.c` and `expand-common.c` (`longopts`, `--first-only`, tab stop parsing, `main`).
- GNU/Linux parameter surface: `unexpand [OPTION]... [FILE]...`; `-a/--all`, `-t/--tabs=LIST`, `--first-only`, obsolete numeric/comma tab syntax, `--help`, `--version`.
- Currently supported by MSP: Supports `-a`, `--all`, `--first-only`, `-t N`, `-tN`, `--tabs=N`, obsolete numeric/list syntax, `/N` and `+N` tab-stop forms, default leading-blank conversion, `-t` implied all-mode, operands and stdin, CR/BS column behavior, byte-preserving invalid input, streaming stdin, and file operands through WorkspaceFS range reads.
- Must implement: None for the current Core100 noninteractive command-local surface.
- Deferred with reason: Full locale/display-width parity is deferred to the shared text-layout locale capability used by `expand`, `fold`, and `wc`; `unexpand` command-local tab/blank behavior is covered for Core100.
- Forbidden by policy: None.
- Performance model: Conversion is line-buffered O(line length), matching the command's line-oriented shape; stdin and file operands consume input incrementally, and file operands read by `readFileRange`. Non-streaming API calls still materialize returned stdout as required by `MSPCommandResult`.
- Oracle/stress gaps: None for the current Core100 noninteractive command-local surface.
- Risk: low for command-local Core100; medium only if future claims depend on full host-locale display width without the shared locale capability.
- Closure status:
  - Implemented evidence: `MSPUnexpandCommand.swift` and `MSPTextLayoutSupport.swift`; `MSPTextLayoutCommandTests` covers default, `-a`, `-t`, obsolete `-4`, comma tab lists, `--first-only`, `/N` and `+N`, multi-file input, invalid tab diagnostics, CR/BS behavior, and invalid-byte preservation; `MSPTextStreamCommandTests` covers completed-line streaming across input chunks and broken-pipe behavior; `MSPWorkerCRecordStreamCommandTests.testExpandAndUnexpandFileOperandsUseRangeReads` proves file operands avoid `readFile`; Core100 oracle fixture has 15 `unexpand` cases covering default, all, tab lists, file/multiple operands, invalid/missing paths, obsolete syntax, `--first-only`, `/+` syntax, carriage returns, and binary invalid bytes.
  - Implementation disposition after this batch: Command-local Core100 surface is closed against `unexpand.c`/`expand-common.c` option and tab-stop shape; file operands now stream through WorkspaceFS range reads.
  - Parent oracle/stress request: none for command-local closure; future work should add shared locale/display-width oracle before claiming full host-locale parity.
  - Deferred/forbidden with reason: Full locale/display-width parity is deferred to shared text-layout locale support.

## wc

- Command: `wc`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPWcCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/wc.c` (`longopts`, `main`, counting engine, `wc_avx2.c` optimization).
- GNU/Linux parameter surface: `wc [OPTION]... [FILE]...`; `-c/--bytes`, `-m/--chars`, `-l/--lines`, `-w/--words`, `-L/--max-line-length`, `--files0-from=FILE`, `--debug`, `--help`, `--version`; locale-aware character, word, and display-width counting.
- Currently supported by MSP: Supports `-c`, `-m`, `-l`, `-w`, `-L`, `--files0-from=FILE|-`, `--debug`, GNU standard options, stdin and `-` operands, totals for multiple operands, invalid-byte skipping for UTF-8 character/word counting, NUL bytes, wide/combining/tab display widths, and file operands through WorkspaceFS range reads.
- Must implement: None for the current Core100 noninteractive command-local surface.
- Deferred with reason: Full locale database parity for `iswspace`, `iswprint`, `isnbspace`, and `wcwidth` remains a shared locale/collation capability, not a `wc`-local parser or performance fix. `--debug` is accepted and Debian 12 oracle-matched for normal counting; any future explanatory diagnostics for unusual locale/encoding paths should be added with the shared locale capability.
- Forbidden by policy: `--files0-from` paths must be WorkspaceFS-confined.
- Performance model: Stdin and file operands count incrementally with O(UTF-8 remainder) memory plus O(1) counters; file operands use `readFileRange` when the WorkspaceFS backend provides it. `--files0-from=FILE` may materialize the NUL name list like GNU's small regular-file `readtokens0` path; the listed files themselves are streamed by range reads.
- Oracle/stress gaps: None for the current Core100 noninteractive command-local surface.
- Risk: low for the Core100 command-local surface; medium if future work claims full host-locale parity without first adding a shared locale service.
- Closure status:
  - Implemented evidence: `MSPWcCommand.swift`; `MSPTextInputCommandTests` covers stdin/dash/totals, byte-only formatting, wide/combining/tab display width, NUL bytes, invalid UTF-8, `--files0-from`, `--debug`, and GNU standard options; `MSPTextStreamCommandTests` covers chunk-boundary UTF-8 streaming; `MSPWorkerCRecordStreamCommandTests.testWcFileOperandsUseRangeReads` proves file operands use WorkspaceFS range reads instead of `readFile`; `MSPTextStreamOracleTests` covers file totals, missing file, and common count modes; Core100 Debian 12 oracle fixture has 12 `wc` cases covering lines, bytes, chars, totals, `--files0-from` file/stdin/empty list, NUL bytes, invalid UTF-8, long line width, missing+present ordering, and `--debug`.
  - Implementation disposition after this batch: Command-local Core100 surface is closed against `wc.c`'s option table and counting shape. The implementation now follows GNU's stream-counting model more closely by decoding valid UTF-8 scalars from bytes, skipping invalid byte sequences for `-m/-w/-L`, and counting file operands incrementally through range reads.
  - Parent oracle/stress request: none for command-local closure; future work should add shared locale-service oracle before claiming full host-locale parity.
  - Deferred/forbidden with reason: Full locale database parity is deferred to a shared locale capability; `--files0-from` paths remain WorkspaceFS-confined by policy.

## yes

- Command: `yes`
- MSP implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPYesCommand.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/yes.c` (`main`, `parse_gnu_standard_options_only`, repeated buffer writer).
- GNU/Linux parameter surface: `yes [STRING]...` or `yes OPTION`; default string `y`; operands joined by spaces; repeats until write error; `--help`, `--version`.
- Currently supported by MSP: Joins arguments with spaces and appends newline; supports Debian 12 `--help` and `--version` byte text from VPS oracle; non-streaming path caps generated output around 64 KiB; streaming path repeats until task cancellation or broken pipe with chunking for async pipes.
- Must implement: None for the Core100 noninteractive command surface. Exact write-error status beyond broken pipe is owned by the shared output-stream failure contract rather than by `yes` parsing or generation.
- Deferred with reason: None.
- Forbidden by policy: Unbounded model-visible output without a stream, cancellation, or output budget is forbidden; the current non-streaming cap is a necessary agent-safety boundary.
- Performance model: Streaming is O(record or chunk size) memory and infinite time until cancelled or broken pipe; non-streaming is bounded O(64 KiB) output, intentionally not GNU-infinite.
- Oracle/stress gaps: None for the current Core100 noninteractive surface. Existing oracle covers default, operand-joined, shell stress `yes | head`, and Debian `--help`/`--version`; unit coverage covers streaming broken-pipe termination.
- Risk: low - the remaining divergence is the documented MSP agent-safety output budget for non-streaming infinite output.
- Closure status:
  - Implemented evidence: `MSPYesCommand.swift`; `MSPTextStreamCommandTests` covers broken-pipe termination in streaming mode; Core100 oracle fixture has 4 primary `yes` cases including Debian 12 `--help`/`--version`, shell-stress includes `yes | head`, and direct parity has `yes ok | head -n 2`.
  - Implementation disposition after this batch: Command-local Core100 surface is closed. Shared output-stream failure semantics remain a runtime contract and do not require `yes`-local option/parser work.
  - Parent oracle/stress request: none for command-local closure; future runtime-level output-failure tests should live with shared pipeline/write-error conformance.
  - Deferred/forbidden with reason: Unbounded non-streaming model-visible output is forbidden; the current bounded non-streaming cap is an agent-safety divergence that must stay documented.
