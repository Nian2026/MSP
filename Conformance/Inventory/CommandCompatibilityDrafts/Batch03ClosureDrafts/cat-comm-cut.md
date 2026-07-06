# Batch 03 Closure Draft: cat / comm / cut

Scope: this draft covers only `cat`, `comm`, and `cut`. It is a proposed update for the Batch 03 matrix, not a direct edit to `batch-03-text-streams.md`.

## `cat`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cat.c`, especially `usage`, `simple_cat`, `cat`, `copy_cat`, and `main`.
- Command-local implementation changed: `MSPCatCommand.swift`.
- Implemented evidence: added GNU `--help` and `--version` handling through the command option parser; preserved existing byte-oriented rendering for `-A/-e/-E/-t/-T/-v`, including high-bit bytes and invalid UTF-8 when only `-E` or `-T` is active; added modular tests for help/version and for continuing across `FILE missing FILE` while returning exit 1 with accumulated stdout and ordered stderr.
- Oracle-safe sampling candidates for coordinator: `cat --help | head -n 3`, `cat --version`, `cat good missing good`, `cat -A all-bytes.bin`, repeated `-` stdin, partial final lines, and stdout broken-pipe behavior with `cat huge | head -c 1`.
- Parent/shared actions: byte streaming for rendered modes still needs a shared streaming file reader/output writer; closed stdout and broken-pipe exit semantics need shared output-stream status propagation; exact Linux oracle promotion remains coordinator-owned.

## `comm`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/comm.c`, especially `usage`, `writeline`, `check_order`, `compare_files`, and `main`.
- Command-local implementation changed: `MSPCommCommand.swift`.
- Implemented evidence: added GNU `--help` and `--version`; added the source-backed `FILE1 FILE2` guard that rejects `- -`; added source-backed duplicate `--output-delimiter` handling where repeated identical delimiters are accepted but conflicting values fail; retained byte/NUL record comparison and existing `--check-order`, `--nocheck-order`, `--total`, and `-z` behavior; adjusted default disorder diagnostics to follow `compare_files`/`check_order` by warning only after an unpairable line is seen, so identical unsorted inputs do not fail by default; `--total` is emitted before the final default sortedness failure, matching the source order; `--check-order` and `--nocheck-order` now follow the `main` option parse order where the later option wins; `MSPCatCommCutCommandTests` covers `comm -z -12 - FILE` to prove NUL-delimited stdin/file mixing.
- Oracle-safe sampling candidates for coordinator: `comm --help | head -n 3`, `comm --version`, `comm - -`, duplicate same/different `--output-delimiter`, `comm -z`, `comm --total`, sorted inputs, identical unsorted inputs under default mode, unpaired unsorted inputs under default/check/nocheck, binary records, and multi-byte locale collation cases.
- Parent/shared actions: GNU `LC_COLLATE` parity requires a shared locale/collation policy; truly streaming two-file merge requires a shared streaming file reader; broken-pipe/write-error status is shared output-runtime work.

## `cut`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cut.c`, especially `usage`, `cut_bytes`, `cut_fields`, `cut_file`, and `main`; `set-fields.c` remains the source for exact range diagnostics.
- Command-local implementation changed: `MSPCutCommand.swift`.
- Implemented evidence: added GNU `--help` and `--version`; changed repeated selection lists to fail with GNU-style `only one list may be specified`; added GNU diagnostics for `-d` outside field mode and `-s` outside field mode; retained NUL record processing and added a regression for `cut -z -b 1` on final unterminated record, which emits a trailing NUL like `cut_bytes` emits `line_delim` at EOF; implemented `--output-delimiter` for byte and character modes by inserting the delimiter before each selected range after the first, matching `cut_bytes` `print_delimiter && is_range_start_index` and `set_fields` non-overlapping increasing range semantics; changed `-c/--characters` to the GNU 9.1 source shape where `main` sets `byte_mode = true` for both `-b` and `-c`, preserving raw bytes including invalid UTF-8 instead of using Swift `Character` semantics; changed `-d` and `--output-delimiter` to raw argument bytes so `\\0` is literal/backslash-zero while empty arguments mean NUL; added command-local blank/tab LIST separators per `set-fields.c`.
- Oracle-safe sampling candidates for coordinator: `cut --help | head -n 3`, `cut --version`, `cut -d : -b 1`, `cut -s -c 1`, repeated `-b`, invalid LIST forms from `set-fields.c`, `cut -z -b 1`, `cut -d '' -f2`, `cut --output-delimiter=: -b 1,3`, `cut --output-delimiter=: -b 1,2`, `cut --complement --output-delimiter=: -b 2-3`, `cut -c 1` over invalid UTF-8 bytes, binary bytes, multi-file partial failures, and huge input streaming.
- Parent/shared actions: exact `set-fields.c` diagnostics should be shared by range parsing; multi-file streaming needs a shared streaming file reader; broken-pipe/write-error status is shared output-runtime work.
