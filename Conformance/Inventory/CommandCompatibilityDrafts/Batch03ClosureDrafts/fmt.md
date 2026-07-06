# Batch 03 Closure Draft: fmt

Scope: this draft covers only `fmt`. It is a proposed update for the Batch 03 matrix, not a direct edit to `batch-03-text-streams.md`.

## `fmt`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/fmt.c`, especially `usage`, `long_options`, `main`, `set_prefix`, `fmt`, `set_other_indent`, `get_paragraph`, `get_line`, `get_prefix`, `get_space`, `flush_paragraph`, `fmt_paragraph`, `line_cost`, and `put_paragraph`.
- Command-local implementation changed: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPFmtCommand.swift`.
- Implemented evidence:
  - Added old first-argument `-WIDTH` parsing, matching the `main` pre-getopt special case.
  - Added `-t` / `--tagged-paragraph` parsing and secondary-indent handling modeled on `set_other_indent`.
  - Added `-g` / `--goal` parsing and goal-width based line-cost selection, while retaining `-w` as the hard maximum width.
  - Preserved existing `-c`, `-s`, `-u`, `-p`, `--help`, and `--version` entrypoints.
  - Added bounded paragraph chunking at 1,000 words, reflecting the source `MAXWORDS` flush behavior so huge paragraphs avoid unbounded O(n^2) layout memory.
  - Added modular tests in `MSPTextLayoutCommandTests` for `-WIDTH`, `-g`, `-t`, and a 1,200-word paragraph smoke check.
- Safe oracle case suggestions for coordinator:
  - `fmt -12` on `alpha beta gamma delta`.
  - `fmt -w 20 -g 12` on `alpha beta gamma delta`.
  - `fmt -t -w 12` on a first line followed by a differently indented second line.
  - `fmt -w 20` on a paragraph above 1,000 words.
  - `fmt -p '# ' -w 12` with matching and non-matching prefix lines.
- Needs parent/shared actions:
  - Exact GNU optimization cost parity still needs a closer implementation of `base_cost`, `line_cost`, punctuation bonuses, widow/orphan costs, and sentence-final handling.
  - Exact tab-column accounting and tab re-introduction should be shared with text layout byte/column helpers.
  - Byte-level input and non-UTF-8 paragraph preservation need shared byte record support; current command still formats through Swift `String`.
  - Broken-pipe/write-error behavior and VPS oracle promotion remain coordinator/shared work.
