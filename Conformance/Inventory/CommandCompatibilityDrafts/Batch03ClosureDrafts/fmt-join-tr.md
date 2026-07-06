# Batch 03 Closure Draft: fmt / join / tr

Scope: this draft covers only `fmt`, `join`, and `tr`. It is a proposed update for the Batch 03 matrix and does not edit `batch-03-text-streams.md`.

## `fmt`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/fmt.c`, especially `main`, `set_prefix`, `get_paragraph`, `fmt`, `fmt_paragraph`, `line_cost`, and `put_paragraph`.
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPFmtCommand.swift`.
- Local tests: `Tests/Swift/Unit/MSPPOSIXCore/Commands/Text/MSPTextLayoutCommandTests.swift`.
- Evidence:
  - `-g` / `--goal` now follows GNU `main`: when no max width option is present, a valid goal width sets the effective max width to `goal + 10`; when `-w` or old `-WIDTH` is present, `goal` must not exceed the selected max width.
  - Existing source-backed coverage remains for old first-argument `-WIDTH`, `-t` / `--tagged-paragraph`, `-c`, `-s`, `-u`, `-p`, large paragraph chunking, `--help`, and `--version`.
- Safe oracle case suggestions:
  - `fmt -g 90` on a short paragraph.
  - `fmt -g 90 -w 100` on a short paragraph.
  - `fmt -g 90 -w 80` expecting an invalid-width diagnostic.
  - Existing candidates from `fmt.md`: `fmt -12`, `fmt -w 20 -g 12`, `fmt -t -w 12`, large paragraph, and `fmt -p '# ' -w 12`.
- Parent-owned actions:
  - Byte-preserving non-UTF-8 formatting needs shared byte-record and column helpers.
  - Exact GNU layout cost parity for punctuation bonuses, tabs, and paragraph copying needs a deeper command rewrite plus oracle sampling.
  - Broken-pipe/write-error status belongs to shared output-stream policy.

## `join`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/join.c`, especially `keycmp`, `check_order`, `get_line`, `advance_seq`, `prfields`, `prjoin`, `join`, the `case 't'` option branch, and the `fp1 == fp2` stdin guard.
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPJoinCommand.swift`.
- Local tests: `Tests/Swift/Unit/MSPPOSIXCore/Commands/Text/MSPSortUniqCommandTests.swift`.
- Evidence:
  - Default disorder diagnostics now follow the source shape for the locally buffered merge: after an unpairable input is seen, a later detected disorder emits one GNU-shaped warning per file and exits with `join: input is not in sorted order`.
  - Join rows now carry original line numbers so `--header --check-order` diagnostics preserve source line numbers without ad hoc offset math.
  - Existing source-backed coverage remains for `-z`, `--check-order`, `--nocheck-order`, `--header`, `-o auto`, `-t ''`, `-t '\0'`, multi-character `-t` diagnostics, `join - -`, missing join fields as empty keys, `--help`, and `--version`.
- Safe oracle case suggestions:
  - Default mode with an unpairable line before an unsorted later line, expecting stdout plus warning/final exit according to GNU.
  - Existing candidates from `join-sort-uniq.md`: `join -z`, `join --check-order`, `join --header --check-order`, `join --nocheck-order`, `join -t, --header -a 1 -a 2 -e NA -o auto`, `join -t ''`, `join -t '\0'`, `join -t ab`, and `join - -`.
- Parent-owned actions:
  - True two-file streaming grouped merge needs shared bounded readers/backpressure and cancellation policy.
  - Byte-level field parsing with invalid UTF-8 needs shared byte-string records.
  - Locale collation and case folding need shared `LC_COLLATE` / `LC_CTYPE` policy.

## `tr`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tr.c`, especially `N_CHARS`, `look_up_char_class`, `append_char_class`, `find_bracketed_repeat`, `build_spec_list`, `get_next`, `validate`, `set_initialize`, `squeeze_filter`, `read_and_delete`, `read_and_xlate`, and `main`.
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPTrCommand.swift`.
- Local tests: `Tests/Swift/Unit/MSPPOSIXCore/Commands/Text/MSPNlTrCommandTests.swift`.
- Evidence:
  - Added modular coverage for POSIX `[:lower:]` to `[:upper:]` translation, complement plus squeeze over high-byte input, and delete plus squeeze mode.
  - Existing source-backed byte-table implementation covers ASCII/escaped operands through a 256-entry table, including NUL deletion, high-byte translation via octal escapes, complemented NUL preservation, NUL squeezing, streaming byte deletion, GNU operand-count diagnostics, octal escapes, and explicit repeat constructs.
- Safe oracle case suggestions:
  - `printf 'abc XYZ\n' | tr '[:lower:]' '[:upper:]'`.
  - `printf '\377A\377\377B' | tr -cs '[:alnum:]' '\n'`.
  - `printf '112xxxy\n' | tr -d -s '[:digit:]' x`.
  - Existing candidates from `nl-tr.md`: octal escapes, explicit repeats, NUL delete, high-byte translation, complemented NUL, NUL squeeze, delete extra operand, delete+squeeze missing operand.
- Parent-owned actions:
  - Complete GNU byte-table parity for non-ASCII literal argv operands needs a shared byte-set expression parser.
  - Locale-sensitive classes, equivalence classes, and exact invalid range diagnostics need a shared locale/parser policy.
  - Broken-pipe/write-error status and VPS fixture promotion remain coordinator work.

## Verification

- Passed: `TMPDIR="$PWD/.codex-tmp/local-tmp" swift build --target MSPPOSIXCore`.
- Passed: `TMPDIR="$PWD/.codex-tmp/local-tmp" swift test --filter MSPTextLayoutCommandTests --jobs 1` (5 tests).
- Passed: `TMPDIR="$PWD/.codex-tmp/local-tmp" swift test --filter MSPSortUniqCommandTests --jobs 1` (13 tests).
- Passed: `TMPDIR="$PWD/.codex-tmp/local-tmp" swift test --filter MSPNlTrCommandTests --jobs 1` (12 tests).
- Passed: `TMPDIR="$PWD/.codex-tmp/local-tmp" swift test --filter MSPTextStreamOracleTests --jobs 1` (2 tests).
- Passed: `git diff --check`.
