# Batch 03 Closure Draft: nl / tr

Scope: this draft covers only `nl` and `tr`. It is a proposed update for the Batch 03 matrix, not a direct edit to `batch-03-text-streams.md`.

## `nl`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/nl.c`, especially `build_type_arg`, `print_lineno`, `reset_lineno`, `proc_header`, `proc_body`, `proc_footer`, `proc_text`, `check_section`, `process_file`, and `main`.
- Command-local implementation changed: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPNlCommand.swift`.
- Implemented evidence:
  - Added GNU/POSIX option surface for `-h/--header-numbering`, `-f/--footer-numbering`, `-d/--section-delimiter`, `-l/--join-blank-lines`, and `-p/--no-renumber`, in addition to the existing `-b/-i/-n/-w/-s/-v` forms.
  - Added header/body/footer section state with default delimiter `\:`; section delimiter lines switch section, emit the source-compatible blank output line, and reset numbering unless `-p` is present.
  - Added one-character `-d C` handling that preserves the default second delimiter character, matching the `nl.c` mutation of `DEFAULT_SECTION_DELIMITERS`; empty `-d ''` disables delimiter recognition.
  - Added `a`, `t`, `n`, and `pBRE` numbering styles for header/body/footer. Regex matching is command-local via Foundation regular expressions, so basic anchored/filter cases are covered while exact GNU regex dialect parity remains a shared compatibility review item.
  - Added `-l NUMBER` blank-line joining for style `a`, and corrected unnumbered-line padding to use `width + separator.count`.
  - Added modular tests in `MSPNlTrCommandTests` for default section delimiters, custom section delimiters, `-p`, `-l`, `pBRE`, and invalid section-style diagnostics.
- Safe oracle case suggestions for coordinator:
  - `nl -ha -ba -fa -w2 -s: section-input.txt` with default `\:\:\:`, `\:\:`, and `\:` markers.
  - `nl -ba -p -w1 -s: section-input.txt`.
  - `nl -ba -d :: -w1 -s: custom-delimiter.txt`.
  - `nl -ba -l2 -w1 -s:` with three consecutive blank lines.
  - `nl -bp'^A' -w1 -s:` with matching and non-matching lines.
- Needs parent/shared actions:
  - Exact GNU `pBRE` parity should be reviewed against the repo-wide regex policy; Foundation regex is sufficient for common local cases but is not the same engine as `re_compile_pattern` with GNU/POSIX basic syntax.
  - Local `--help`/`--version` entrypoints are implemented; exact full GNU help text remains a broader coreutils help-text policy.
  - Broken-pipe/write-error behavior belongs to shared output-stream status propagation.
  - Coordinator-owned VPS sampling and fixture promotion are still required for the safe oracle cases above.

## `tr`

- Reference source checked: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/tr.c`, especially `long_options`, `usage`, `unquote`, `look_up_char_class`, `append_range`, `append_char_class`, `append_equiv_class`, `find_bracketed_repeat`, `build_spec_list`, `get_next`, `get_spec_stats`, `validate`, `set_initialize`, `squeeze_filter`, `read_and_delete`, `read_and_xlate`, and `main`.
- Command-local implementation changed: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Text/MSPTrCommand.swift`.
- Implemented evidence:
  - Added source-backed GNU operand-count validation from `main`: missing operand, missing second operand for translate, missing second operand for delete+squeeze, and extra operand for delete-without-squeeze now fail before input processing.
  - Added command-local set preprocessing for GNU `unquote` escape cases: octal `\NNN` with one to three octal digits, `\\`, `\a`, `\b`, `\f`, `\n`, `\r`, `\t`, and `\v`.
  - Added command-local explicit repeat expansion for `[CHAR*REPEAT]`, including decimal and leading-zero octal repeat counts, plus source-backed diagnostics for `[c*]`/`[c*0]` in string1 and multiple indefinite repeats in string2.
  - Added a command-local 256-entry byte processor for ASCII/escaped set operands. This covers source-backed `N_CHARS == 256`, `set_initialize`, `read_and_delete`, `read_and_xlate`, and `squeeze_filter` behavior for NUL/high-byte input without touching shared readers or parsers.
  - Byte processor evidence covers `tr -d '\000'`, `tr '\377' X`, `tr -c '\000' X`, and `tr -s '\000'` over raw `Data`, preserving bytes instead of UTF-8 replacement.
  - Kept existing ASCII POSIX class/range/complement/delete/squeeze/translate behavior through `MSPPOSIXScalarSetExpression`, without changing shared support.
  - Added modular tests in `MSPNlTrCommandTests` for octal escapes, explicit repeat translation, newline deletion through `\012`, delete extra-operand diagnostics, delete+squeeze missing-operand diagnostics, NUL deletion, high-byte translation, complemented NUL preservation, and NUL squeezing.
- Safe oracle case suggestions for coordinator:
  - `printf 'ababa\n' | tr '\141\142' XY`.
  - `printf 'abc cab\n' | tr abc '[X*3]'`.
  - `printf 'a\nb\n' | tr -d '\012'`.
  - `printf 'A\0B\0' | tr -d '\000'`.
  - `printf '\377A\377' | tr '\377' X`.
  - `printf '\0\377A' | tr -c '\000' X`.
  - `printf '\0\0A\0\0' | tr -s '\000'`.
  - `printf a | tr -d a b`.
  - `printf aa | tr -d -s a`.
  - `printf 'aaab\n' | tr -s '[:alpha:]'`.
- Needs parent/shared actions:
  - Complete GNU byte-table parity still needs a shared byte-set expression parser. The local byte processor is intentionally limited to ASCII/escaped set operands, and does not make non-ASCII literal operands behave like GNU argv bytes.
  - Locale-sensitive classes, `[:upper:]`/`[:lower:]` paired case conversion, and class order require a shared locale/collation policy matching `setlocale`, `isupper`, `islower`, and related ctype calls.
  - `[=CHAR=]` equivalence classes and exact invalid range diagnostics should live in the shared byte-set parser rather than a command-local shim.
  - Complemented translation over ASCII/escaped operands now uses a local byte table; broader mixed locale/non-ASCII argv semantics should be reworked with the shared byte parser.
  - Local `--help`/`--version` entrypoints are implemented; exact full GNU help text, broken-pipe/write-error behavior, and VPS oracle promotion remain coordinator/shared work.
