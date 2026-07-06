# Batch 01 Shell/Path/Runtime Command Compatibility Draft

Source-backed compatibility matrix for the batch-01 command set only. Evidence was checked against the MSP Swift implementation under `Implementations/Swift/Sources/MSPPOSIXCore` and `Implementations/Swift/Sources/ModelShellProxy`, the command fixture `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`, and vendored Debian 12 sources under `References/LinuxSourceSnapshot/debian12-bookworm/sources/`.

## `:`

- Command: `:`
- MSP implementation: `MSPNoopCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPShellBuiltinCommands.swift`; registered by `MSPPOSIXCoreCommandPack`.
- Reference source: Bash `builtins/colon.def` (`colon_builtin`); dash `src/builtins.def.in` maps `:` to `truecmd`.
- GNU/Linux parameter surface: shell builtin null command; accepts ignored operands through normal shell parsing; no command-local options.
- Currently supported by MSP: returns exit 0 and no output for any arguments passed to the command implementation.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none.
- Forbidden by policy: none beyond existing WorkspaceFS redirection policy.
- Performance model: O(1) command body; shell expansion and redirection cost are owned by `ModelShellProxy`.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: low; command body is trivial, but shell-front-end side effects can still regress.

### Closure status

- Implemented evidence: `MSPNoopCommand` is registered and returns exit 0 with no output for all operands; existing Core100 coverage includes bare `:` and redirection smoke, and stress cases exercise `:` inside shell control flow.
- Command-local status: none in the command body. Assignment, expansion, and redirection side effects are owned by the shared shell front end and cannot be fixed in the allowed Batch 01 command file.
- Safe oracle notes: none that a Batch 01 command-local worker can promote; coordinator should sample `VAR=value :`, assignment-only persistence checks, expansion-error ordering, redirection-denied failures, and byte-level stderr.
- Deferred/forbidden with reason: deferred to shared shell runtime for assignment/redirection semantics; WorkspaceFS policy must continue forbidding host-escape redirections.

## `[`

- Command: `[`
- MSP implementation: `MSPTestCommand(name: "[")` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPTestCommand.swift`; registered by `MSPPOSIXCoreCommandPack`.
- Reference source: Bash `builtins/test.def` (`test_builtin`); Bash `test.c` (`test_command`, `unary_operator`, `binary_operator`); coreutils `src/test.c` / `src/lbracket.c`; dash `src/bltin/test.c`.
- GNU/Linux parameter surface: closing `]`; 0/1/2/3/N argument POSIX test grammar; `!`, parentheses, `-a`, `-o`; string `-n`, `-z`, `=`, `==`, `!=`, `<`, `>`; integers `-eq`, `-ne`, `-gt`, `-ge`, `-lt`, `-le`; files `-a`, `-b`, `-c`, `-d`, `-e`, `-f`, `-g`, `-G`, `-h`, `-L`, `-k`, `-N`, `-O`, `-p`, `-r`, `-s`, `-S`, `-t`, `-u`, `-w`, `-x`; file comparisons `-ef`, `-nt`, `-ot`; GNU external `[` also honors `--help` and `--version` in its special no-closing-bracket form.
- Currently supported by MSP: requires final `]`; supports empty/string truth, `!`, parentheses, `-a`, `-o`, unary `-n`, `-z`, common file predicates (`-a`, `-b`, `-c`, `-d`, `-e`, `-f`, `-g`, `-G`, `-h`, `-k`, `-L`, `-N`, `-O`, `-p`, `-r`, `-s`, `-S`, `-t`, `-u`, `-w`, `-x`) with WorkspaceFS/virtual limits, string `=`, `==`, `!=`, `<`, `>`, integer comparisons, and file comparisons `-ef`, `-nt`, `-ot`.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: terminal truth for `-t FD` may need a virtual TTY model; until MSP has PTY/session state, implement deterministic non-PTY semantics and defer real interactive terminal detection.
- Forbidden by policy: exposing host device/inode ownership directly for `-O`, `-G`, `-ef`, or `-t`; results must be WorkspaceFS/virtual identity based.
- Performance model: current evaluator is O(argument count) and eager; full expression parsing remains O(tokens), while file predicates add one WorkspaceFS stat/lstat per operand.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; current support is a small subset of `[` and can silently misclassify common shell conditionals.

### Closure status

- Implemented evidence: `MSPTestCommand(name: "[")` enforces closing `]`, now shares the recursive `test` parser for `!`, parentheses, `-a`, `-o`, string `<`/`>`, common unary predicates, and file comparisons; `MSPShellBuiltinCommandTests.testTestCommandSupportsCommonFilePredicatesAndIntegerDiagnostics` covers compound expressions, permission predicates, symlink predicate, `-nt`, `-ef`, and diagnostics.
- Command-local status: Bash-only `-o OPTION`, `-v VAR`, `-R VAR`, and external-GNU `[` no-closing-bracket `--help`/`--version` behavior remain outside the current command-local shell-builtin surface; full device/uid/gid/inode fidelity is not representable in WorkspaceFS today.
- Safe oracle notes: VPS sampling should cover exhaustive POSIX truth tables, ambiguous three/four argument precedence, symlink/stat/permission matrices, file-comparison byte parity, and invalid-expression stderr. Safe case drafts: `[ '(' -n x -a 3 -gt 2 ')' -o a = b ]`, `[ file1 -nt file2 ]`, `[ file1 -ef file1 ]`, `[ -u file ]`, `[ -g file ]`, `[ -L link ]`, `[ a '<' b ]`.
- Deferred/forbidden with reason: real `-t FD` terminal detection is deferred until virtual TTY/session state exists; host uid/gid/device/inode/tty leakage is forbidden and must be virtualized.

## `[[`

- Command: `[[`
- MSP implementation: `MSPTestCommand(name: "[[")` plus `executeDoubleBracketRegexCommand` in `Implementations/Swift/Sources/ModelShellProxy/ModelShellProxy.swift` for three-token `lhs =~ regex`; registered by `MSPPOSIXCoreCommandPack`.
- Reference source: Bash parser `parse.y` (`COND_START`, `COND_END`, `parse_cond_command`, `cond_term`); Bash executor `execute_cmd.c` (`execute_cond_node`); Bash `test.c` helpers for unary/binary predicates.
- GNU/Linux parameter surface: Bash conditional compound command, not a coreutils executable; supports `!`, parentheses, `&&`, `||`, unary and binary test operators, pattern matching for `=`/`==`/`!=`, locale-aware `<`/`>`, arithmetic comparisons, regex `=~`, quote-sensitive RHS behavior, and `BASH_REMATCH` side effects.
- Currently supported by MSP: final `]]` checked in `MSPTestCommand`; simple command-shaped test expressions share the broader `MSPTestCommand` evaluator; glob equality/inequality is supported for simple `=`/`==`/`!=`; `lhs =~ regex` works only as exactly three tokens and updates `BASH_REMATCH` on match.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: locale collation and extglob-correct pattern semantics can be staged if the shell pattern engine is not complete, but only after oracle cases identify the exact unsupported cases.
- Forbidden by policy: host filesystem/device identity leakage through file predicates; use WorkspaceFS and virtual identity.
- Performance model: current implementation is eager and O(arguments) plus regex compile/match for `=~`; full implementation should parse a conditional AST once, short-circuit boolean nodes, and cap regex work through existing command limits/cancellation.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; current implementation is command-shaped, while bash `[[` is syntax with materially different parsing and expansion rules.

### Closure status

- Implemented evidence: `MSPTestCommand(name: "[[")` now shares the broader test parser for simple command-shaped conditionals and glob equality/inequality, while `ModelShellProxy.executeDoubleBracketRegexCommand` handles the existing exact three-token `lhs =~ regex` path and `BASH_REMATCH` update.
- Command-local status: none can be completed inside the allowed command implementation file without changing `MSPShell`/`ModelShellProxy`; real bash `[[` is syntax, so internal `&&`/`||`, quote-sensitive expansion, regex lifecycle, parse diagnostics, and proper conditional AST execution require shared runtime work.
- Safe oracle notes: VPS sampling should cover capture groups, failed regex cleanup, quoted vs unquoted RHS, nested boolean expressions, syntax errors, pattern edge cases, file predicates inside `[[`, and `BASH_REMATCH` persistence. Safe case drafts: `[[ abc =~ (a)(b) ]]`, `[[ abc == a* ]]`, `[[ abc == 'a*' ]]`, `[[ -n x && 3 -gt 2 ]]`.
- Deferred/forbidden with reason: deferred to shared parser-executor because `[[` is not a normal argv command; locale collation/extglob policy may be staged there; host filesystem identity leakage through predicates is forbidden.

## `basename`

- Command: `basename`
- MSP implementation: `MSPBasenameCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Path/MSPBasenameCommand.swift`.
- Reference source: coreutils `src/basename.c` (`longopts`, `perform_basename`, `main`).
- GNU/Linux parameter surface: `basename NAME [SUFFIX]`; `basename OPTION... NAME...`; `-a`/`--multiple`; `-s SUFFIX`/`--suffix=SUFFIX` implying `-a`; `-z`/`--zero`; `--help`; `--version`; POSIX edge behavior for roots, trailing slashes, empty strings, and `//`.
- Currently supported by MSP: `NAME [SUFFIX]`; `-a`, `--multiple`, `-s`, `--suffix`, `-z`, `--zero`, `--help`, `--version`; stops option parsing at first operand like coreutils' leading `+` getopt mode; pure string path handling.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none.
- Forbidden by policy: none; command must remain pure string/path transformation with no host stat.
- Performance model: O(total input path bytes), eager string processing, output proportional to operands.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: medium; option surface is mostly present, but path edge cases and GNU meta options are not proven.

### Closure status

- Implemented evidence: `MSPBasenameCommand` supports `NAME [SUFFIX]`, `-a`/`--multiple`, `-s`/`--suffix`, `-z`/`--zero`, `--help`, and `--version`; `MSPPathCommandTests.testBasenameSupportsGNUCoreutilsPathOptions` covers suffix operands, multiple mode, long suffix, empty suffix, NUL output, missing/extra operands, invalid option, missing `-s`, help, and version.
- Command-local status: none in the common GNU option surface after this batch; double-slash `//` behavior is a platform edge that must be oracle-locked before changing string semantics.
- Safe oracle notes: VPS sampling should cover empty string, root, `//`, trailing-slash, long-option, unsupported-option, and byte-level NUL fixtures. Safe case drafts: `basename ''`, `basename /`, `basename //`, `basename -az /tmp/a /tmp/b`.
- Deferred/forbidden with reason: `//` is deferred pending Debian oracle because POSIX permits implementation-defined double-slash treatment; host stat/path probing is forbidden because basename must remain a pure string transform.

## `builtin`

- Command: `builtin`
- MSP implementation: `MSPBuiltinCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPSubcommandUtilityCommands.swift`; lookup list in `MSPShellBuiltinCommands.swift`; runtime dispatch through `ModelShellProxy.makeSubcommandRunner`.
- Reference source: Bash `builtins/builtin.def` (`builtin_builtin`).
- GNU/Linux parameter surface: `builtin [shell-builtin [arg ...]]`; `--` option terminator; invalid option handling; executes an enabled shell builtin directly and returns false when the name is not a shell builtin.
- Currently supported by MSP: optional `--`; checks a static shell-builtin name set; delegates to subcommand runner with same standard input/environment.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: disabled-builtin support is deferred because MSP has no `enable -n`/loadable builtins model yet.
- Forbidden by policy: using `builtin` to bypass MSP policy; delegated builtins must still pass the same policy and WorkspaceFS checks.
- Performance model: O(1) lookup plus delegated command cost; no streaming work in wrapper.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: medium; wrapper is small, but bypass semantics are security-sensitive.

### Closure status

- Implemented evidence: `MSPBuiltinCommand` accepts optional `--`, checks `mspPOSIXShellBuiltinNames`, delegates through the subcommand runner, and rejects non-builtins; `MSPShellBuiltinCommandTests` covers rejection of a non-builtin shell launcher, and existing Core100 coverage includes builtin execution/state smoke.
- Command-local status: none that can be proven inside the command wrapper alone. Alias/function bypass and advertised-builtin synchronization require shared command-resolution state; invalid-option byte parity should be sampled before changing diagnostics.
- Safe oracle notes: VPS sampling should cover no-arg, `--`, invalid option, non-builtin wording, alias/function shadowing, delegated state changes, and policy-denied delegated builtin cases. Safe case drafts: `builtin`, `builtin -- printf x`, `builtin -x`, `alias printf=false; builtin printf ok`.
- Deferred/forbidden with reason: disabled/loadable builtin support is deferred until MSP has an `enable` model; alias/function bypass proof is deferred to shared lookup/runtime; bypassing MSP policy through `builtin` is forbidden.

## `cd`

- Command: `cd`
- MSP implementation: `MSPCdCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPShellBuiltinCommands.swift`; state applied by `ModelShellProxy.applyStateChange`.
- Reference source: Bash `builtins/cd.def` (`cd_builtin`, `change_to_directory`); dash `src/cd.c` (`cdopt`, `cdcmd`).
- GNU/Linux parameter surface: Bash `cd [-L|[-P [-e]] [-@]] [dir]`; dash `cd [-L|-P] [dir]`; `cd`, `cd --`, `cd -`, `HOME`, `OLDPWD`, `PWD`, `CDPATH`, logical vs physical symlink handling, `cdable_vars`, too-many-arguments diagnostics.
- Currently supported by MSP: `cd`, `cd --`, `cd DIR`, `cd -`; updates virtual `currentDirectory`, `PWD`, and `OLDPWD`; validates directory through WorkspaceFS.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: Bash `-@` extended-attribute directory view is platform-conditional and conflicts with current portable WorkspaceFS abstraction; defer unless a virtual xattr namespace is introduced.
- Forbidden by policy: mutating the host process working directory or escaping WorkspaceFS root; `cd` must remain virtual.
- Performance model: O(path components) resolution plus one stat; CDPATH can add O(number of CDPATH entries) resolutions; no output streaming except `cd -`/CDPATH prints.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; current virtual cwd basics work, but common shell path semantics are largely missing.

### Closure status

- Implemented evidence: `MSPCdCommand` implements `cd`, `cd --`, `cd DIR`, `cd -`, virtual `PWD`/`OLDPWD` state changes, canonical directory validation, and bash-shaped path diagnostics; `MSPShellBuiltinCommandTests.testCdReturnsShellStateChangeAndCdDashOutput` covers relative `cd`, `cd -`, missing `OLDPWD`, and non-directory errors.
- Command-local status: `-L`, `-P`, `-e`, CDPATH search/output, and symlink-aware logical/physical cwd require shared WorkspaceFS/PWD semantics; HOME unset, permission-denied, and exact too-many-args diagnostics need oracle before further local changes.
- Safe oracle notes: VPS sampling should cover `cd -` byte output, HOME/OLDPWD unset cases, `--`, too-many args, CDPATH ordering/output, symlink directories, permission failures, and source/function/subshell state propagation. Safe case drafts: `cd -`, `env -u HOME bash -lc 'cd'`, `CDPATH=.. cd child`, `cd -P symlinkdir`, `cd -L symlinkdir`.
- Deferred/forbidden with reason: `-L`/`-P`/`-e` and CDPATH are deferred to shared cwd/PWD model, not command-local code; Bash `-@` is platform-specific and outside WorkspaceFS; mutating host cwd or escaping WorkspaceFS is forbidden.

## `command`

- Command: `command`
- MSP implementation: `MSPCommandCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPSubcommandUtilityCommands.swift`; runtime lookup and shell functions in `ModelShellProxy`.
- Reference source: Bash `builtins/command.def` (`command_builtin`); dash `src/exec.c` (`commandcmd`, `describe_command`).
- GNU/Linux parameter surface: `command [-pVv] command [arg ...]`; `-p` standard utility PATH; `-v` reusable/brief lookup; `-V` verbose lookup; suppresses shell function lookup when executing; help option in Bash builtins.
- Currently supported by MSP: parses `-p`, `-v`, `-V`; `-v`/`-V` use virtual command lookup; execution delegates to subcommand runner.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none for common `-pVv`; they are core shell semantics.
- Forbidden by policy: `command -p` must not expose host `/bin` or `/usr/bin` binaries outside registered MSP commands.
- Performance model: O(number of operands * lookup path entries) for lookup; delegated command cost for execution.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; `command` is a command-resolution primitive and current `-p`/function-bypass semantics are not implemented.

### Closure status

- Implemented evidence: `MSPCommandCommand` parses `-p`, `-v`, and `-V`; `MSPShellBuiltinCommandTests.testLookupBuiltinsKeywordsAndExternalFallbacksMatchBashAndWhichShapes` covers builtin/file/keyword lookup and invalid option diagnostics; existing Core100 coverage exercises lookup, execution, and missing-command smoke.
- Command-local status: no command-local wrapper work remains for the current virtual lookup table. Real `-p`, function-suppression during execution, alias/function/reserved-word-aware `-v`/`-V`, multi-name status, and Bash `--help` require shared lookup/runtime state.
- Safe oracle notes: VPS sampling should cover `-p` lookup/execution, alias and function shadowing, reserved words beyond `[[`, multiple operands, unknown names, execution bypass, and virtual PATH mutation cases. Safe case drafts: `command -p printf x`, `f(){ :; }; command f`, `alias ll='ls'; command -v ll`, `command -V cd no-such`.
- Deferred/forbidden with reason: deferred to shared command-resolution API for `-p` and function/alias bypass; exposing host `/bin` or `/usr/bin` through `command -p` is forbidden.

## `dirname`

- Command: `dirname`
- MSP implementation: `MSPDirnameCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Path/MSPDirnameCommand.swift`.
- Reference source: coreutils `src/dirname.c` (`longopts`, `main`).
- GNU/Linux parameter surface: `dirname [OPTION] NAME...`; `-z`/`--zero`; `--help`; `--version`; string path rules for no slash, trailing slash, root, empty string, multiple operands, and `//`.
- Currently supported by MSP: one or more operands; `-z`/`--zero`, `--help`, `--version`; pure string dirname transformation.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none.
- Forbidden by policy: none; command must not stat host paths.
- Performance model: O(total input path bytes), eager string processing, output proportional to operands.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: medium; implementation is close for common paths but not proven against GNU edge behavior.

### Closure status

- Implemented evidence: `MSPDirnameCommand` supports multiple operands, `-z`/`--zero`, `--help`, and `--version`; `MSPPathCommandTests.testDirnameSupportsGNUCoreutilsPathOptions` covers relative paths, repeated/trailing slashes, NUL output, missing operand, invalid option, help, and version.
- Command-local status: none in the common GNU option surface after this batch; double-slash `//` behavior is a platform edge that must be oracle-locked before changing string semantics.
- Safe oracle notes: VPS sampling should cover empty string, root, `//`, trailing-slash, long-option, unsupported-option, and byte-level NUL fixtures. Safe case drafts: `dirname ''`, `dirname /`, `dirname //`, `dirname -z foo/bar /usr/bin/`.
- Deferred/forbidden with reason: `//` is deferred pending Debian oracle because POSIX permits implementation-defined double-slash treatment; host stat/path probing is forbidden because dirname must remain a pure string transform.

## `echo`

- Command: `echo`
- MSP implementation: `MSPEchoCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPEchoCommand.swift`.
- Reference source: Bash `builtins/echo.def` (`echo_builtin`); coreutils `src/echo.c` (`main`, direct option parser).
- GNU/Linux parameter surface: Bash `echo [-neE] [arg ...]`; coreutils `-n`, `-e`, `-E`, standalone `--help`, standalone `--version`; escapes `\\`, `\a`, `\b`, `\c`, `\e`, `\E`, `\f`, `\n`, `\r`, `\t`, `\v`, `\0NNN`, coreutils `\xHH`, and Bash `\uHHHH`/`\UHHHHHHHH`.
- Currently supported by MSP: option clusters containing `n`, `e`, `E`; plain joining with spaces; escapes for `\0NNN`, `\a`, `\b`, `\c`, `\e`, `\E`, `\f`, `\n`, `\r`, `\t`, `\v`, `\\`, `\xHH`, `\uHHHH`, and `\UHHHHHHHH`.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: locale/display-width behavior is not command-local and should wait for a shared text/locale policy.
- Forbidden by policy: none.
- Performance model: O(total argument bytes), eager output construction today; large outputs should stream through `standardOutputStream` to avoid whole-buffer growth.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: medium; everyday output works, but byte escape parity is incomplete.

### Closure status

- Implemented evidence: `MSPEchoCommand` parses `-n`/`-e`/`-E` clusters, preserves unknown options as operands, joins operands, and implements common escapes plus `\c`, `\xHH`, `\uHHHH`, and `\UHHHHHHHH`; `MSPShellBuiltinCommandTests.testEchoAndPrintfDecodeCoreEscapeExtensions` covers the new hex/Unicode escapes.
- Command-local status: standalone GNU external `--help`/`--version`, POSIX/XPG default escape-mode controls, exact octal edge parity, closed-stdout/write-error behavior, and streaming for very large output require oracle/runtime policy before local changes.
- Safe oracle notes: VPS sampling should cover full escape matrix, unknown-option-as-data cases, option cluster edge cases, `\c` truncation, huge output/streaming, write errors, and bash-vs-coreutils mode differences. Safe case drafts: `echo -e '\x41'`, `echo -e '\u03bb'`, `echo -e 'a\cb'`, `echo --help`, `echo -ne x`.
- Deferred/forbidden with reason: external-vs-builtin meta options and mode defaults are deferred to coordinator policy; locale/display-width behavior is deferred to shared text/locale policy.

## `env`

- Command: `env`
- MSP implementation: `MSPEnvCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPSubcommandUtilityCommands.swift`.
- Reference source: coreutils `src/env.c` (`longopts`, `parse_split_string`, `main`).
- GNU/Linux parameter surface: `env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]`; `-i`/`--ignore-environment`; bare `-` as `-i`; `-0`/`--null`; `-u NAME`/`--unset=NAME`; `-C DIR`/`--chdir=DIR`; `-S STRING`/`--split-string=STRING`; `-v`/`--debug`; signal controls `--default-signal[=SIG]`, `--ignore-signal[=SIG]`, `--block-signal[=SIG]`, `--list-signal-handling`; `--help`; `--version`; exit codes 125/126/127.
- Currently supported by MSP: `-i`, bare `-`, `--ignore-environment`, `-0`, `--null`, `-u NAME`, `-uNAME`, `--unset NAME`, `--unset=NAME`, `-C DIR`, `--chdir DIR`, `--chdir=DIR`, `-S STRING`, `--split-string`, `--split-string=STRING`, `--help`, `--version`, environment assignments, printing, and registered-command execution with modified environment/current directory; rejects `--null` with command.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: GNU signal handling options should be deferred until MSP has a virtual process/signal model; host signal disposition must not be mutated.
- Forbidden by policy: changing host cwd; changing host signal masks/handlers; executing arbitrary host commands through modified `PATH`.
- Performance model: O(environment size + arguments); current print path eagerly builds full output; command execution delegates. `-S` parsing is O(split string bytes) but must be bounded for huge shebang strings.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; GNU `env` has a broad runtime surface and current MSP covers only the common environment-edit subset.

### Closure status

- Implemented evidence: `MSPEnvCommand` supports `-i`/`--ignore-environment`, bare `-`, `-0`/`--null`, unset forms, basic `-S`/`--split-string`, `-C`/`--chdir`, `--help`, `--version`, assignment ordering, registered-command execution with modified environment/cwd, and GNU-shaped 125/127 diagnostics; `MSPShellBuiltinCommandTests.testEnvMatchesGNUDiagnosticsNullRulesAndSubcommandBoundary` covers invalid options, unset errors, NUL rules, nested unset, wide assignments, `--`, `-S`, help/version, bare `-`, and `-C pwd`.
- Command-local status: `-v`/`--debug`, precise GNU `-S` quote/escape diagnostics, environment ordering parity against captured Linux, virtual `PATH` lookup/mutation, invalid assignment/name edge cases, command-not-executable 126, and the full 125/126/127 matrix remain hard deferred because signal/debug/PATH/exec status fidelity requires shared runtime/oracle policy beyond this command-local implementation.
- Safe oracle notes: VPS sampling should sample ordering, large NUL environments, nested command isolation, PATH mutation, `-C` errors, full split-string grammar, unsupported long options, command-not-executable status, help/version byte shape, and no-host-command execution. Safe case drafts: `env - FOO=bar`, `env --help | head -n 3`, `env --version`, `env -C sub pwd`, `env -S 'A=1 printf %s A'`, `env -i PATH=/bin which sh`.
- Deferred/forbidden with reason: GNU signal handling options are deferred until MSP has a virtual process/signal model; host cwd changes, host signal mutation, and arbitrary host PATH execution are forbidden.

## `false`

- Command: `false`
- MSP implementation: `MSPFalseCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPBooleanCommands.swift`.
- Reference source: Bash `builtins/colon.def` (`false_builtin`); dash `src/builtins.def.in` maps `false` to `falsecmd`; coreutils `src/false.c` includes `src/true.c` with failure status.
- GNU/Linux parameter surface: shell builtin ignores operands and returns 1; coreutils `false [ignored command line arguments]` plus standalone `--help`/`--version` recognized only as sole argument.
- Currently supported by MSP: returns exit 1 and no output while ignoring ordinary arguments; sole `--help` and sole `--version` follow coreutils external meta-option behavior and exit 0.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none.
- Forbidden by policy: none.
- Performance model: O(1).
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: low; only meta-option ambiguity remains.

### Closure status

- Implemented evidence: `MSPFalseCommand` returns exit 1 and no output while ignoring ordinary operands, and implements coreutils-style sole `--help`/`--version`; `MSPShellBuiltinCommandTests.testBooleanCommandsHonorCoreutilsSoleMetaOptions` covers help, version, and multi-operand ignored meta behavior.
- Command-local status: command-local implementation is closed for shell-builtin plus coreutils sole-meta behavior; write-error reporting for help/version is hard deferred until the shared output stream can surface closed-stdout failures.
- Safe oracle notes: VPS sampling should sample `false --help`, `false --version`, `false --help ignored`, pipeline status arrays, negation, `errexit`, and closed stdout once output failure semantics exist.
- Deferred/forbidden with reason: closed-stdout/write-error parity is deferred to shared stream/runtime error propagation; no policy-forbidden surface otherwise.

## `printf`

- Command: `printf`
- MSP implementation: `MSPPrintfCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPPrintfCommand.swift`.
- Reference source: Bash `builtins/printf.def` (`printf_builtin`); coreutils `src/printf.c` (`print_formatted`, `print_direc`, `main`); dash `src/bltin/printf.c`.
- GNU/Linux parameter surface: coreutils `printf FORMAT [ARGUMENT]...`, `--`, standalone `--help`/`--version`; Bash `printf [-v var] format [arguments]`; escapes `\"`, `\\`, `\a`, `\b`, `\c`, `\e`, `\f`, `\n`, `\r`, `\t`, `\v`, octal, `\xHH`, `\uHHHH`, `\UHHHHHHHH`; conversions `%%`, `%b`, `%q`, integer, float including `%a/%A`, `%c`, `%s`; Bash `%Q` and `%(fmt)T`; flags, width, precision, `*` width/precision, length modifiers, repeated format reuse, numeric diagnostics.
- Currently supported by MSP: optional leading `--`; standalone `--help`/`--version`; required format; format reuse; conversions `%b`, `%c`, `%d`, `%i`, `%u`, `%o`, `%x`, `%X`, `%a`, `%A`, `%f`, `%F`, `%e`, `%E`, `%g`, `%G`, `%s`, `%%`; common escapes plus `\"`, `\E`, `\xHH`, `\uHHHH`, `\UHHHHHHHH`; basic numeric parsing with GNU/Bash-like diagnostics for partial conversions.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: locale-specific grouping/`I` flag can be staged behind a shared locale policy once that policy exists.
- Forbidden by policy: `%T` must not expose host timezone/locale beyond MSP's configured deterministic environment.
- Performance model: current implementation eagerly appends all output to `Data`; large repeated formats can grow unbounded and should stream plus honor output limits/cancellation.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; `printf` is central to shell scripts and current support is materially below Bash/coreutils.

### Closure status

- Implemented evidence: `MSPPrintfCommand` implements leading `--`, standalone `--help`/`--version`, required format diagnostics, format reuse, `%b/%c/%d/%i/%u/%o/%x/%X/%a/%A/%f/%F/%e/%E/%g/%G/%s/%%`, common escapes plus `\"`, `\E`, `\xHH`, `\uHHHH`, `\UHHHHHHHH`, integer diagnostics, and binary output through `stdoutData`; `MSPShellBuiltinCommandTests.testEchoAndPrintfDecodeCoreEscapeExtensions` covers help/version, hex/Unicode escapes, and `%a`.
- Command-local status: Bash `-v`, `%q`, Bash `%Q`, Bash `%(fmt)T`, `*` width/precision, full flag/length validation, invalid format diagnostics, write errors, invalid Unicode/scalar edge behavior, and streaming for huge repeated output are hard deferred because they need shell variable assignment semantics, shell-quoting policy, deterministic time/locale policy, or shared streaming/write-error support.
- Safe oracle notes: VPS sampling should sample conversion/escape matrix, help/version, `%q/%Q/%T`, `-v`, dynamic width/precision, numeric edge cases, invalid formats, binary/NUL output, huge repeat/cancellation, and closed stdout/write errors. Safe case drafts: `printf --help | head -n 3`, `printf --version`, `printf '%a\n' 2`, `printf '%*s\n' 5 x`, `printf '%q\n' 'a b'`, `printf '%b' '\x41\u03bb'`, `printf '%d\n' 09`.
- Deferred/forbidden with reason: locale-specific grouping/`I` remains deferred behind shared locale policy; `%T` must not expose host timezone/locale beyond deterministic MSP environment.

## `printenv`

- Command: `printenv`
- MSP implementation: `MSPPrintenvCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPPrintenvCommand.swift`.
- Reference source: coreutils `src/printenv.c` (`longopts`, `main`).
- GNU/Linux parameter surface: `printenv [OPTION]... [VARIABLE]...`; `-0`/`--null`; `--help`; `--version`; all variables if no operand; selected values only for names without `=`; exit 0 only if all requested variables matched.
- Currently supported by MSP: `-0`, `--null`, `--`, `--help`, `--version`; all environment or selected variable values; ignores operands containing `=`; returns 1 if any requested variable is missing.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none.
- Forbidden by policy: printing hidden host environment; only MSP virtual environment may be visible.
- Performance model: O(environment size + operand count); current implementation eagerly builds output and sorts keys.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: medium; selected lookup is present, but all-env ordering and meta options are unproven.

### Closure status

- Implemented evidence: `MSPPrintenvCommand` supports `-0`/`--null`, `--`, `--help`, `--version`, all-env output, selected variables, `NAME=VALUE` operand ignore, and missing-variable exit 1; existing `MSPCore100ExtraCommandTests` covers selected variables including empty and missing, and Core100 has one/many/missing/zero-output smoke.
- Command-local status: preserving virtual environment insertion order instead of sorted no-operand output, exact invalid-option byte parity, and large-output streaming.
- Safe oracle notes: VPS sampling should cover no-operand all-env ordering, invalid options, help/version, `NAME=VALUE` operands, huge environments, hidden-host-environment leakage checks, and byte-level NUL output. Safe case drafts: `printenv`, `printenv -0 A B`, `printenv NAME=VALUE`, `printenv --help`.
- Deferred/forbidden with reason: insertion-order parity is deferred until the shared environment model exposes stable ordering; printing host process environment is forbidden.

## `pwd`

- Command: `pwd`
- MSP implementation: `MSPPwdCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPPwdCommand.swift`; cwd state in `ModelShellProxy.applyStateChange`.
- Reference source: Bash `builtins/cd.def` (`pwd_builtin`); coreutils `src/pwd.c` (`longopts`, `logical_getcwd`, `main`); dash `src/builtins.def.in` maps `pwdcmd`.
- GNU/Linux parameter surface: Bash builtin `pwd [-LP]`; coreutils `pwd [OPTION]...` with `-L`/`--logical`, `-P`/`--physical`, `--help`, `--version`; default differs between shell builtin and standalone coreutils; logical `$PWD` validation vs physical symlink resolution.
- Currently supported by MSP: parses short `-L`/`-P` and long `--logical`/`--physical`; implements standalone `--help`/`--version`; logical mode prints virtual `context.currentDirectory`; physical mode canonicalizes the current directory through WorkspaceFS; invalid options return bash-builtin-shaped usage; ignores non-option operands after option parsing break.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none for symlink-aware WorkspaceFS; this is common shell behavior.
- Forbidden by policy: calling host `getcwd()` or exposing host absolute paths.
- Performance model: current O(1); physical mode may be O(path components) plus symlink resolution/stat calls.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; printed value is central shell state and current logical/physical handling should cover deeper WorkspaceFS oracle coverage.

### Closure status

- Implemented evidence: `MSPPwdCommand` implements short `-L`/`-P`, long `--logical`/`--physical`, standalone `--help`/`--version`, virtual logical cwd, WorkspaceFS canonical physical mode, invalid-option diagnostics, and shell-style operand tolerance; `MSPShellBuiltinCommandTests.testPwdMatchesBashBuiltinOptionsAndOperandTolerance` covers these paths.
- Command-local status: full symlink-aware logical vs physical parity, `$PWD` validation after symlink changes, coreutils-vs-builtin operand differences, and deleted/unreadable cwd equivalents require shared cwd/PWD and oracle policy.
- Safe oracle notes: VPS sampling should sample symlink chains, changed/invalid `$PWD`, help/version byte shape, extra operands, sourced/function/subshell state, deleted cwd, unreadable cwd, and byte-level diagnostics. Safe case drafts: `pwd --logical`, `pwd --physical`, `pwd --help | head -n 3`, `pwd --version`, `pwd ignored`, `PWD=/bad pwd -L`, `pwd -P` inside symlink cwd.
- Deferred/forbidden with reason: symlink/PWD validation is deferred to shared cwd model; host `getcwd()` and host absolute path exposure are forbidden.

## `test`

- Command: `test`
- MSP implementation: `MSPTestCommand(name: "test")` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPTestCommand.swift`.
- Reference source: Bash `builtins/test.def`; Bash `test.c`; coreutils `src/test.c`; dash `src/bltin/test.c`.
- GNU/Linux parameter surface: same expression surface as `[` without required closing bracket; Bash adds `-o OPTION`, `-v VAR`, `-R VAR`; GNU `test --help` and `test --version` are treated as nonempty strings, while external `[` handles them specially.
- Currently supported by MSP: empty/string truth, `!`, parentheses, `-a`, `-o`, unary `-n`, `-z`, common file predicates (`-a`, `-b`, `-c`, `-d`, `-e`, `-f`, `-g`, `-G`, `-h`, `-k`, `-L`, `-N`, `-O`, `-p`, `-r`, `-s`, `-S`, `-t`, `-u`, `-w`, `-x`) with WorkspaceFS/virtual limits, string `=`, `==`, `!=`, `<`, `>`, integer comparisons, and file comparisons `-ef`, `-nt`, `-ot`.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: real `-t FD` terminal detection waits on virtual TTY/session state; implement deterministic non-PTY behavior first.
- Forbidden by policy: leaking host uid/gid/inode/device/tty state.
- Performance model: O(tokens) plus WorkspaceFS stat/lstat per file predicate; current eager evaluator throws for more than three args.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; `test` is widely used and current implementation is intentionally narrow.

### Closure status

- Implemented evidence: `MSPTestCommand(name: "test")` supports empty/string truth, `!`, parentheses, `-a`, `-o`, string `<`/`>`, common unary file predicates, `-nt`/`-ot`/`-ef`, integer comparisons, and diagnostics for bad unary/binary/integer expressions; `MSPShellBuiltinCommandTests.testTestCommandSupportsCommonFilePredicatesAndIntegerDiagnostics` covers compound expressions, permissions, symlink predicate, string ordering, and file comparisons.
- Command-local status: Bash-only `-o OPTION`, `-v VAR`, `-R VAR`, exact `test --help`/`--version` string-truth edge behavior, and full uid/gid/device/inode fidelity are not representable in the current command-local surface.
- Safe oracle notes: VPS sampling should cover broad truth tables, ambiguous precedence, invalid-expression diagnostics, bash-only variable/option tests, symlink/stat/permission matrices, and byte-level stderr. Safe case drafts: `test '(' -n x -a 3 -gt 2 ')' -o a = b`, `test file1 -ot file2`, `test file1 -ef file1`, `test beta '>' alpha`, `test --help`.
- Deferred/forbidden with reason: real `-t FD` terminal detection is deferred until virtual TTY/session state exists; host uid/gid/inode/device/tty leakage is forbidden.

## `true`

- Command: `true`
- MSP implementation: `MSPTrueCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPBooleanCommands.swift`.
- Reference source: Bash `builtins/colon.def` (`colon_builtin` for `true`); dash `src/builtins.def.in` maps `true` and `:` to `truecmd`; coreutils `src/true.c`.
- GNU/Linux parameter surface: shell builtin ignores operands and returns 0; coreutils `true [ignored command line arguments]` plus standalone `--help`/`--version` recognized only as sole argument.
- Currently supported by MSP: returns exit 0 and no output while ignoring ordinary arguments; sole `--help` and sole `--version` follow coreutils external meta-option behavior and exit 0.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none.
- Forbidden by policy: none.
- Performance model: O(1).
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: low; semantics are trivial except GNU meta-option ambiguity.

### Closure status

- Implemented evidence: `MSPTrueCommand` returns exit 0 and no output while ignoring ordinary operands, and implements coreutils-style sole `--help`/`--version`; `MSPShellBuiltinCommandTests.testBooleanCommandsHonorCoreutilsSoleMetaOptions` covers help, version, and multi-operand ignored meta behavior.
- Command-local status: command-local implementation is closed for shell-builtin plus coreutils sole-meta behavior; write-error reporting for help/version is hard deferred until the shared output stream can surface closed-stdout failures.
- Safe oracle notes: VPS sampling should sample `true --help`, `true --version`, `true --help ignored`, pipeline status arrays, negation, `errexit`, and closed stdout once output failure semantics exist.
- Deferred/forbidden with reason: closed-stdout/write-error parity is deferred to shared stream/runtime error propagation; no policy-forbidden surface otherwise.

## `type`

- Command: `type`
- MSP implementation: `MSPTypeCommand` and lookup helpers in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPShellBuiltinCommands.swift`; available names supplied by `ModelShellProxy`.
- Reference source: Bash `builtins/type.def` (`type_builtin`, `describe_command`); dash `src/exec.c` (`typecmd`, `describe_command`).
- GNU/Linux parameter surface: Bash `type [-afptP] name [name ...]`; `-a`, `-f`, `-p`, `-P`, `-t`; obsolete/accepted `-type`, `-path`, `-all` / `--type`, `--path`, `--all`; Bash `--help`; output kinds `alias`, `keyword`, `function`, `builtin`, `file`; alias/function/builtin/file lookup order.
- Currently supported by MSP: parses `-a`, `-f`, `-p`, `-P`, `-t`; accepts Bash obsolete aliases `-type`/`--type`, `-path`/`--path`, `-all`/`--all`; accepts Bash `--help`; distinguishes keyword set containing `[[`, builtin set, and known external paths; supports multiple operands and not-found exit status.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: alias, function, and hashed/tracked command table output wait on shared shell lookup state because the command-local API receives only registered command names and static path hints.
- Forbidden by policy: exposing unregistered host PATH entries.
- Performance model: O(operands * lookup entries); no filesystem walk should occur beyond registered command lookup.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; current lookup model cannot represent aliases/functions correctly.

### Closure status

- Implemented evidence: `MSPTypeCommand` parses `-a`, `-f`, `-p`, `-P`, and `-t`; it normalizes Bash's obsolete `-type`/`--type`, `-path`/`--path`, and `-all`/`--all` aliases before option parsing; it accepts Bash `--help`; it distinguishes the `[[` keyword, static builtins, and known/registered external paths. `MSPShellBuiltinCommandTests.testLookupBuiltinsKeywordsAndExternalFallbacksMatchBashAndWhichShapes` covers keyword, all matches for builtin/external, path-only builtin behavior, obsolete aliases, help output, no-argument behavior, and invalid option diagnostics.
- Command-local status: alias lookup/output, shell function lookup/output, `-f` suppression once functions exist, exact alias/function/file lookup order, and hash/tracked-path semantics require shared shell lookup state.
- Safe oracle notes: VPS sampling should cover aliases, functions, `-a/-f/-p/-P` combinations, obsolete options, unknown names, multiple names, external registered commands, reserved words, output wording, and missing-name diagnostics. Safe case drafts: `type -a printf`, `type -t [[`, `type -p cd`, `type --type cd`, `type --path basename`, `type --all basename`, `f(){ :; }; type f`, `alias ll=ls; type ll`.
- Deferred/forbidden with reason: alias/function/hash/tracked command support is deferred to shared lookup runtime; exposing unregistered host PATH entries is forbidden.

## `which`

- Command: `which`
- MSP implementation: `MSPWhichCommand` in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Utility/MSPShellBuiltinCommands.swift`.
- Reference source: `References/LinuxSourceSnapshot/debian12-bookworm/sources/debianutils-5.7/which` (`getopts a`, `ALLMATCHES`, slash-operand branch, PATH colon loop, final `ALLRET`); `References/LinuxSourceSnapshot/debian12-bookworm/sources/debianutils-5.7/which.1` for synopsis and exit statuses.
- GNU/Linux parameter surface: Debianutils `which [-a] filename ...`; `-a` prints all matching pathnames per operand; invalid options print `Usage: $0 [-a] args` and exit 2; no operands exit 1; any missing/non-executable operand makes the final exit 1; operands containing `/` are tested directly with `-f` and `-x` and printed unchanged; other operands are searched through `$PATH` split on `:`, with empty elements treated as `.`, trailing-colon behavior preserved, first match printed unless `-a` is set, and no pathname canonicalization. This vendored Debian 12 source does not expose alias/function ingestion, TTY-only behavior, long options, `--help`, or `--version`.
- Currently supported by MSP: Debianutils `-a`; no operands return exit 1; multiple operands set exit 1 if any operand is missing; virtual `$PATH` search honors path order and empty/trailing entries as `.`, uses WorkspaceFS regular/executable checks for slash operands, uses known external virtual fallback paths, excludes builtins, rejects non-Debian `--all`, and emits Debianutils-shaped invalid-option output.
- Must implement: none for Batch 01 command-local closure; implemented evidence and scoped deferrals are recorded below.
- Deferred with reason: none; the vendored Debianutils implementation has no alias/function/TTY/long-option behavior to defer.
- Forbidden by policy: scanning or exposing the host `PATH`, host cwd, or host executable bits; PATH lookup and slash operands must resolve only inside MSP's virtual workspace/registered command surface.
- Performance model: Debianutils behavior is O(operands * PATH entries) with one regular-file/executable check per candidate, short-circuiting per operand unless `-a` is set; MSP should keep that bounded by virtual PATH length and avoid directory walks.
- Oracle/stress gaps: none for Batch 01 command-local closure; local coverage, VPS-safe sampling candidates, and scoped deferrals are recorded below.
- Risk: high; current MSP `which` is a registry/path-table lookup, while Debianutils `which` is a `$PATH` plus executable-file test, so common environment-sensitive cases can report the wrong path or success status.

### Closure status

- Implemented evidence: `MSPWhichCommand` implements Debianutils-style `-a`, no-argument exit 1, mixed missing status, builtins excluded from output, virtual `$PATH` search, empty/trailing components as `.`, slash operands through WorkspaceFS regular/executable checks, known external fallback paths, rejection of non-Debian `--all`, and Debianutils-shaped invalid-option diagnostics; `MSPShellBuiltinCommandTests.testWhichUsesVirtualPathAndSlashOperandRules` covers virtual PATH, `-a` ordering, slash operands, and non-executable miss.
- Command-local status: exact `--` terminator behavior and duplicate/no-canonicalization edge parity should be oracle-locked, but no broad command-local implementation gap remains for the Debianutils option surface.
- Safe oracle notes: VPS sampling should cover PATH mutation with empty/trailing/current-directory entries, duplicate output, slash operands, non-executable files, mixed found/missing operands, invalid short options, long-option rejection, `--` terminator, no-canonicalization, and no-host-PATH leak tests. Safe case drafts: `PATH=/tmp/bin:/bin which cmd`, `PATH=:/bin which localcmd`, `which -a sh`, `which ./x`, `which --all sh`, `which -z sh`.
- Deferred/forbidden with reason: edge byte parity is deferred to coordinated VPS capture; scanning or exposing host PATH/cwd/executable bits is forbidden.
