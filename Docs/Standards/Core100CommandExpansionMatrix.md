# MSP Core100 Command Expansion Matrix

This document defines the first Core100 expansion target after the MSP v1
68-command Linux command layer. It is a standards input, not an implementation
shortcut. Every command and option promoted here must be backed by Debian 12
oracle captures before implementation is accepted.

## Scope

Core100 means the default, safe, WorkspaceFS-backed Linux-like command surface
for agent-facing `exec_command`. It must remain plain-text at the agent
boundary. Internal fixtures may be JSON and byte-safe base64.

Core100 does not bundle host binaries or app-specific commands. `git`,
`ffmpeg`, `yt-dlp`, `curl`, `wget`, `tar`, `zip`, `jq`, and media/document
commands belong in later optional command packs or external-binary adapters.

## Expansion Summary

The current required command fixture contains 68 commands. Core100 adds these
32 command names:

| Class | Commands | Count |
| --- | --- | ---: |
| shell state and compatibility | `export`, `unset`, `set`, `read`, `source`, `alias`, `unalias`, `umask` | 8 |
| WorkspaceFS file operations | `rmdir`, `unlink`, `truncate`, `dd`, `split`, `install`, `tree` | 7 |
| text and record utilities | `expr`, `strings`, `fold`, `expand`, `unexpand`, `fmt`, `shuf`, `tsort` | 8 |
| environment identity | `uname`, `whoami`, `id`, `hostname`, `sleep` | 5 |
| encoding and digest | `base32`, `basenc`, `sha512sum`, `b2sum` | 4 |

Total target size: 68 existing commands + 32 expansion commands = 100.

## Promotion Matrix

Status values:

- `new-command`: not currently in the required command fixture.
- `runtime-present`: shell runtime already has a surface, but it must be
  promoted into the Core100 conformance inventory and oracle fixtures.
- `policy-sensitive`: requires an explicit MSP policy boundary before default
  enablement.

| Command | Class | Status | Reference | Required option surface for Core100 | Deferred / policy notes |
| --- | --- | --- | --- | --- | --- |
| `export` | shell | new-command | bash/dash | no args, `-p`, `-n`, `NAME=value`, multiple names, invalid identifiers | exported environment is internal MSP runtime state, not host process mutation |
| `unset` | shell | runtime-present | bash/dash | variables, `-v`, `-f`, arrays/subscripts, invalid identifiers, missing names | already has runtime support; needs Core100 fixture promotion |
| `set` | shell | runtime-present | bash/dash | `--`, positional parameters, `$-`, `-e/+e`, `-f/+f`, `-u/+u`, `-o/+o pipefail`, invalid options | deeper bash option parity stays outside Core100 unless oracle-backed |
| `read` | shell | runtime-present | bash/dash | default read, `-r`, `-d`, `-n`, `-u`, IFS behavior, EOF exit status | must use shared fd table; no host stdin access |
| `source` | shell | runtime-present | bash | `source file`, `. file`, arguments, missing file, return inside sourced file | fixture must prove current-shell state mutation |
| `alias` | shell | new-command | bash | list, set, quote presentation, lookup, invalid names | expansion only when shell runtime opts allow alias expansion |
| `unalias` | shell | new-command | bash | remove one, remove many, `-a`, missing alias diagnostics | must not affect command registry entries |
| `umask` | shell | runtime-present | bash/coreutils | default, `-p`, `-S`, octal, symbolic modes, invalid modes | already affects WorkspaceFS creation modes; needs Core100 fixture promotion |
| `rmdir` | filesystem | new-command | coreutils `rmdir.c` | empty dir removal, multiple dirs, `-p`, `--ignore-fail-on-non-empty`, missing/non-empty errors | only WorkspaceFS paths; no host path deletion |
| `unlink` | filesystem | new-command | coreutils `unlink.c` | single operand, missing operand, extra operand, dir error | same policy as `rm` without recursive behavior |
| `truncate` | filesystem | new-command | coreutils `truncate.c` | `-s`, `--size`, `-c`, grow, shrink, create, missing file, suffixes | bounded by WorkspaceFS file-size policy |
| `dd` | filesystem/data | policy-sensitive | coreutils `dd.c` | `if=`, `of=`, `bs=`, `count=`, `skip=`, `seek=`, `status=none`, stdin/stdout | no devices, no `/dev`, no sparse-host escape, max output and file-size policy required |
| `split` | filesystem/text | new-command | coreutils `split.c` | default, `-l`, `-b`, `-n`, `-d`, `--additional-suffix`, prefix, stdin | output fan-out limit required |
| `install` | filesystem | policy-sensitive | coreutils `install.c` | copy file, `-D`, `-d`, `-m`, `-T`, preserve content, missing source errors | owner/group options are deferred; no host privilege semantics |
| `tree` | filesystem/display | new-command | tree utility | dirs, files, `-a`, `-L`, `-d`, `-f`, `-i`, sorting, empty dirs | if Debian lacks `tree`, capture with installed package version recorded |
| `expr` | text/shell | new-command | coreutils `expr.c` | arithmetic, string, regex `:`, comparisons, exit codes 0/1/2/3 | shell quoting cases are mandatory |
| `strings` | text/binary | new-command | binutils strings | default, `-n`, `-a`, `-t d/o/x`, binary input, no printable strings | binutils package/version must be recorded |
| `fold` | text | new-command | coreutils `fold.c` | default width, `-w`, `-s`, bytes vs columns, long lines, stdin/files | Unicode and byte boundaries require byte fixtures |
| `expand` | text | new-command | coreutils `expand.c` | default, `-t`, multiple tab stops, stdin/files | tab and column behavior must be byte-checked |
| `unexpand` | text | new-command | coreutils `unexpand.c` | default, `-a`, `-t`, stdin/files | leading vs all blanks must be covered |
| `fmt` | text | new-command | coreutils `fmt.c` | default, `-w`, `-s`, `-u`, paragraphs, stdin/files | locale should be fixed to `C.UTF-8` |
| `shuf` | text | policy-sensitive | coreutils `shuf.c` | `-n`, `-i`, `-r`, `--random-source`, stdin/files | deterministic oracle requires fixed random source |
| `tsort` | text/graph | new-command | coreutils `tsort.c` | DAG, cycles, odd input count, repeated edges | stderr cycle wording must be captured |
| `uname` | environment | new-command | coreutils `uname.c` | default, `-a`, `-s`, `-n`, `-r`, `-m`, combinations | MSP must return virtual Linux-like identity, not leak iOS/macOS host |
| `whoami` | environment | new-command | coreutils `whoami.c` | default, invalid option | virtual identity policy required |
| `id` | environment | new-command | coreutils `id.c` | default, `-u`, `-g`, `-n`, `-G`, `-un`, invalid users | virtual uid/gid policy required |
| `hostname` | environment | policy-sensitive | hostname/coreutils compatible surface | display hostname, `-s`, `-f`, invalid option | setting hostname is forbidden in Core100 |
| `sleep` | process | policy-sensitive | coreutils `sleep.c` | integer/fractional durations, suffixes, invalid durations, multiple operands | strict maximum duration and cancellation are mandatory |
| `base32` | encoding | new-command | coreutils `base32.c` | encode/decode, `-d`, `-w`, invalid input, stdin/files | streaming and invalid byte diagnostics required |
| `basenc` | encoding | new-command | coreutils `basenc.c` | `--base64`, `--base64url`, `--base32`, `--base16`, decode, wrap | only encodings present in Debian oracle are Core100 |
| `sha512sum` | digest | new-command | coreutils digest | file/stdin, multiple files, `-c`, missing file, binary/text markers | should share digest implementation with existing sums |
| `b2sum` | digest | new-command | coreutils digest | file/stdin, multiple files, `-c`, `-l`, missing file | should share digest implementation with existing sums |

## Required Oracle Coverage Per Command

Each command must have at least these Debian oracle cases before the command is
implemented or promoted:

1. no-option happy path;
2. common option happy paths listed in the matrix;
3. stdin case if the command reads stdin;
4. file operand case if the command reads files;
5. multiple operands if accepted by GNU behavior;
6. missing operand diagnostic;
7. invalid option diagnostic;
8. missing path diagnostic where applicable;
9. path with spaces and shell metacharacters;
10. non-UTF-8 or binary input if byte behavior matters;
11. long line or large file boundary if the command can stream;
12. side-effect file-tree diff if the command writes or removes files;
13. exit-code case for non-error semantic false states such as `expr` false or
    `tsort` cycles;
14. pipeline/redirection composition case through the shared shell runtime.

## Implementation Acceptance Gates

A Core100 command is accepted only when all of these are true:

1. the matrix row is updated with supported and deferred options;
2. Debian 12 raw and normalized oracle fixtures exist;
3. local MSP runner compares stdout, stderr, exit code, and side effects at
   byte level against the normalized oracle;
4. performance-sensitive paths use WorkspaceFS streaming/range APIs instead of
   eager whole-tree or whole-file materialization unless the GNU algorithm
   itself requires global state;
5. diagnostics do not leak host physical paths;
6. implementation lives in SDK/shared command or shell runtime layers, not in
   a demo app;
7. agent-facing `exec_command` input/output remains plain text.
