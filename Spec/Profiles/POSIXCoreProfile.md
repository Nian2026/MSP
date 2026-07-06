# POSIX Core Profile

The POSIX Core profile is a narrow WorkspaceFS smoke profile. It is useful for
testing the filesystem boundary and the command registration surface, but it is
not the full MSP v1 Linux command layer. Full conformance is defined by
`MSPV1LinuxCommandLayerProfile.md`.

These commands are MSP-native commands: they use virtual workspace paths,
return shell text, and must not expose host sandbox paths.

## Smoke Commands

- `pwd`: print the current virtual working directory.
- `echo`: write arguments to standard output.
- `printf`: format and print text.
- `true`: return a successful exit status.
- `false`: return an unsuccessful exit status.
- `test` and `[`: evaluate simple shell test expressions.
- `ls`: list virtual workspace files and directories.
- `cat`: concatenate virtual workspace files.
- `mkdir`: create virtual workspace directories.
- `touch`: update virtual file timestamps or create empty files.
- `stat`: display virtual workspace metadata.
- `cp`: copy virtual workspace files and directories.
- `mv`: move or rename virtual workspace files.
- `rm`: remove virtual workspace files and directories.

## Filesystem Contract

- All path arguments are resolved through WorkspaceFS.
- Command output and diagnostics use virtual paths or user-provided operands.
- Hidden WorkspaceFS policy paths remain hidden even when commands accept
  options such as `ls -a`.
- Commands must continue to use shell-style plain text; they do not return JSON
  envelopes to the agent-facing bridge.

## Smoke Option Surface

- `ls`: `-1`, `-R`, `-l`, `-a`, `-d`, `-h`, `-r`, `-t`, `-S`,
  `--all`, `--almost-all`, `--recursive`, `--directory`,
  `--human-readable`, `--reverse`, `--sort`.
- `cat`: `-A`, `-e`, `-E`, `-b`, `-n`, `-s`, `-t`, `-T`, `-v`, `-u`,
  `--show-all`, `--show-ends`, `--number-nonblank`, `--number`,
  `--squeeze-blank`, `--show-tabs`, `--show-nonprinting`.
- `mkdir`: `-p`, `--parents`.
- `touch`: `-c`, `--no-create`.
- `stat`: `-c`, `--format`, `--printf`.
- `cp`: `-r`, `-R`, `-f`, `--recursive`, `--force`.
- `mv`: `-f`, `--force`.
- `rm`: `-r`, `-R`, `-f`, `--recursive`, `--force`.
- `test` and `[`: string tests, integer comparisons, `-e`, `-f`, `-d`,
  `-n`, `-z`, and `!`.
