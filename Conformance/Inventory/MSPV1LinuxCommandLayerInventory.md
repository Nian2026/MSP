# MSP v1 Linux Command Layer Inventory

This inventory is the MSP-native classification table for the v1 Linux-like
command layer. It defines the migration scope without exposing private app
naming in public SDK or conformance files.

## Authoritative Inputs

- Source app shell default builtin registry, preserved under `References/`.
- Source app external-command registry, preserved under `References/`.
- Debian 12 source packages for Linux-compatible behavior checks:
  GNU coreutils, bash, dash, findutils, grep, sed, mawk, and ripgrep.
- MSP fixture:
  `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`.

## Scope Rule

MSP v1 core includes generic Linux-native commands and generic shell commands.
It excludes app-specific commands and does not bundle third-party external
binaries. External binaries are exposed through an SDK capability boundary so
app developers can provide their own binaries and policies.

If a command exposes a parser, expansion, glob, pipeline, redirection, stdin,
environment, cwd, path, or exit-code gap, the fix belongs in the shared shell
runtime or WorkspaceFS layer, not in command-local special cases.

## Required Linux / Generic Shell Commands

All commands in this table are required by MSP v1. The current implementation
status is tracked by the required-commands fixture and verified by Swift tests.

| Command | Class | MSP v1 treatment | Primary semantic reference |
| --- | --- | --- | --- |
| `:` | shell special builtin | core command | bash/dash |
| `[` | shell test utility | core command | coreutils `test.c` / bash |
| `[[` | shell conditional | core command | bash |
| `awk` | text language | core command | POSIX awk / mawk |
| `base64` | data encoding | core command | coreutils `base64.c` |
| `basename` | path utility | core command | coreutils `basename.c` |
| `bc` | calculator language | core command | POSIX bc-compatible behavior |
| `builtin` | shell lookup builtin | core command | bash |
| `cat` | text/file utility | core command | coreutils `cat.c` |
| `cd` | shell state builtin | core command | bash/dash |
| `chmod` | file mode utility | core command | coreutils `chmod.c` |
| `cksum` | checksum utility | core command | coreutils `cksum.c` |
| `cmp` | comparison utility | core command | common Unix behavior |
| `comm` | text comparison utility | core command | coreutils `comm.c` |
| `command` | shell lookup builtin | core command | bash/dash |
| `cp` | filesystem utility | core command | coreutils `cp.c` |
| `cut` | text processing utility | core command | coreutils `cut.c` |
| `date` | time utility | core command | coreutils `date.c` |
| `diff` | comparison utility | core command | GNU diff-compatible behavior |
| `dirname` | path utility | core command | coreutils `dirname.c` |
| `du` | disk usage utility | core command | coreutils `du.c` |
| `echo` | shell/core utility | core command | coreutils `echo.c` / bash |
| `env` | environment utility | core command | coreutils `env.c` |
| `false` | status utility | core command | coreutils `false.c` |
| `file` | metadata utility | core command | common Unix behavior |
| `find` | filesystem search utility | core command | findutils |
| `grep` | text search utility | core command | GNU grep |
| `head` | text selection utility | core command | coreutils `head.c` |
| `join` | text relational utility | core command | coreutils `join.c` |
| `ldd` | dependency display utility | core command | Linux ldd-compatible behavior |
| `ln` | filesystem link utility | core command | coreutils `ln.c` |
| `ls` | filesystem listing utility | core command | coreutils `ls.c` |
| `md5sum` | digest utility | core command | coreutils digest implementation |
| `mkdir` | filesystem utility | core command | coreutils `mkdir.c` |
| `mktemp` | temporary path utility | core command | coreutils `mktemp.c` |
| `mv` | filesystem utility | core command | coreutils `mv.c` |
| `nl` | text numbering utility | core command | coreutils `nl.c` |
| `numfmt` | numeric formatting utility | core command | coreutils `numfmt.c` |
| `od` | binary dump utility | core command | coreutils `od.c` |
| `paste` | text merge utility | core command | coreutils `paste.c` |
| `printf` | shell/core utility | core command | coreutils `printf.c` / bash |
| `ps` | process listing utility | core command | Linux/procps-compatible behavior |
| `pwd` | shell/core utility | core command | coreutils `pwd.c` / bash/dash |
| `readlink` | symlink utility | core command | coreutils `readlink.c` |
| `realpath` | path utility | core command | coreutils `realpath.c` |
| `rg` | text search utility | core command | ripgrep |
| `rm` | filesystem removal utility | core command | coreutils `rm.c` |
| `sed` | stream editor | core command | GNU sed / POSIX sed |
| `seq` | sequence utility | core command | coreutils `seq.c` |
| `sha1sum` | digest utility | core command | coreutils digest implementation |
| `sha256sum` | digest utility | core command | coreutils digest implementation |
| `sort` | text ordering utility | core command | coreutils `sort.c` |
| `stat` | metadata utility | core command | coreutils `stat.c` |
| `tac` | reverse text utility | core command | coreutils `tac.c` |
| `tail` | text selection utility | core command | coreutils `tail.c` |
| `tee` | stream/file utility | core command | coreutils `tee.c` |
| `test` | shell test utility | core command | coreutils `test.c` / bash |
| `timeout` | process control utility | core command | coreutils `timeout.c` |
| `touch` | filesystem timestamp utility | core command | coreutils `touch.c` |
| `tr` | text transform utility | core command | coreutils `tr.c` |
| `true` | status utility | core command | coreutils `true.c` |
| `type` | shell lookup builtin | core command | bash |
| `uniq` | text filtering utility | core command | coreutils `uniq.c` |
| `wc` | text counting utility | core command | coreutils `wc.c` |
| `which` | command lookup utility | core command | common Unix behavior |
| `xargs` | argument builder utility | core command | POSIX xargs |
| `xxd` | hex dump utility | core command | xxd-compatible behavior |
| `yes` | stream utility | core command | coreutils `yes.c` |

## Required Shared Shell Runtime Capabilities

| Capability | MSP layer |
| --- | --- |
| command AST parsing and execution | MSPShell |
| command lookup and dispatch | MSPCore / ModelShellProxy |
| mutable current working directory | ModelShellProxy shell state |
| assignment-only and assignment-prefixed commands | MSPShell / ModelShellProxy |
| parameter expansion and special parameters | MSPShell expansion |
| arithmetic command and expansion lvalues for scalar, indexed-array, associative-array, and nameref state | MSPShell / ModelShellProxy |
| quote handling and word splitting | MSPShell expansion |
| pathname/glob expansion | MSPShell expansion + WorkspaceFS |
| stdin/stdout/stderr stream propagation | MSPShell runtime |
| input/output/append redirection | MSPShell runtime + WorkspaceFS |
| descriptor routing | MSPShell runtime; fd 0/1/2 plus fd table entries for persistent/scoped fd3+ output, input, duplication, close, closed fd0 distinct from empty stdin, `read -u N`, `mapfile -u N`, duplicated input read-offset sharing, `<>` read/write open-file-description offset sharing, and fd3+ overlays visible inside compound/function/eval/source/shell-launcher runtimes |
| process substitution | MSPShell expansion + ModelShellProxy runtime + WorkspaceFS temporary paths for `<(...)`, `>(...)`, scoped output finalization, and fd-close finalization |
| heredoc and here-string handling | MSPShell parser/runtime |
| pipeline execution, including stderr piping | MSPShell runtime |
| `PIPESTATUS` raw stage-status array updates | MSPShell runtime |
| `&&`, `||`, `;`, and `!` exit semantics | MSPShell runtime |
| shell status propagation | ModelShellProxy shell state |
| virtual path resolution | WorkspaceFS |
| host path redaction | WorkspaceFS / command diagnostics |

## Required Runtime Special Builtins

These names are shell-runtime semantics, not standalone POSIX core command
implementations. They must still be visible to command lookup and executable
through the same `exec_command` text path.

| Builtin | MSP v1 treatment | Current status |
| --- | --- | --- |
| `break` | loop control runtime builtin | implemented |
| `continue` | loop control runtime builtin | implemented |
| `eval` | re-enter parser/runtime with expanded command text | implemented |
| `exec` | persistent descriptor/runtime redirection builtin | implemented for fd 0/1/2 and fd table entries such as `exec 3>file`, `exec 3<file`, descriptor duplication, and descriptor close |
| `exit` | current command-run exit control | implemented |
| `return` | function return control | implemented |
| `shift` | positional-parameter mutation builtin | implemented |
| `set` | shell options and positional-parameter setup | `set --`, `-e/+e`, `-f/+f`, `-u/+u`, and `-o/+o pipefail` implemented |
| `shopt` | bash shell option surface | implemented for `-s`, `-u`, `-p`, `-q`, recognized option state, lookup visibility, and WorkspaceFS pathname expansion effects for `nullglob`, `failglob`, `dotglob`, `nocaseglob`, `extglob`, and `globstar` |
| `declare` | variable declaration surface | implemented for scalar, indexed-array, associative-array, and nameref declarations, sparse indexed-array printing, associative subscript assignment, `-p`, lookup visibility, and pipeline isolation; deeper attribute parity remains pending |
| `typeset` | `declare` compatibility alias | implemented for the current `declare` compatibility surface; deeper alias parity remains pending |
| `unset` | variable/function removal | implemented |
| `local` | function-local declaration semantics | implemented for scalar, indexed-array, associative-array, and nameref state restoration |
| `.` | source script in current shell | implemented |
| `source` | source script in current shell | implemented |
| `trap` | exit/signal trap surface | implemented for `EXIT`/`0` run-end handlers, reset, `-p`, `-l`, common signal registration/listing, lookup visibility, and pipeline isolation; real OS signal delivery is outside the in-process command layer |
| `read` | stdin record assignment builtin | implemented for `-r`, `-d`, `-n`, and `-u N` against the shared fd table |
| `mapfile` | stdin-to-array builtin | implemented for indexed arrays with `-t`, `-u N`, `-n`, `-s`, and `-O`; callback/origin edge cases still need deeper parity audit |
| `readarray` | `mapfile` compatibility alias | implemented for the current `mapfile` indexed-array surface |
| `umask` | file creation mask state | implemented for octal, `-p`, `-S`, common symbolic modes, and WorkspaceFS creation modes |
| `sh` | shell launcher compatibility boundary | implemented as an in-process MSP runtime launcher for `-c`, WorkspaceFS script files, stdin scripts, `-n`, `-e`, `-u`, `-o/+o` for `errexit`/`nounset`/`pipefail`, redirection, lookup visibility, and child-shell state isolation; not a bundled host shell binary |
| `bash` | shell launcher compatibility boundary | implemented as the same in-process launcher surface, including `--noprofile`/`--norc` acceptance; full bash-specific language/startup-file parity remains outside this checkpoint |
| `zsh` | shell launcher compatibility boundary | implemented as the same in-process launcher surface; full zsh-specific language/startup-file parity remains outside this checkpoint |

## External Binary Boundary

These commands are outside the MSP v1 core command pack. MSP provides the
external-runner capability and policy surface; apps provide binaries and decide
which commands to expose.

| Command | MSP v1 treatment |
| --- | --- |
| `git` | external-runner integration |
| `qpdf` | external-runner integration |
| `ffmpeg` | external-runner integration |
| `ffprobe` | external-runner integration |
| `yt-dlp` | external-runner integration |

## App-Specific Commands Excluded From Core

These commands are intentionally not part of the generic Linux command layer.
They belong in app-defined command packs or examples.

| Command | Reason |
| --- | --- |
| `trash` | app recoverable-delete policy |
| `restore` | app recoverable-delete policy |
| `chat` | app agent/conversation feature |
| `km` | app knowledge-map feature |
| `pdf` | app document feature |
| `text` | app document attachment feature |
| `video` | app media feature |
| `open` | host/app open integration |
| `xdg-open` | host/app open integration |
| `gio` | host/app open integration |
| `kde-open` | host/app open integration |
| `kde-open5` | host/app open integration |
| `exo-open` | host/app open integration |
| `mimeopen` | host/app open integration |
| `see` | host/app open integration |

## Current Verification Checkpoint

As of the current MSP v1 command-layer checkpoint, the required command fixture
contains 68 commands, the direct parity fixture contains one direct case for each
of those 68 commands, and the POSIX core command pack registers the same 68
commands without app-specific or external-binary commands.

A six-family VPS oracle audit has expanded local coverage across the command
surface:

| Family | Commands audited | Current result |
| --- | --- | --- |
| text streams | `cat`, `head`, `tail`, `wc`, `sort`, `uniq`, `tac`, `tee`, `tr`, `paste`, `comm` | local command fixes accepted for `tr` and `comm`; no shared-layer blocker |
| text languages | `grep`, `sed`, `awk`, `cut`, `join`, `nl`, `xargs`, `yes`, `printf`, `echo`, `seq` | local command fixes accepted for GNU diagnostics and option edges; no shared-layer blocker |
| filesystem | `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `ln`, `chmod`, `du`, `mktemp`, `find` | local command fix accepted for `mv` missing-source diagnostics; no shared-layer blocker |
| data, comparison, metadata | `od`, `xxd`, `base64`, `md5sum`, `sha1sum`, `sha256sum`, `cksum`, `cmp`, `diff`, `file`, `stat` | local command fixes accepted for `diff -u` headers and default `stat`; no shared-layer blocker |
| shell, builtin, path, environment | `cd`, `pwd`, `env`, `test`, `[`, `[[`, `:`, `true`, `false`, `type`, `which`, `command`, `builtin`, `basename`, `dirname`, `readlink`, `realpath` | local command fixes accepted for GNU-style diagnostics and lookup edges; parser-level `[[` syntax wording plus bash presentation prefixes for shell builtin syntax errors remain shared-shell audit items |
| miscellaneous, process, numeric, search | `date`, `bc`, `numfmt`, `ps`, `timeout`, `ldd`, `rg` | local command fixes accepted for `date`, `ps`, `timeout`, and `rg`; no shared-layer blocker |

The VPS audit edge cases have started moving from scattered unit tests into the
MSP conformance fixture set. `MSPV1LinuxCommandLayer.edge-parity-cases.json`
currently contains 42 edge cases covering 39 required commands, focused on
option diagnostics, missing-path diagnostics, exit-code propagation, and virtual
path output. The edge fixture runs through the same WorkspaceFS-backed
`ModelShellProxy.iOS(...).enable(.posixCore)` path as the rest of the
conformance suite.

The VPS oracle distinguishes command-local diagnostics from shell presentation
diagnostics. Cases such as `command -Z` and `[ abc` include a bash
`/bin/bash: line 1:` prefix on the reference VPS, so they are tracked as shared
shell presentation decisions instead of command-local conformance cases.

Post-integration gates for this checkpoint:

- `swift test` passes with 154 tests.
- `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`,
  `Conformance/Fixtures/MSPV1LinuxCommandLayer.direct-parity-cases.json`, and
  `Conformance/Fixtures/MSPV1LinuxCommandLayer.parity-cases.json` parse as JSON.
- `Conformance/Fixtures/MSPV1LinuxCommandLayer.edge-parity-cases.json` parses
  as JSON, runs through the conformance test runner, and references only
  required MSP v1 commands.
- Public MSP source, tests, spec, and conformance paths pass the MSP-native
  naming check.
- `git diff --check` passes.

This checkpoint is stronger than command-presence completion, but it is not the
final MSP v1 parity claim by itself. The next parity work is to keep promoting
the remaining stable VPS edge cases from the family audits into durable
conformance fixtures, then add a repeatable oracle-harness workflow so
option-level stdout, stderr, exit code, and path diagnostics can be refreshed
against a real Linux reference over time.

## Completion Gates

MSP v1 Linux command-layer migration is complete only when all of these are
true:

1. Every required command above is implemented or has a written temporary
   deferral with rationale.
2. MSP public source, specs, tests, and conformance files use MSP-native naming.
3. The core command pack exactly matches the required command fixture.
4. App-specific and external commands are not registered by the core command
   pack.
5. Each command has direct unit or integration tests.
6. Each command family has Linux-compatible parity cases for stdout, stderr,
   exit code, path errors, option parsing, and stdin behavior where applicable.
7. Shared parser/runtime gaps are fixed in MSPShell or WorkspaceFS, not in
   command-local patches.
8. Agent-facing invocation remains `exec_command` with only `cmd`, and output
   remains plain shell text.
9. All path behavior runs through WorkspaceFS without host sandbox path leaks.
