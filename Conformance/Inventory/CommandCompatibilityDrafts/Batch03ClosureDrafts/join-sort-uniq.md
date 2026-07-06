# Batch 03 Closure Draft: join / sort / uniq

Scope: this draft covers only `join`, `sort`, and `uniq`. It is a proposed update for the Batch 03 matrix, not a direct edit to `batch-03-text-streams.md`. It intentionally does not edit oracle fixtures, capture scripts, registry, Package.swift, or shared runtime.

## `join`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/join.c`
  - option table and help surface: `longopts`, `usage`
  - field list and `-o auto`: `add_field_list`, `autoformat`, `autocount_1`, `autocount_2`
  - header and merge loop: `join`
  - ordering diagnostics: `check_order`
  - output construction: `prjoin`, `prfields`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPJoinCommand.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - `-z` and `--zero-terminated` switch input and output record delimiters to NUL while preserving byte output.
  - `--check-order` now emits GNU-shaped fatal diagnostics with file name, source line number, and offending line text; `--header` adjusts the data-line offset.
  - `--nocheck-order` is accepted as the explicit local opt-out for fatal checking.
  - `--header` prints a joined header line before data rows and removes headers from the merge stream.
  - `-o auto` computes output field counts from the header or first data row, then fills absent fields with `-e` replacement where applicable.
  - `-t ''` treats the whole record as the single join field, matching the `newtab = '\n'` branch in `join.c`.
  - `-t '\0'` uses NUL as the field separator while keeping the record delimiter unchanged, matching the `STREQ (optarg, "\\0")` branch in `join.c`.
  - Multi-character `-t` values now fail with a GNU-shaped `multi-character tab` diagnostic, and `join - -` fails before consuming stdin.
  - Lines with a missing join field now participate with an empty join key instead of being dropped.
  - Tests: `MSPSortUniqCommandTests.testJoinSupportsHeaderZeroTerminatedCheckOrderAndAutoFormat`.
- Safe oracle case suggestions for coordinator:
  - `join --help`
  - `join --version`
  - `join -z left right` with NUL-delimited files
  - `join --check-order unsorted sorted`
  - `join --header --check-order header-unsorted sorted`
  - `join --nocheck-order unsorted sorted`
  - `join -t, --header -a 1 -a 2 -e NA -o auto left.csv right.csv`
  - `join -t '' whole-left whole-right`
  - `join -t '\0' nul-separated-left nul-separated-right`
  - `join -t ab left right`
  - `join - -`
  - `join -a 1` where the selected join field is absent on one row
- Coordinator-owned actions:
  - Locale collation and case folding need a shared `LC_COLLATE`/`LC_CTYPE` policy; local comparison remains byte/String based.
  - GNU default disorder warning behavior after unpairable lines is separate from explicit `--check-order` and should be sampled before broad enablement.
  - Truly streaming two-file merge and cancellation/output backpressure need shared streaming readers and bounded output policy.
  - Byte-level field parsing with invalid UTF-8 should be sampled before declaring full field-separator parity.

## `sort`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/sort.c`
  - option table and help surface: `long_options`, `sort_args`, `usage`
  - check modes: `CHECK_OPTION`, `check_type`, `check`
  - stable and last-resort tie breaking: `stable`, `check_ordering_compatibility`, `compare`
  - key and comparison flow: `keycompare`, `compare`, `sort`
  - field separator validation: main switch case `t`, including `empty tab`,
    `\0`, and `multi-character tab`
  - merge/temp model: `merge`, `mergefiles`, `sortlines`, `default_sort_size`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPSortCommand.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - `-C`, `--check=quiet`, and `--check=silent` check ordering while suppressing first-disorder diagnostics; invalid `--check=WORD` fails before sorting.
  - `-s` and `--stable` are accepted and disable the local last-resort bytewise tie-breaker for sorting and check mode.
  - `-b/--ignore-leading-blanks`, `-g/--general-numeric-sort`, `-i/--ignore-nonprinting`, `-M/--month-sort`, `-V/--version-sort`, and `--sort=general-numeric|human-numeric|month|numeric|version` now route through command-local comparison logic backed by the source `set_ordering`/`SORT_TABLE` shape.
  - Existing local support remains for default byte ordering, `-n`, `-h`, `-r`, `-u`, `-z`, `-f`, `-d`, `-t`, basic `-k`, `-o`, and key-equivalence uniqueness.
  - `-t ''` now fails with GNU-shaped `empty tab`, `-t xx` fails with
    `multi-character tab`, and `-t '\0'` uses NUL as the command-local field
    separator.
  - Tests: `MSPSortUniqCommandTests.testSortSupportsCommonGNUOrderingOptions`, `MSPSortUniqCommandTests.testSortSupportsAdditionalGNUComparisonModes`, `MSPSortUniqCommandTests.testSortUniqueUsesSortKeyEquivalenceLikeGNUCoreutils`, and `MSPSortUniqCommandTests.testSortCanWriteOutputThroughWorkspaceFS`.
- Safe oracle case suggestions for coordinator:
  - `sort --help`
  - `sort --version`
  - `sort -C` on sorted and unsorted input
  - `sort --check=quiet` and `sort --check=silent`
  - `sort --check=bad`
  - `sort -n -s` with equal numeric keys and different trailing text
  - `sort -n -s -c` with equal numeric keys in original order
  - `sort -u -t '|' -k 2,2n`
  - `sort -t '\0' -k 2,2n` with NUL-separated fields
  - `sort -t ''` and `sort -t xx` diagnostics
  - `sort -o out in`
  - `sort -b`, `sort -i`, `sort -M`, `sort -V`, and `sort --sort=general-numeric`
- Coordinator-owned actions:
  - Locale collation, dictionary classing, folding, and numeric punctuation need a shared locale/parser policy.
  - External merge, temp spill, `--batch-size`, `--temporary-directory`, `--parallel`, and memory-size handling need shared workspace temp-file and cancellation policy.
  - `--random-source`, `-R`, and deterministic random grouping need a shared randomness policy.
  - `--files0-from`, `--compress-program`, and `--debug` cross command-local parsing into file-list ingestion, subprocess policy, and diagnostic annotation.
  - Full GNU key grammar, including character offsets, per-key end positions, obsolete `+POS -POS`, and exact `filevercmp` corner cases should be sampled and implemented as a dedicated parser/comparator pass.

## `uniq`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/uniq.c`
  - option table and help surface: `longopts`, `usage`
  - obsolete syntax parser: `main` cases `1`, `0`...`9`
  - group methods: `grouping_method_string`, `grouping_method_map`, `GROUP_OPTION`
  - all-repeated delimiters: `delimit_method_string`, `delimit_method_map`, `-D`
  - output state machine: `check_file`
  - comparison fields: `find_field`, `different`
- Local implementation: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPUniqCommand.swift`
- Local evidence added/kept:
  - `--help` and `--version` return GNU coreutils 9.1 shaped output before input access.
  - `--all-repeated[=none|prepend|separate]` is accepted for both eager and streaming paths, with group delimiters matching the source state machine.
  - `--group[=separate|prepend|append|both]` is accepted for both eager and streaming paths and remains mutually exclusive with `-c/-d/-D/-u`.
  - Obsolete `-N` and `+N` syntax is normalized to field and character skips in argument order.
  - `-s/--skip-chars` and `-w/--check-chars` compare byte counts, matching `find_field` plus `different`/`memcmp`; `-i` now folds ASCII bytes instead of decoding to Unicode text, matching the source's byte-wise `memcasecmp` shape for the Core100 C-locale surface.
  - `-z -f` treats newline as a field separator, matching `system.h:field_sep`.
  - Invalid group/all-repeated methods fail before input processing.
  - Existing local support remains for `-c`, `-d`, `-D`, `-u`, `-i`, `-z`, `-f`, `-s`, `-w`, input operand, output operand, and streaming stdin/stdout.
  - Tests: `MSPSortUniqCommandTests.testUniqSupportsCountsFiltersAndComparisonOptions`, `MSPSortUniqCommandTests.testUniqSkipAndCheckCharacterCountsAreByteBased`, `MSPSortUniqCommandTests.testUniqIgnoreCaseAndZeroTerminatedFieldSkipsStayByteBased`, and `MSPSortUniqCommandTests.testUniqCanWriteOutputOperandThroughWorkspaceFS`.
- Safe oracle case suggestions for coordinator:
  - `uniq --help`
  - `uniq --version`
  - `uniq -1` and `uniq +2`
  - `uniq --group`, `--group=prepend`, `--group=append`, `--group=both`
  - `uniq --group -d`
  - `uniq --all-repeated=none`, `--all-repeated=prepend`, `--all-repeated=separate`
  - invalid `--group=bad` and `--all-repeated=bad`
  - `uniq -s 1` and `uniq -w 1` on multibyte UTF-8 records to verify byte counts
  - `uniq -z --group=both` with NUL-delimited records
- Coordinator-owned actions:
  - Exact host-locale case folding for `-i` requires shared `LC_CTYPE` policy; local command behavior is byte-wise ASCII folding.
  - Huge duplicate-run memory pressure, broken-pipe status, and output cancellation need shared pipeline/runtime policy.

## Targeted Test Status

- Current commands attempted with
  `TMPDIR="$PWD/.codex-tmp/local-tmp"`:
  `swift build --target MSPPOSIXCore` and
  `swift test --filter MSPSortUniqCommandTests --jobs 1`.
- Current result on this shared worktree: both Swift commands were blocked
  before executing sort tests by an out-of-scope compile error in
  `MSPTeeCommand.swift`; `git diff --check` passed.
