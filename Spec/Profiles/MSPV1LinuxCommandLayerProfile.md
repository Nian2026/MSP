# MSP v1 Linux Command Layer Profile

This profile defines the complete MSP v1 Linux-like command layer. It is not a
sample subset and it is not a starter command pack. A conforming MSP v1 SDK
must either implement every command listed here or carry a documented temporary
deferral with a concrete rationale.

## Public Contract

- Agent input remains a single `exec_command` call with a `cmd` string.
- Agent output remains plain shell text, not JSON.
- All file access goes through WorkspaceFS.
- Agent-visible paths are virtual workspace paths rooted at `/`.
- Host sandbox paths must not appear in stdout, stderr, or diagnostics.
- App-specific commands are extensions, not part of this generic profile.
- External binaries are integrated through the external-runner capability; this
  profile does not require MSP to bundle third-party binaries.

## Required Commands

### Shell State And Builtins

- `:`
- `cd`
- `command`
- `builtin`
- `type`
- `env`
- `test`
- `[`
- `[[`
- `true`
- `false`
- `pwd`
- `echo`
- `printf`

### Filesystem And Paths

- `ls`
- `cat`
- `cp`
- `mv`
- `rm`
- `mkdir`
- `touch`
- `ln`
- `chmod`
- `stat`
- `du`
- `mktemp`
- `basename`
- `dirname`
- `readlink`
- `realpath`

### Text, Search, And Streams

- `grep`
- `rg`
- `sed`
- `awk`
- `xargs`
- `find`
- `head`
- `tail`
- `wc`
- `tac`
- `cut`
- `nl`
- `sort`
- `uniq`
- `tr`
- `join`
- `comm`
- `paste`
- `tee`
- `diff`
- `cmp`

### Data, Checksums, And Binary Views

- `base64`
- `od`
- `xxd`
- `md5sum`
- `sha1sum`
- `sha256sum`
- `cksum`

### Numeric, Time, Metadata, And Process Utilities

- `date`
- `file`
- `numfmt`
- `seq`
- `yes`
- `bc`
- `timeout`
- `which`
- `ldd`
- `ps`

## Required Shared Shell Semantics

These capabilities are part of the profile. They must be implemented in shared
shell/runtime layers, not by adding command-local special cases.

- full AST execution for parsed command lines
- command lookup and resolution
- mutable current working directory
- environment assignment and propagation
- parameter expansion
- quote handling
- word splitting
- pathname expansion
- stdin/stdout/stderr stream propagation
- input, output, append, and descriptor redirection
- heredoc processing
- pipeline execution
- `&&`, `||`, `;`, and negation exit semantics
- shell status propagation
- WorkspaceFS path resolution
- host-path redaction

## Required Runtime Special Builtins

These are part of the shell runtime rather than the standalone POSIX core
command pack. A conforming MSP v1 shell still exposes them through normal text
execution and command lookup.

Implemented runtime special builtins:

- `.`
- `break`
- `continue`
- `declare` for scalar, indexed-array, associative-array, and nameref declarations, `-p`, lookup visibility, and pipeline-isolated state
- `eval`
- `exec`
- `exit`
- `local`
- `mapfile` for stdin-to-indexed-array assignment with `-t`, `-u 0`, `-n`, `-s`, and `-O`
- `read`
- `readarray` as `mapfile` compatibility alias
- `return`
- `set --`
- `set -e/+e`
- `set -f/+f`
- `set -u/+u`
- `set -o/+o pipefail`
- `sh` as an in-process shell launcher compatibility entry for `-c`, script
  files, stdin scripts, `-n`, and supported option state
- `shift`
- `bash` as the same in-process launcher surface, including `--noprofile` and
  `--norc` acceptance
- `shopt -s/-u/-p/-q`
- `shopt` option state for `nullglob`, `failglob`, `dotglob`, `nocaseglob`, `extglob`, and `globstar`
- `source`
- `trap` for `EXIT`/`0` run-end handlers, reset, `-p`, `-l`, common signal registration/listing, and lookup visibility
- `typeset` as the current `declare` compatibility alias surface
- `umask`
- `unset`
- `zsh` as the same in-process launcher compatibility surface

Pending runtime special-builtin parity audits and compatibility boundaries:

- deeper `typeset` alias parity beyond the current `declare` compatibility surface
- full shell-language and startup-file parity for specific host shells beyond
  the MSP in-process launcher surface

## Current MSP Core Coverage Snapshot

The current `posix-core` pack is tracked by
`Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`.
At this checkpoint it implements 68 of the 68 required command names.
The MSP-native command classification table lives in
`Conformance/Inventory/MSPV1LinuxCommandLayerInventory.md`.
The executable conformance smoke corpus lives in
`Conformance/Fixtures/MSPV1LinuxCommandLayer.parity-cases.json`.
The per-command parity corpus lives in
`Conformance/Fixtures/MSPV1LinuxCommandLayer.direct-parity-cases.json`.
Digest commands now support checksum generation plus `-c`/`--check`
verification and `--status` quiet verification. Coverage lives in
`MSPDataAndTextCommandTests` and the MSP v1 parity fixtures.
`od` now follows GNU coreutils 9.1 integer-format output for default octal
2-byte dumps, `-A d/o/x/n`, `-j`/`-N`, optional-value `-w`, duplicate-block
abbreviation, traditional `-b`/`-c`/`-d`/`-o`/`-x` options, `-t` integer
formats including `x/o/u/d` byte widths, `z` character trailers, multi-format
rows, and `--endian=big|little`. Coverage lives in
`MSPDataAndTextCommandTests` and the MSP v1 parity fixtures with stdout strings
captured from a Debian GNU coreutils 9.1 reference host.
`date` now supports GNU-style selected-date output for `-d`/`--date` epoch
strings, optional-value `-I[=FMT]`/`--iso-8601[=FMT]`, `--rfc-3339=FMT`, and
additional `strftime`-style tokens such as `%e`, `%D`, `%j`, `%u`, `%w`, and
`%y`. Coverage lives in `MSPDataAndTextCommandTests` and the MSP v1 parity
fixtures.
`seq` now follows GNU coreutils 9.1 output for one-, two-, and three-operand
ranges, including the GNU rule that an omitted increment remains `1` even when
`LAST < FIRST`, decimal default precision, `-s`/`--separator`, `-f`/`--format`
with common floating-point directives and literal prefixes/suffixes,
`-w`/`--equal-width` zero padding, and GNU-style usage diagnostics for invalid
operands, extra operands, zero increments, and `-f` plus `-w` conflicts.
Coverage lives in `MSPDataAndTextCommandTests` and the MSP v1 parity fixtures
with stdout/stderr strings captured from a Debian GNU coreutils 9.1 reference
host.
`ln` now supports default hard-link creation through WorkspaceFS and symbolic
links through `-s`/`--symbolic`, with conformance coverage proving hard-link
writes are reflected through the original source path.
`find` now uses a parsed expression evaluator for `-name`/`-iname`,
`-path`/`-ipath`, `-regex`/`-iregex`, `-type f/d/l`, `-empty`, permission,
size, time, `-newer`, boolean `!`/`-a`/`-o`, `-prune`, `-print`, `-print0`,
`-printf`, `-exec ... {} ;`, `-exec ... {} +`, and `-quit` over WorkspaceFS
virtual paths. Its `-printf` formatter covers field width, precision,
left-alignment, zero-padding, common path/metadata conversions, and
`%A`/`%C`/`%T` time sub-directives. Coverage lives in
`ModelShellProxySmokeTests` and the MSP v1 parity fixtures.

Shared shell semantics are still audited separately from command-name coverage.
Any gaps in parsing, expansion, redirection, heredocs, or logical-list execution
must be fixed in shared shell/runtime layers, not by adding command-local
special cases.

Current shared-runtime evidence:

- Pipeline execution is covered by `ModelShellProxySmokeTests`.
- `&&` / `||` logical-list short-circuit execution is covered by
  `testLogicalListsShortCircuitThroughSharedShellRuntime`.
- Pipeline negation exit semantics (`! pipeline`) are covered by
  `testLogicalListsShortCircuitThroughSharedShellRuntime`.
- Pipeline status array semantics now update `PIPESTATUS` for single-command
  and multi-stage pipelines using raw stage exit codes, while `$?` still follows
  ordinary, `pipefail`, and negated-pipeline exit semantics. Coverage lives in
  `testSetShellOptionsRunThroughSharedShellRuntime`.
- Internal stdout/stderr transport is byte-preserving through
  `MSPCommandResult`, pipelines, redirections, and process substitution
  materialization, while the agent-facing exec bridge still renders plain text.
  Coverage includes `base64 -d` producing `0xff` through a pipe into `od` and
  through `>` redirection into a WorkspaceFS file.
- Basic file/stdin/stdout/stderr redirection (`<`, `>`, `>>`, `2>`, `&>`,
  heredoc, here-string, and `/dev/null` as an empty input device) is covered by
  `testRedirectionsRunThroughWorkspaceFSAndSharedShellRuntime` and
  `testClosedStandardInputIsNotTreatedAsEmptyInput`.
- Basic descriptor routing for fd 1/2 duplication (`2>&1`, `1>&2`, `>&file`)
  and default-stdin read/write open-file descriptions (`<>`) is covered by
  `testRedirectionsRunThroughWorkspaceFSAndSharedShellRuntime`.
- Descriptor routing now includes fd table entries beyond 0/1/2 for persistent
  and scoped redirections such as `exec 3>file`, `exec 3<file`, `>&3`, `<&3`,
  descriptor close operations, `read -u N`, `mapfile -u N`, duplicated input
  descriptors sharing read offsets, and `<>` read/write descriptors sharing
  read/write offsets across `>&` and `<&` duplication. Closed fd 0 now remains
  distinct from empty stdin for shared POSIX input readers and shell `read`.
  Coverage lives in
  `testExecPersistentRedirectionsRunThroughSharedShellRuntime` and
  `testScopedRedirectionsOverlayPersistentFileDescriptors`, with closed-stdin
  behavior covered by `testClosedStandardInputIsNotTreatedAsEmptyInput`.
- Shared expansion now preserves parsed word structure through
  `MSPParsedWord` and applies parameter expansion, quote-aware word splitting,
  pathname expansion, arithmetic expansion, special `$?`, and
  redirection-target expansion at command execution time. Coverage lives in
  `testExpandsParametersWordSplittingAndPathnamesThroughSharedLayer` and
  `testExpansionUsesCurrentShellStateAndWorkspaceFS`.
- Shared command substitution supports `$()` and backticks through the same
  shell runtime, including quoting, word splitting, WorkspaceFS reads, stderr
  propagation, inherited `$?`, and subshell-like state isolation. Coverage lives
  in `testCommandSubstitutionRunsThroughSharedShellRuntime`.
- Shared process substitution supports `<(...)` and `>(...)` through the same
  shell runtime and WorkspaceFS path layer. Input substitutions materialize
  child stdout as temporary workspace files, output substitutions route written
  data into the child command, and fd-backed output substitutions finalize when
  the fd is closed. Coverage lives in
  `testProcessSubstitutionRunsThroughSharedShellRuntime`.
- Advanced string parameter expansion now covers length, substring, prefix and
  suffix glob removal, single/global replacement, and case modification.
  Coverage lives in `testExpandsAdvancedStringParametersThroughSharedLayer` and
  `testAdvancedStringParameterExpansionRunsThroughSharedShellRuntime`.
- Arithmetic command and expansion execution now supports expression exit
  semantics, comma-separated parts, scalar/indexed-array/associative-array
  assignment and update operators, nameref-resolved lvalues, redirection,
  command substitution, logical-list behavior, C-style `for` mutation, and
  pipeline state isolation. Coverage lives in
  `testExtractsArithmeticCommandAsExecutableShellSemantic` and
  `testArithmeticCommandRunsThroughSharedShellRuntime`.
- Group and subshell compound command execution now runs through the shared
  shell runtime. Group commands preserve parent shell environment/current
  directory when state changes are allowed, subshell commands isolate those
  state changes, filesystem mutations remain in the shared WorkspaceFS, and
  compound redirection, pipeline state isolation, and logical-list behavior are
  covered by
  `testExtractsGroupAndSubshellCompoundCommandsAsExecutableShellSemantics` and
  `testGroupAndSubshellCompoundCommandsRunThroughSharedShellRuntime`.
- Structured compound control flow now carries parsed AST structure through the
  shell facade and executes ordinary `if` / `elif` / `else`, `while`, `until`,
  explicit-value `for`, C-style `for`, `case`, and `while read` forms in the
  shared runtime. Coverage lives in
  `testExtractsStructuredCompoundCommandsAsExecutableShellSemantics` and
  `testStructuredCompoundCommandsRunThroughSharedShellRuntime`.
- Shell function definitions and invocation now run through the shared shell
  runtime, including `name() { ...; }`, `function name { ...; }`, subshell
  bodies, definition-time and call-time redirection, positional parameters,
  quoted positional-parameter field expansion such as `"$@"`, embedded forms
  like `pre"$@"post`, function-local `return`, implicit positional-parameter
  `for`, function precedence over registered commands, explicit
  `command`/`builtin` bypass, and subshell-style isolation for pipeline and
  command-substitution child environments. Coverage lives in
  `testExtractsFunctionDefinitionsAsExecutableShellSemantics` and
  `testShellFunctionsRunThroughSharedShellRuntime`.
- Non-local shell control flow now runs through the shared shell runtime:
  `break` and `continue` affect enclosing loops with numeric levels, `exit`
  stops the current command run with shell-style numeric status handling, and
  command-substitution children isolate those control effects from the parent
  shell. Coverage lives in
  `testKeepsShellControlCommandsInsideCompoundBodies` and
  `testLoopControlAndExitRunThroughSharedShellRuntime`.
- Core persistent `exec` redirection now runs through the shared shell runtime
  for standard descriptors: fd 0 input binding, fd 1/fd 2 output binding,
  append/truncate behavior, `2>&1`, pipeline capture, `|&`, command
  substitution stdout capture, WorkspaceFS-only output paths, and `<>`
  read/write open-file-description offset sharing. Coverage lives in
  `testExecPersistentRedirectionsRunThroughSharedShellRuntime`.
- Scoped redirection overlays now compose with persistent fd 1/fd 2 bindings
  and fd table entries beyond 0/1/2 for compound commands, shell functions,
  `eval`, `source`, and shell launcher compatibility entries. Output
  redirections temporarily override the touched descriptors, input-only
  redirections do not restore unrelated output descriptor changes, function
  definition redirections run at invocation time, untouched descriptors opened
  inside brace groups remain live like bash, and runtime special builtins such
  as `exec` are visible to shell lookup commands. Coverage lives in
  `testScopedRedirectionsOverlayPersistentFileDescriptors` and
  `testAdditionalLinuxCoreCommandsRunThroughWorkspaceAndShellState`.
- `eval` now re-enters the shared parser/runtime with expanded command text,
  preserves state changes when it runs in the parent shell, scopes ordinary
  redirections like other compound runtime forms, propagates `return` and
  `exit`, and remains isolated in pipelines. `shift` now mutates the current
  positional-parameter frame and is isolated in pipeline children. Both are
  visible to `command -v` and `type`. Coverage lives in
  `testEvalAndShiftRunThroughSharedShellRuntime`.
- `set --`, `unset`, `local`, and standalone `read` now run through the shared
  runtime. `set --` updates positional parameters, `unset -v/-f` removes
  variables or shell functions, `local` restores function-local scalar,
  indexed-array, associative-array, and nameref state on return, and `read`
  assigns fields from shell stdin including `-r`, `-d`, `-n`, and `-u 0`.
  Coverage lives in
  `testSetUnsetLocalAndReadRunThroughSharedShellRuntime`.
- `set` shell options now run through shared shell state for the core
  Linux-compatible option surface: `-e/+e` controls errexit in ordinary list
  positions, `-f/+f` controls pathname expansion, `-u/+u` controls nounset
  parameter expansion, and `-o/+o pipefail` controls pipeline exit status. The
  option state is saved and restored with pipeline/subshell/function/source
  runtime isolation, and condition positions suppress errexit. Coverage lives
  in `testSetShellOptionsRunThroughSharedShellRuntime`.
- `shopt` now runs through shared shell state with `-s`, `-u`, `-p`, and `-q`.
  Its recognized option state is visible to command lookup and drives
  WorkspaceFS pathname expansion for `nullglob`, `failglob`, `dotglob`,
  `nocaseglob`, `extglob`, and `globstar`, with pipeline isolation preserved.
  Coverage lives in
  `testShoptRunsThroughSharedShellRuntimeAndPathnameExpansion`.
- `source` and `.` now read scripts through WorkspaceFS and execute them in
  the current shell runtime. Sourced scripts can mutate environment, current
  directory, and shell functions, temporarily replace positional parameters
  when arguments are supplied, consume `return` as the source command status,
  honor scoped redirection, and remain isolated in pipelines. Coverage lives in
  `testSourceRunsWorkspaceScriptsInCurrentShellRuntime`.
- `umask` now runs as shared shell runtime state rather than a standalone
  command. It supports default octal output, `-p`, `-S`, octal masks, common
  symbolic masks, pipeline/subshell isolation, command lookup visibility, and
  WorkspaceFS creation modes for redirection, `touch`, `mkdir`, `tee`, and
  related file writers. Coverage lives in
  `testUmaskRunsThroughSharedShellRuntimeAndWorkspaceCreationModes`.
- `trap` now runs as shared shell runtime state rather than a standalone
  command. It supports `EXIT`/`0` handlers at top-level command-run completion,
  reset via `trap - SIGNAL`, `trap SIGNAL`, listing via `trap`/`trap -p`,
  signal-name listing via `trap -l`, common signal canonicalization, pipeline
  isolation, command lookup visibility, and bash-style re-readable output.
  Common OS signals can be registered and listed, but real process signal
  delivery is outside the in-process command layer. Coverage lives in
  `testTrapRunsThroughSharedShellRuntime`.
- Indexed-array shell state now runs through the shared parser, expansion, and
  runtime layers. Assignment-only arrays, append assignment, sparse subscript
  assignment such as `array[5]=value`, subscript append, `${array[0]}`,
  `"${array[@]}"`, `${array[*]}`, `${#array[@]}`, `${!array[@]}`, `unset`,
  pipeline isolation, and `mapfile`/`readarray` stdin loading are covered by
  `testIndexedArraysAndMapfileRunThroughSharedShellRuntime`.
- `declare` and the current `typeset` alias surface now run through shared
  shell state for scalar declarations, indexed-array declarations,
  associative-array declarations and subscript assignment, nameref declarations
  and scalar/associative-array mutation through references, `declare -p`,
  lookup visibility, invalid identifiers, and pipeline isolation. Coverage lives
  in `testDeclareAndTypesetRunThroughSharedShellRuntime` and
  `testAssociativeArraysAndNamerefsRunThroughSharedShellRuntime`.
- `sh`, `bash`, and `zsh` now run as in-process shell launcher compatibility
  entries through the shared MSP runtime rather than bundled host binaries. The
  current surface covers `-c command [name args...]`, WorkspaceFS script files,
  stdin scripts, syntax check mode (`-n`), `-e`, `-u`, `-o/+o` for `errexit`,
  `nounset`, and `pipefail`, child-shell state isolation, redirection, and
  lookup visibility. Coverage lives in
  `testShellLaunchersRunWorkspaceScriptsAsIsolatedRuntime`.
- Full bash arithmetic operator parity, full array parameter expansion, full
  shell variable attributes, full bracket glob classes/options, deeper nameref
  cycle/attribute parity, and full host-specific shell-language/startup-file
  parity still require separate parity audits before the profile can be called
  complete.

## Conformance Evidence

A command is accepted into this profile only when all relevant evidence exists:

- SDK implementation under MSP-native naming.
- Unit tests for option parsing, file handling, stdin behavior, and errors.
- Linux/coreutils parity fixtures for stdout, stderr, and exit code.
- WorkspaceFS tests proving host-path redaction.
- Agent bridge tests proving plain-text `exec_command` output.
- iOS demo proof through profile enablement, not demo-local command wiring.

## Semantic References

MSP command behavior should be checked against real Linux implementations and
documented behavior, including Debian shell and command source packages such as
GNU coreutils, bash, dash, findutils, grep, sed, mawk, and ripgrep. Existing app
implementations may be used as migration references, but public MSP behavior is
defined by this profile, conformance fixtures, and Linux-compatible observable
semantics.
