# Core100 Debian Oracle Capture Plan

This plan describes the capture work required before expanding the MSP Linux
command layer from 68 to 100 commands. It is intentionally oracle-first: do not
implement a command or parameter by guessing. Capture Debian 12 behavior first,
then implement against normalized byte-level fixtures.

## Capture Environment

- OS: Debian 12 bookworm.
- Shells: `/bin/sh` for POSIX-like cases and `/bin/bash --noprofile --norc`
  for bash-specific runtime cases.
- Locale: `LC_ALL=C.UTF-8`, `LANG=C.UTF-8`, `TZ=UTC`.
- PATH: fixed by the runner and recorded in the private capture metadata.
- CWD: runner-owned case root, normalized as `<CASE_ROOT>` or `/`.
- Privilege: non-root user only.
- Network: disabled for Core100 capture.

## Artifact Model

Private raw capture artifacts should keep real bytes and real temporary paths.
Public fixtures must be sanitized and normalized.

Required fields per case:

```json
{
  "id": "core100-command-option-example",
  "title": "human readable case title",
  "category": "core100-command-options",
  "case_type": "noninteractive",
  "shell": {"dialect": "bash", "argv": ["/bin/bash", "--noprofile", "--norc"]},
  "commands": ["example"],
  "command_line": "example --flag input.txt",
  "standard_input_b64": "",
  "fixture": {
    "kind": "isolated-temp-tree",
    "directories": ["in", "out"],
    "files": [{"path": "in/input.txt", "content_b64": "...", "mode": "0644"}]
  },
  "compare_fields": ["stdout", "stderr", "exit_code", "file_tree", "permissions", "side_effects"],
  "expected": {"stdout_b64": "...", "stderr_b64": "...", "exit_code": 0},
  "normalization": {"case_root": "<CASE_ROOT>"}
}
```

The first runner may use a richer private schema, but the imported public
fixture must keep the same observable fields used by the existing Debian 12
oracle fixture.

## Command Option Capture Requirements

Each command in `Docs/Standards/Core100CommandExpansionMatrix.md` must receive
the following minimum case families. More cases are expected for complex
commands such as `dd`, `install`, `split`, `alias`, and `read`.

| Family | Required case shape |
| --- | --- |
| presence | `command -v`, `type`, invalid lookup interactions where shell-visible |
| default output | no-option behavior and default stdout/stderr/exit code |
| common options | every option listed in the Core100 matrix |
| option combinations | at least two realistic multi-option combinations |
| invalid options | short and long invalid option diagnostics |
| missing operands | diagnostics and exit codes for too few operands |
| extra operands | diagnostics and exit codes for too many operands |
| stdin | stdin-only behavior when supported |
| file operands | one file, multiple files, missing file |
| paths | spaces, leading dash, glob characters, unicode, newline in filename when safe |
| binary | binary/non-UTF-8 input for byte-oriented commands |
| long input | long line and multi-chunk file behavior |
| side effects | file-tree diff, mode diff, symlink diff, content hash |
| pipeline | command in a pipeline, including downstream early close where relevant |
| redirection | stdin/stdout/stderr redirection around the command |

## Per-Command Capture Checklist

| Command | Minimum case count | Must include |
| --- | ---: | --- |
| `export` | 12 | no args, `-p`, `-n`, assignment, invalid identifier, child env visibility |
| `unset` | 10 | variable, function, arrays, missing, `-v`, `-f`, invalid option |
| `set` | 14 | positional params, `$-`, `-e`, `-u`, `-f`, `pipefail`, invalid options |
| `read` | 16 | default, `-r`, `-d`, `-n`, `-u`, IFS, EOF, closed fd |
| `source` | 12 | state mutation, arguments, missing file, return, nested source |
| `alias` | 12 | list, set, quote rendering, expansion on/off, invalid names |
| `unalias` | 8 | remove one/many, `-a`, missing alias, invalid option |
| `umask` | 12 | default, `-p`, `-S`, octal, symbolic, file creation side effects |
| `rmdir` | 12 | empty, non-empty, `-p`, ignore non-empty, missing, multiple dirs |
| `unlink` | 8 | file, missing, directory, extra operands, leading-dash path |
| `truncate` | 14 | create, no-create, grow, shrink, suffixes, invalid size, sparse policy |
| `dd` | 20 | stdin/stdout, file in/out, `bs`, `count`, `skip`, `seek`, status, errors |
| `split` | 18 | default, lines, bytes, numeric suffix, suffix, stdin, output fan-out |
| `install` | 18 | copy, `-D`, `-d`, `-m`, `-T`, existing target, missing source |
| `tree` | 14 | default, depth, dirs only, all files, full paths, sorting, empty dirs |
| `expr` | 16 | arithmetic, strings, regex, comparisons, false result, syntax error |
| `strings` | 12 | default, min length, offsets, binary input, no strings |
| `fold` | 10 | width, spaces, bytes/columns, long line, file/stdin |
| `expand` | 10 | default tabs, tab stops, multiple stops, file/stdin |
| `unexpand` | 10 | leading blanks, all blanks, tab stops, file/stdin |
| `fmt` | 12 | default, width, split-only, uniform spacing, paragraphs |
| `shuf` | 12 | deterministic random source, `-n`, `-i`, repeat, file/stdin |
| `tsort` | 10 | simple DAG, repeated edges, cycle, odd input count |
| `uname` | 10 | default, `-a`, individual flags, combined flags |
| `whoami` | 4 | default, invalid option, env independence |
| `id` | 14 | default, `-u`, `-g`, `-G`, `-n`, combinations, invalid user |
| `hostname` | 6 | display, short, fqdn, invalid option, forbidden setter sample |
| `sleep` | 8 | zero, fractional, suffix, multiple operands, invalid, cancellation |
| `base32` | 10 | encode, decode, wrap, invalid input, file/stdin |
| `basenc` | 14 | base64, base64url, base32, base16, decode, invalid encoding |
| `sha512sum` | 10 | file/stdin, multiple files, check file, missing file |
| `b2sum` | 10 | file/stdin, multiple files, check file, `-l`, missing file |

This minimum plan yields more than 380 command-option cases before shell stress
cases. That is intentional.

## Shell Stress Capture Requirements

Shell stress is more important than any one command. It proves the shared
runtime does not reveal itself as fake when commands are composed.

Required stress families:

1. long command line;
2. long single argument;
3. long environment assignment;
4. long pipeline;
5. many redirections;
6. nested quoting;
7. command substitution;
8. arithmetic expansion;
9. parameter expansion operators;
10. glob, extglob, globstar, dotglob, nullglob, failglob;
11. brace expansion;
12. heredoc and quoted heredoc;
13. here-string;
14. functions and local state;
15. loops and loop control;
16. `if`, `case`, `&&`, `||`, `!`;
17. subshell and group command state isolation;
18. process substitution where supported by the runtime target;
19. descriptor table operations;
20. binary stdout/stderr and non-UTF-8 stdin;
21. broken pipe and early close;
22. timeout and cancellation.

The detailed case list lives in `Core100ShellStressCases.md`.

## Normalization Rules

Normalize only unstable host details:

- case root path -> `<CASE_ROOT>` or `/`;
- runner root path -> `<CASE_RUNNER_ROOT>`;
- generated command helper path -> `<CASE_COMMAND>`;
- Linux hostname -> `<LINUX_ORACLE_HOST>` when host-specific;
- private IPs -> `<IP_ADDRESS>`;
- timestamps and random names only when the command contract is not randomness.

Do not normalize real command behavior away. If GNU output includes spaces,
quotes, tabs, byte offsets, errno wording, or line prefixes, those must remain
byte-level expected output.

## Capture Batch Gates

A capture batch is accepted only when:

1. it passes `DebianOracleCaptureSafetyPolicy.md`;
2. every case has a stable id and declared covered commands;
3. every command row in the matrix has at least the minimum case count;
4. shell stress cases include the full shared-runtime family list;
5. stdout/stderr are captured as bytes, not decoded strings;
6. file-tree side effects are captured after the command;
7. private raw artifacts and public normalized fixtures are both generated;
8. the import step refuses unresolved physical host paths;
9. no blocked/dangerous case is silently skipped;
10. failures are reported as capture failures or explicit deferrals with reason.

## Current Runner Status

The non-destructive capture runner now lives at:

```text
Conformance/Scripts/core100_oracle_capture.py
```

The required preflight is:

```sh
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit
```

Only after both pass may `run-vps` execute cases. The runner executes each case
inside a fresh `/tmp/msp-oracle-capture-*` root, drops to a non-root identity
when the SSH user is root, enforces output and file-tree limits, and refuses to
promote a public oracle fixture when any runner limit is hit.
