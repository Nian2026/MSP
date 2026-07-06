# Batch 03 grep Closure Draft

This is a grep-only closure proposal. It does not edit
`batch-03-text-streams.md`, oracle capture generators, or promoted fixtures.

## Source Evidence

- GNU grep 3.8 driver:
  `References/LinuxSourceSnapshot/debian12-bookworm/sources/grep-3.8/src/grep.c`
- Option surface: `short_options`, `long_options`.
- Context parsing: `get_nondigit_option`, `context_length_arg`, and the main
  switch cases for `A`, `B`, `C`.
- Binary handling: `binary_files`, `grep`, `grepdesc`.
- Directory/device policy: `directories_type`, `directories_args`,
  switch cases `D`, `d`, `r`, `R`, plus `grepdirent`.
- Include/exclude policy: `exclude_options`, `skipped_file`,
  `EXCLUDE_OPTION`, `INCLUDE_OPTION`, `EXCLUDE_FROM_OPTION`,
  `EXCLUDE_DIRECTORY_OPTION`.
- Output precedence: `list_files`, `count_matches`, `exit_on_match`,
  `out_quiet`, and the post-parse precedence block where `-q` overrides
  `-l/-L`, which override `-c`.
- Empty explicit pattern sources: the early return at `grep.c` lines 2906-2911
  treats an empty key set as a real no-match condition instead of falling back
  to positional PATTERNS.
- Prefix and initial-tab behavior: `print_line_head`, `print_offset`,
  `align_tabs`.
- Color handling: `COLOR_OPTION`, `color_option`, `init_colorize`,
  `parse_grep_colors`.

## Implemented Evidence

- `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPGrepCommand.swift`
  now preprocesses GNU digit context aliases such as `-1` into context mode.
- Added source-backed context rendering for `-A`, `-B`, `-C`,
  `--after-context`, `--before-context`, `--context`,
  `--group-separator`, and `--no-group-separator`.
- `-C` and digit aliases now act as the GNU default context value: explicit
  `-A` or `-B` values retain priority even when `-C` appears later.
- Added local binary policy for `--binary-files=binary|text|without-match`,
  `-I`, and `-a/--text`.
- Added directory policy validation for
  `--directories=read|recurse|skip` and `-d read|recurse|skip`.
- Added device policy validation for `--devices=read|skip` and
  `-D read|skip`; MSP WorkspaceFS exposes no host device nodes here.
- Added accepted Linux-compatible options `-U/--binary`,
  `-T/--initial-tab`, and `-u/--unix-byte-offsets`; `-u` emits the GNU
  obsolete warning, and `-T` changes prefixed output by inserting the initial
  tab before line content.
- Count/list/quiet precedence is covered locally: `-l` and `-L` suppress
  `-c` output, and `-q` suppresses both normal output and count/list output.
- `--color`, `--colour`, `--color=never|no|none`, and
  `--color=auto|tty|if-tty` are accepted as no-color output. This matches the
  GNU non-tty path where `color_option == 2` is disabled after the `isatty`
  check.
- `--color=always|yes|force` now fails with an explicit exit-2 diagnostic
  because MSP does not yet have colored match-span rendering.
- Invalid `--color=VALUE` now fails with an explicit diagnostic instead of
  being silently ignored or treated as a pattern.
- `--include=GLOB`, `--exclude=GLOB`, `--exclude-from=FILE`, and
  `--exclude-dir=GLOB` now have WorkspaceFS-local recursive filtering
  semantics. File filters apply to both command-line files and recursive
  entries; directory filters prune recursive descendants while preserving the
  command-line root directory.
- `--dereference-recursive` is accepted as the long form of `-R` and enters
  recursive search. Exact symlink-following remains a parent-owned WorkspaceFS
  policy question.
- Missing `-f FILE` and `--exclude-from=FILE` operands now report grep-style
  exit-2 diagnostics instead of surfacing raw filesystem errors.
- Empty `-f FILE` pattern lists are now preserved as explicit pattern input:
  file operands remain input files, `grep -f empty file` exits no-match, and
  `grep -L -f empty file` can list the file as having no selected lines.
- Accepted unsafe no-op behavior is reduced: `-P`, `--line-buffered`,
  and forced color output still fail with exit 2 rather than pretending to
  perform unsupported behavior.

## Test Evidence

- Updated
  `Tests/Swift/Unit/MSPPOSIXCore/Commands/Text/MSPTextLanguageCommandOracleTests.swift`.
- Added local assertions for:
  `-NUM`, context separators, `--group-separator`,
  `--no-group-separator`, GNU `-C` default-context priority,
  `--directories=skip`, `--directories=read`, invalid directory methods,
  all three `--binary-files` modes, `-z`, `-Z`, `-I`, `-T`, `-u`, invalid
  binary modes, no-color `--color`/`--colour=never`, forced-color diagnostics,
  invalid-color diagnostics, recursive include/exclude/exclude-from/exclude-dir
  filtering, `--dereference-recursive`, missing `--exclude-from`, and
  `-c/-l/-L/-q` precedence.
- Added explicit empty-pattern-file assertions for `grep -f empty file` and
  `grep -L -f empty file`.
- Current targeted commands attempted with
  `TMPDIR="$PWD/.codex-tmp/local-tmp"`:
  `swift build --target MSPPOSIXCore` and
  `swift test --filter MSPTextLanguageCommandOracleTests --jobs 1`.
- Current result on this shared worktree: both Swift commands were blocked
  before executing grep tests by an out-of-scope compile error in
  `MSPTeeCommand.swift`; `git diff --check` passed.

## Capture Candidates For Parent Sampling

All cases are safe inside the standard temporary case root and do not require
host paths or system mutation:

- `grep --help` and `grep -V` exact Debian 12 stdout/stderr/exit capture.
- `printf 'zero\none\ntwo\nthree\nfour\nfive\nsix\n' | grep -n -1 three`.
- `printf 'zero\none\ntwo\nthree\nfour\nfive\nsix\n' | grep -E -A1 -B1 --group-separator='***' 'one|five'`.
- `printf 'zero\none\ntwo\nthree\nfour\nfive\nsix\n' | grep -E -C1 --no-group-separator 'one|five'`.
- `printf 'hit\nmiss\n' > f; grep -c -l hit f; grep -c -L hit f; grep -q -c hit f`.
- `printf 'a\0b\n' > bin; grep --binary-files=without-match a bin; grep --binary-files=text a bin; grep --binary-files=binary a bin; grep -I a bin`.
- `mkdir d; printf 'hit\n' > d/f; grep --directories=skip hit d; grep --directories=read hit d`.
- `printf 'hit\n' > f; grep -nT hit f; grep -u hit f`.
- `: > empty; printf 'hit\n' > f; grep -f empty f; grep -L -f empty f`.
- `printf 'hit\n' > f; grep --color hit f; grep --colour=never hit f; grep --color=always hit f; grep --color=bad hit f`.
- `mkdir -p tree/nested tree/vendor; printf 'hit\n' > tree/keep.txt tree/skip.log tree/nested/keep.swift tree/vendor/keep.txt; printf '*.log\n' > exclude-patterns.txt; grep -r --include='*.txt' hit tree; grep -r --exclude='*.log' --exclude-dir=vendor hit tree; grep -r --exclude-from=exclude-patterns.txt hit tree; grep --dereference-recursive --exclude='*.log' hit tree`.

## Parent/Shared Actions

- Exact GNU help/version support still needs parent-captured Debian 12 text or
  a shared GNU standard option helper. Any local help/version smoke coverage is
  not a substitute for exact oracle promotion.
- Recursive traversal parity still needs a shared WorkspaceFS traversal policy
  for exact `-r` versus `-R` symlink handling and loop detection. The local
  include/exclude pruning covers common WorkspaceFS path filters, but GNU
  exclude library corner cases still need oracle review.
- Byte/NUL fidelity still needs a shared byte-record bridge for `-z`, raw NUL
  stdout, byte-accurate offsets, invalid UTF-8, and agent-visible binary output.
- Regex parity still needs a shared matcher decision for BRE vs ERE and PCRE
  (`-P`) rather than relying on Foundation `NSRegularExpression`.
- Forced color output still needs colored match-span rendering and exact GNU
  `GREP_COLORS`/`GREP_COLOR` handling before `--color=always|yes|force` can
  be enabled.
- Pipeline write-error and broken-pipe exit fidelity should be handled in the
  shared streaming/output layer, not locally inside grep.

## Suggested Matrix Update

Closure status can cite the grep implementation and test evidence above for
local closure of context output, digit context aliases, binary-file modes,
directory method diagnostics, no-color `--color` handling,
initial-tab/obsolete-warning behavior, recursive include/exclude filters, and
count/list/quiet precedence. The only grep items that should stay with the
parent are exact help/version capture, exact recursive/symlink traversal
policy, byte/NUL bridge behavior, shared regex/PCRE parity, forced-color
rendering, full GNU exclude-library corner cases, and shared pipeline
write-error semantics.
