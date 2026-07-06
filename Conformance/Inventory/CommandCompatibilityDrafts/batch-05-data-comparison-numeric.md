# Batch 05: Data, Comparison, Numeric

## b2sum
- **Command**: `b2sum`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Registry/MSPPOSIXCoreCommandPack.swift:16`; `Commands/Data/MSPChecksumCommands.swift:41-194`, `MSPDigestAlgorithm.blake2b` at `392-516`, `MSPBLAKE2b` at `519-685`.
- **Reference source**: `coreutils-9.1/src/digest.c` common checksum parser and verifier (`long_options`, `usage`, `main`); also `coreutils-9.1/src/blake2/b2sum.c` standalone BLAKE2 option parser (`usage`, `main`). Confirm which source Debian's installed `b2sum` was built from before treating `-a` as in-scope.
- **GNU/Linux parameter surface**: FILE operands and `-`; digest output and `-c/--check`; `-b/--binary`, `-t/--text`, `-l/--length=BITS`; `--tag`, `--zero`; check-only `--ignore-missing`, `--quiet`, `--status`, `--strict`, `-w/--warn`; help/version. Standalone source also exposes `-a blake2b|blake2s|blake2bp|blake2sp`.
- **Currently supported by MSP**: FILE operands, empty operand list as stdin, one consumed `-` stdin operand, multi-file output, `-b/-t` mode marker, `-c/--check`, `--status`, `-l/--length` for 8-bit multiples from 8 to 512, BSD tagged output, NUL-delimited `--zero` output, tagged check parsing, `--warn`, `--strict`, `--quiet`, `--ignore-missing`, `--help`, and `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None yet. If `-a blake2s/bp/sp` is absent from Debian's installed help and only belongs to unused standalone source, defer with explicit build evidence.
- **Forbidden by policy**: Reading host paths outside WorkspaceFS or following symlinks out of the workspace.
- **Performance model**: File hashing is chunked at 32 KiB through `readFileRange`; stdin and check files are eager `Data` loads. BLAKE2b is linear time with small hasher state, but check mode can trigger many workspace reads and needs cancellation and aggregate output limits.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because check mode and filename escaping are security-relevant and current support can silently diverge from GNU verification semantics.
- **Closure status**:
  - **Implemented evidence**: Swift registers `b2sum` through `MSPB2SumCommand`/`MSPDigestCommand` and implements BLAKE2b plus `-l/--length`, file/stdin rows, `-b/-t`, `-c`, `--status`, `--tag`, `--zero`, tagged check parsing, the check modifiers `--warn/--strict/--quiet/--ignore-missing`, `--help`, and `--version`; unit evidence includes `MSPWorkerFIdentityEncodingDigestTests.testSha512sumAndB2sumMatchCore100OracleBytes` and the shared digest option test; Core100 oracle has 10 `b2sum` cases including stdin, file, multiple, length, check ok/fail, missing, binary, zero-length, and space-path cases; vendored source is `coreutils-9.1/src/digest.c` plus `src/blake2/b2sum.c`.
  - **Implementation closure decision**: Coordinator action covers repeated-stdin semantics, exact unsupported-combination diagnostics, full binary/escaped filename byte parity, chunked stdin/check parsing, and a Debian-build decision for standalone `-a` algorithms.
  - **Oracle/stress closure plan**: Add broader GNU byte-for-byte cases for escaped/binary filenames, repeated `-`, huge stdin/check files, output caps, unsupported option combinations, and BLAKE2 length boundary/invalid values.
  - **Deferred/forbidden with reason**: No common GNU checksum parameter is deferred. Host paths outside WorkspaceFS and symlink escapes remain forbidden by policy; optional standalone `-a blake2s/bp/sp` may be deferred only with Debian installed-help/build evidence.

## base32
- **Command**: `base32`
- **MSP implementation**: `MSPBase32Command` facade in `Commands/Data/MSPBase32BasencCommands.swift:4-17`; shared runner/parser/codec owners under `Commands/Data/BaseEncoding/`, including `BaseEncodingCommandRunner.swift`, `BaseEncodingOptions.swift`, `BaseEncodingKind.swift`, `BaseEncodingStreaming.swift`, `BaseEncodingDecoding.swift`, `BaseEncodingBase32.swift`, `BaseEncodingInput.swift`, and `BaseEncodingHelp.swift`.
- **Reference source**: `coreutils-9.1/src/basenc.c`, `long_options`, `usage`, and `main`; `BASE_TYPE` selects the base32 applet.
- **GNU/Linux parameter surface**: `[OPTION]... [FILE]`; `-d/--decode`, `-i/--ignore-garbage`, `-w/--wrap=COLS`, `--help`, `--version`; stdin on no FILE or `-`; one FILE only.
- **Currently supported by MSP**: No operand or one FILE/`-`; encode and decode; `-d`, `-i`, `-w COLS`/`--wrap=COLS`; default wrap 76; file input streamed in chunks for encode/decode; `--help`; `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File path mode streams input but accumulates encoded/decoded output in memory; stdin mode is eager. Runtime is O(n), memory should be bounded by output limits but is not currently enforced in the command.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: medium, because the option surface is small but byte parity and invalid-input diagnostics are easy to get subtly wrong.
- **Closure status**:
  - **Implemented evidence**: Swift uses `MSPBase32Command` and the shared `BaseEncoding` owner package; unit evidence includes encode/decode/ignore-garbage, `--version`, chunked file operands through `readFileRange`, invalid decode, wrapping, help, and extra-operand diagnostics in `MSPWorkerFIdentityEncodingDigestTests`; Core100 oracle has 10 `base32` cases covering encode, decode, wrap, file, multiple/extra operand, ignore-garbage, invalid decode, missing, zero-wrap, and space-path; vendored source is `coreutils-9.1/src/basenc.c` with `BASE_TYPE` selecting base32.
  - **Implementation closure decision**: Coordinator action covers exact GNU invalid-padding/overflow/extra-operand diagnostics, full RFC 4648 padding edge behavior, output-limit enforcement, and repeated `-` stdin behavior.
  - **Oracle/stress closure plan**: Add all-byte binary corpus, lowercase and mixed invalid alphabet cases, invalid padding matrix, huge streaming encode/decode, partial decoded output parity, repeated `-`, and exact stderr/exit-code captures.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## base64
- **Command**: `base64`
- **MSP implementation**: `Commands/Data/MSPBase64Command.swift:4-197`, with streaming encoder/decoder below that file.
- **Reference source**: `coreutils-9.1/src/basenc.c`, `long_options`, `usage`, and `main`; `BASE_TYPE` selects the base64 applet.
- **GNU/Linux parameter surface**: `[OPTION]... [FILE]`; `-d/--decode`, `-i/--ignore-garbage`, `-w/--wrap=COLS`, `--help`, `--version`; stdin on no FILE or `-`; one FILE only.
- **Currently supported by MSP**: `-d`, `-i`, `-w`/`--wrap`, `--help`, `--version`, one operand max, stdin/no operand, file operand, streamed file encoding/decoding, eager stdin encoding/decoding, binary stdout on decode.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File reads are chunked, but output is accumulated as `String` or `Data`; stdin is eager. O(n) time, O(output) memory, so large decode/encode needs streaming stdout and cancellation.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: medium, because common happy paths work but binary edge cases are not proven.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPBase64Command` supports `-d/--decode`, `-i/--ignore-garbage`, `-w/--wrap`, `--help`, `--version`, one file or stdin, streaming file encode/decode, and binary stdout; unit evidence is in `MSPDataAndTextCommandTests` and `MSPDataComparisonMetadataOracleTests`; Core100 oracle has 6 `base64` cases covering encode, decode, wrap-zero, ignore-garbage, invalid decode, and file; vendored source is `coreutils-9.1/src/basenc.c`.
  - **Implementation closure decision**: Coordinator action covers exact huge-wrap overflow handling, exact invalid-byte/truncated-input diagnostics, repeated `-` semantics, and output-limit/streaming stdout.
  - **Oracle/stress closure plan**: Add all 256 byte values, multiline encoded input, invalid padding matrix, no-wrap huge output, file/stdin diagnostic parity, repeated stdin, and stdout cap behavior.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## basenc
- **Command**: `basenc`
- **MSP implementation**: `MSPBasencCommand` facade in `Commands/Data/MSPBase32BasencCommands.swift:19-31`; shared parser/codec owners under `Commands/Data/BaseEncoding/`, including `BaseEncodingCommandRunner.swift`, `BaseEncodingOptions.swift`, `BaseEncodingKind.swift`, `BaseEncodingStreaming.swift`, `BaseEncodingDecoding.swift`, `BaseEncodingBase32.swift`, `BaseEncodingInput.swift`, and `BaseEncodingHelp.swift`.
- **Reference source**: `coreutils-9.1/src/basenc.c`, `long_options` and `main` cases for `--base64`, `--base64url`, `--base32`, `--base32hex`, `--base16`, `--base2msbf`, `--base2lsbf`, and `--z85`.
- **GNU/Linux parameter surface**: `[OPTION]... [FILE]`; encoding selector required for `basenc`; selectors `--base64`, `--base64url`, `--base32`, `--base32hex`, `--base16`, `--base2msbf`, `--base2lsbf`, `--z85`; `-d`, `-i`, `-w COLS`, help/version.
- **Currently supported by MSP**: All listed selectors except `--z85`; `-d`, `-i`, `-w`; `--help`; `--version`; no operand or one FILE/`-`; missing selector is diagnosed.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None. `--z85` is in coreutils 9.1 `basenc.c`, so it is coordinator-tracked, coordinator-tracked.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: Same runner as base32: file input chunked, stdin and output accumulated. O(n) time, O(output) memory until streaming output is added.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because `basenc` advertises multiple encodings and the current proof still misses source-backed `--z85`, full binary corpora, and selector-conflict behavior.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPBasencCommand` supports the shared `BaseEncoding` runner, `--base64`, `--base64url`, `--base32`, `--base32hex`, `--base16`, `--base2msbf`, `--base2lsbf`, `-d`, `-i`, `-w`, `--help`, and `--version`; unit evidence covers base64url/base16/base2msbf, `--version`, chunked base32 file operands through the shared runner, base32hex encode/decode, base2lsbf encode/decode, base64url decode, and missing-selector diagnostics in `MSPWorkerFIdentityEncodingDigestTests`; Core100 oracle has 14 `basenc` cases; vendored source is `coreutils-9.1/src/basenc.c`.
  - **Implementation closure decision**: Coordinator action covers `--z85`, exact selector-conflict and extra-operand diagnostics, complete invalid alphabet/padding parity, output limiting, and large streaming stdout.
  - **Oracle/stress closure plan**: Add `--z85`, `--base32hex`, `--base2lsbf`, multi-selector conflict, huge binary encode/decode, no-wrap output caps, and full byte corpus.
  - **Deferred/forbidden with reason**: `--z85` is source-backed in coreutils 9.1 and is coordinator-tracked item, coordinator-tracked. Host-path reads outside WorkspaceFS are forbidden.

## bc
- **Command**: `bc`
- **MSP implementation**: `Commands/Numeric/MSPBcCommand.swift:4-250`; arithmetic helper `MSPPOSIXArithmeticExpressionParser.swift`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/bc-1.07.1/bc/main.c:50-160` for `long_options`, `usage`, `parse_args`, FILE operand collection; `main.c:179-219` for `BC_ENV_ARGS`, `POSIXLY_CORRECT`, and `BC_LINE_LENGTH`; `main.c:271-330` for mathlib-before-first-file and stdin-after-files ordering; `References/LinuxSourceSnapshot/debian12-bookworm/sources/bc-1.07.1/bc/bc.y:121-793` for the command language grammar.
- **GNU/Linux parameter surface**: `[options] [file ...]`; options are `-c/--compile`, `-h/--help`, `-i/--interactive`, `-l/--mathlib`, `-q/--quiet`, `-s/--standard`, `-w/--warn`, `-v/--version`; environment options from space-split `BC_ENV_ARGS`; POSIX mode from `POSIXLY_CORRECT`; output line wrapping from `BC_LINE_LENGTH`; FILE operands are read in order, `-l` preloads the math library before the first input, then stdin is read after files. The grammar covers arbitrary precision numbers; `ibase`, `obase`, `scale`, `last`, `history`; variables and arrays; assignment and compound assignment; `++/--`; arithmetic, power, relational, `&&`, `||`, `!`; `length`, `sqrt`, `scale`, `read`, `random`; functions with parameters, arrays, `auto`, `return`, and `void`; statements `if/else`, `while`, `for`, `break`, `continue`, blocks, `print`, strings, `quit`, `halt`, `warranty`, and `limits`.
- **Currently supported by MSP**: `-h/--help` and `-v/--version` are special-cased; `-l/--mathlib` is accepted but does not load GNU math routines; FILE/stdin data is concatenated; streaming mode handles stdin line by line only when there are no operands; supported language is limited to semicolon-separated arithmetic expressions routed through the shell arithmetic parser plus narrow `scale=N`, `ibase`, and `obase` handling. No real `bc` variables, arrays, functions, control flow, strings, print, diagnostics recovery, or arbitrary precision decimal runtime are present.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: Readline/libedit history can be deferred until MSP exposes PTY-style interactive sessions, because it is terminal integration rather than batch command semantics. The `bc` language itself is coordinator-tracked.
- **Forbidden by policy**: Reading script files outside WorkspaceFS; inheriting host `BC_ENV_ARGS` unexpectedly; shelling out to host `/usr/bin/bc`; unbounded CPU or memory from attacker-controlled huge numbers, exponentiation, loops, recursion, or output amplification.
- **Performance model**: GNU `bc` is streaming over source files but can run arbitrarily long programs; numeric operations are at least O(digits) and multiplication/division/exponentiation can grow superlinear with operand size and requested `scale`. Current MSP is O(input) for parsing simple lines and O(digits) only within native `Int`, but it is semantically tiny. A conforming MSP needs big-number budgets, loop/function recursion limits, cancellation checks in evaluator hot paths, and stdout caps for large `print`/base-conversion output.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because the Swift command is a small integer calculator while Debian `bc` is a programmable arbitrary precision language.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPBcCommand` has batch and streaming paths for simple expressions, `scale`, limited base state, file input, syntax diagnostics, `-h/--help`, and `-v/--version`; unit evidence is in `MSPWorkerFMiscProcessNumericSearchTests`; Core100 oracle has 5 `bc` cases covering arithmetic, scale, ibase/obase, expression file, and syntax error; vendored source is `bc-1.07.1/bc/main.c` and `bc/bc.y`.
  - **Implementation closure decision**: Coordinator action covers remaining option/env handling, GNU mathlib, arbitrary precision decimal runtime, complete `bc.y` language, variables/arrays/functions/control flow/strings/print, file plus stdin ordering, exact diagnostics/line numbers, compile-only mode, output wrapping, and resource budgets.
  - **Oracle/stress closure plan**: Add mathlib, bases, decimal scale, variables, arrays, functions, loops, `print`, strings, `BC_ENV_ARGS`, POSIX/warn modes, compile-only, divide-by-zero, syntax recovery, huge-number, recursion, and runaway-loop cases.
  - **Deferred/forbidden with reason**: Readline/history is deferred until PTY-style interactivity exists. The `bc` language and common options are coordinator-tracked. Reading script files outside WorkspaceFS, inheriting host env unexpectedly, shelling to host `bc`, and unbounded CPU/memory are forbidden.

## cksum
- **Command**: `cksum`
- **MSP implementation**: `Commands/Data/MSPChecksumCommands.swift:5-39` plus POSIX CRC helpers in the same file.
- **Reference source**: `coreutils-9.1/src/digest.c` modern `cksum` parser (`--algorithm`, `--length`, `--check`, `--tag`, `--untagged`, `--zero`, check modifiers); `coreutils-9.1/src/cksum.c` and `cksum.h` for POSIX CRC implementation.
- **GNU/Linux parameter surface**: FILE operands and stdin; default CRC output; `-a/--algorithm=bsd|sysv|crc|md5|sha1|sha224|sha256|sha384|sha512|blake2b|sm3`; `-l/--length=BITS` for BLAKE2b; `-c/--check` where supported; `--tag`, `--untagged`, `--zero`, `--debug`; check modifiers `--ignore-missing`, `--quiet`, `--status`, `--strict`, `-w/--warn`; help/version.
- **Currently supported by MSP**: Default POSIX CRC and byte count for stdin, `-`, and multiple files; file path mode is chunked; `--zero` delimiter for CRC/sum/digest output; `--algorithm=bsd|sysv|crc|md5|sha1|sha224|sha256|sha384|sha512|blake2b|sm3`; `--length` for BLAKE2b; digest algorithms default to tagged output and support `--untagged`; digest check mode supports GNU check modifiers and tagged check parsing; `--algorithm={bsd,sysv,crc} -c` is rejected like GNU; `--help`; `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None for common options. Hardware acceleration debug detail can be a virtualized diagnostic if iOS lacks matching CPU feature detection.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: Current file CRC is streaming O(n), stdin is eager. Multi-algorithm mode must keep streaming and avoid whole-file reads for digest algorithms.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because fixture status says implemented while GNU `cksum` is now a broad digest frontend.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPCksumCommand` implements POSIX CRC rows for stdin/file/multiple operands; it now follows `coreutils-9.1/src/digest.c` for `--algorithm`, BLAKE2b `--length`, default tagged digest output, `--untagged`, `--zero`, digest `--check`, `--warn`, `--strict`, `--quiet`, `--status`, `--ignore-missing`, `--help`, `--version`, and the GNU rejection of checking `bsd/sysv/crc`; it follows `src/cksum.c`/`cksum.h` for CRC output. Unit evidence is `MSPWorkerFIdentityEncodingDigestTests.testCksumModernDigestFrontendMatchesGNUOracleSamples`; shell-facade evidence is edge fixture `cksum-modern-digest-frontend-options`; Core100 oracle still has the 5 baseline `cksum` cases.
  - **Implementation closure decision**: Coordinator action covers exact invalid argument/help text, exact `--debug` hardware diagnostic policy, repeated-stdin behavior, broader escaped/binary filename parity, chunked stdin/check parsing, and unsupported `-b/-t/--text/--binary` diagnostics.
  - **Oracle/stress closure plan**: Add algorithm matrix over stdin/multiple files, escaped/binary paths, huge streamed files, repeated `-`, malformed check matrices beyond MD5 samples, invalid options, length-boundary failures, and debug/virtualized debug behavior.
  - **Deferred/forbidden with reason**: No common option is deferred. Hardware acceleration `--debug` details may be virtualized on non-Linux/iOS. Host-path reads outside WorkspaceFS are forbidden.

## cmp
- **Command**: `cmp`
- **MSP implementation**: `Commands/Comparison/MSPCmpCommand.swift:4-258`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/diffutils-3.8/src/cmp.c:99-111` for `long_options`; `cmp.c:123-150` for suffix-backed skip parsing and `-l`/`-s` incompatibility; `cmp.c:161-198` for usage text; `cmp.c:200-370` for operand defaulting and option handling; `cmp.c:377-611` for the chunked byte comparison loop, `-n`, `-l`, `-b`, and EOF diagnostics.
- **GNU/Linux parameter surface**: `cmp [OPTION]... FILE1 [FILE2 [SKIP1 [SKIP2]]]`; if FILE2 is omitted it is stdin, and `-` means stdin. Options are `-b/--print-bytes`, obsolescent `-c/--print-chars`, `-i/--ignore-initial=SKIP` or `SKIP1:SKIP2`, `-l/--verbose`, `-n/--bytes=LIMIT`, `-s/--quiet/--silent`, `--help`, `-v/--version`. SKIP/LIMIT parse base-0 integers with suffixes from `valid_suffixes` (`kB`, `K`, `MB`, `M`, `GB`, `G`, continuing through `T/P/E/Z/Y`, plus `0`). Multiple `-i`/skip operands keep the maximum per side; multiple `-n` keeps the largest limit. `-l` and `-s` are incompatible. Output modes are first-difference, all-differences octal table, status-only, and print-bytes variants with `cat -t` style byte names.
- **Currently supported by MSP**: One or two operands plus optional trailing `SKIP1 SKIP2`; omitted FILE2 defaults to stdin, and `-` means stdin. Accepted options are `-s/--silent/--quiet`, `-l/--verbose`, `-n/--bytes`, `-i/--ignore-initial`, `--help`, and `--version`; `-l`/`-s` is rejected as incompatible. File/file comparison is chunked for default/silent and eager for verbose; stdin operands are eager `Data`; repeated `-` treats the second stdin as empty. Default output approximates first mismatch/EOF messages but not locale/POSIX `char` wording, `-b`, read-error behavior, or same-file/offset shortcuts.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: Reference `cmp` is O(min(n, LIMIT)) time with bounded buffers and O(1) comparison memory; skip uses `lseek` when possible or read-and-discard fallback. MSP file/file keeps the O(n) chunked path, but stdin paths are O(n) memory. `-l` is still O(n) scan time but can emit O(number_of_differences) lines, so output limiting and cancellation are mandatory for large binary files.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because skip/limit/byte-print controls are core `cmp` behavior and currently absent, while verbose output can amplify on large binaries.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPCmpCommand` implements two-file comparison, omitted FILE2 as stdin, trailing `SKIP1 SKIP2`, `-i/--ignore-initial`, `-n/--bytes`, `-s/--quiet`, `-l/--verbose`, `--help`, `--version`, `-l`/`-s` conflict rejection, chunked file/file default and silent paths, stdin operands, EOF diagnostics, and missing-file errors; unit evidence is in `MSPDataAndTextCommandTests` and `MSPDataComparisonMetadataOracleTests` including omitted-FILE2 stdin, conflict, skip, ignore-initial, and byte-limit cases; Core100 oracle has 5 `cmp` cases plus `stress-s2-cmp-large-early-mismatch`; vendored source is `diffutils-3.8/src/cmp.c`.
  - **Implementation closure decision**: Coordinator action covers `-b/-c`, complete suffix family beyond K/M/G and kB/MB/GB, same-file shortcuts, exact diagnostics, output caps, and streaming stdin comparison.
  - **Oracle/stress closure plan**: Add VPS oracle for omitted FILE2, all `-` combinations, skip/limit suffix matrix, byte-print modes, incompatible options, same-path/offset cases, huge verbose output, and exact GNU stderr/stdout captures.
  - **Deferred/forbidden with reason**: None for common diffutils options. Host-path reads outside WorkspaceFS are forbidden.

## date
- **Command**: `date`
- **MSP implementation**: `Commands/Utility/MSPDateCommand.swift:4-387`.
- **Reference source**: `coreutils-9.1/src/date.c`, `long_options`, `usage`, and `main`; uses GNU `parse_datetime` and locale/timezone formatting.
- **GNU/Linux parameter surface**: `+FORMAT`; display current or described time; `-d/--date=STRING`, `-f/--file=DATEFILE`, `-I[=FMT]/--iso-8601[=FMT]`, `--resolution`, `-R/--rfc-email` plus old aliases, `--rfc-3339=FMT`, `-r/--reference=FILE`, `-s/--set=STRING`, `-u/--utc/--universal/--uct`, POSIX set-time operand, help/version, many `strftime` directives and GNU date grammar.
- **Currently supported by MSP**: `-u/--utc`, `-d/--date` for `@SECONDS` and a few fixed ISO-like formats, `-I`/`--iso-8601`, `--rfc-3339`, `--help`, `--version`, one `+FORMAT` operand, fixed en_US_POSIX formatting subset, current `Date()`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: Actual host clock mutation for `-s` and POSIX set-time operand must not be implemented; a non-mutating diagnostic or virtualized rejection is allowed instead.
- **Forbidden by policy**: Setting system date/time; reading reference files outside WorkspaceFS; exposing host timezone database paths directly.
- **Performance model**: O(1) for single format, O(lines) for `-f`; date parsing must be deterministic under explicit TZ/locale. Current current-time output is nondeterministic unless tests pin `-d`.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because time parsing/formatting is broad, nondeterministic, and currently much narrower than GNU.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPDateCommand` implements `-u/--utc`, limited `-d/--date`, `-I/--iso-8601`, `--rfc-3339`, `--help`, `--version`, one `+FORMAT`, and a fixed POSIX locale subset; unit evidence is in `MSPWorkerFMiscProcessNumericSearchTests`; direct fixture covers stable epoch/format cases; Core100 oracle has 5 `date` cases; vendored source is `coreutils-9.1/src/date.c`.
  - **Implementation closure decision**: Coordinator action covers GNU `parse_datetime`, `-f`, `-r`, `-R`, `--resolution`, broader `strftime` modifiers/directives, deterministic oracle clock injection for current time, fractional precision, timezone/DST handling, and set-time rejection diagnostics.
  - **Oracle/stress closure plan**: Add relative/natural dates, timezone strings, DST boundaries, `-f`, `-r`, RFC email, resolution, padding/case modifiers, locale isolation, nanosecond cases, current-time stabilization, and `-s`/POSIX set-time rejection.
  - **Deferred/forbidden with reason**: Actual host clock mutation via `-s` or POSIX set-time operand is forbidden. WorkspaceFS-safe `-r` is coordinator-tracked item, coordinator-tracked.

## dd
- **Command**: `dd`
- **MSP implementation**: `Commands/Data/MSPDdCommand.swift` plus `Commands/Data/Dd/` owner files for options/help, input adapters, output adapters, and copy engine; WorkspaceFS boundary in `MSPWorkspace.swift:8-52`, `MSPAppleWorkspace.swift:45-64`, `183-241`, and containment checks at `1213-1295`.
- **Reference source**: `coreutils-9.1/src/dd.c`, conversion/flag/status tables, `usage`, `parse_integer`, `scanargs`, `skip`, and copy loop.
- **GNU/Linux parameter surface**: Operand form only: `if=`, `of=`, `ibs=`, `obs=`, `bs=`, `cbs=`, `count=`, `skip=`/`iseek=`, `seek=`/`oseek=`, `conv=ascii,ebcdic,ibm,block,unblock,lcase,ucase,sparse,swab,noerror,nocreat,excl,notrunc,sync,fdatasync,fsync`, `iflag=`/`oflag=` flags including `append,binary,cio,direct,directory,dsync,noatime,nocache,noctty,nofollow,nolinks,nonblock,sync,text,fullblock,count_bytes,skip_bytes,seek_bytes`, `status=none|noxfer|progress`, GNU byte suffixes and trailing `B` byte-count semantics, help/version.
- **Currently supported by MSP**: `if`, `of`, `ibs`, `obs`, `bs`, `count`, `skip`/`iseek`, `seek`/`oseek`; `conv=notrunc,sync,swab`; `iflag=fullblock`; `oflag=append`; `status=none|noxfer|default`; `--help`; `--version`; stdin/stdout streaming when available; workspace file input/output.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: Direct I/O/cache flags such as `direct`, `nocache`, `noatime`, `cio`, `dsync`, and `sync` may be virtualized or deferred because iOS/WorkspaceFS cannot expose Linux file descriptor semantics safely. `fdatasync/fsync` can be no-op only if documented and oracle-tested.
- **Forbidden by policy**: Real `/dev/*` device paths, raw block/char devices, host absolute paths outside WorkspaceFS, reads from host random/time devices, and writes to system paths. If `/dev/null` or `/dev/zero` are ever desired, they must be explicit virtual devices with output caps, not host passthrough.
- **Performance model**: Copy loop is chunked, but file output uses append operations and `seek` currently writes real zero bytes. Large `seek`, `count`, or stdout output can explode disk/memory; sparse output must track holes virtually or cap output size. Cancellation must be checked inside long copy loops.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because `dd` combines byte parity, side effects, output amplification, and device-path safety.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPDdCommand` is now a thin command entrypoint and delegates operand parsing/help to `Dd/MSPDdOptions.swift`, stdin/file input to `Dd/MSPDdInput.swift`, buffer/stream/file/notrunc output to `Dd/MSPDdOutput.swift`, and block copying/swab/status accounting to `Dd/MSPDdCopyEngine.swift`. It implements core operand parsing, stdin/stdout streams, WorkspaceFS file I/O, `if/of`, block sizes, `count`, `skip/iseek`, `seek/oseek`, `conv=notrunc,sync,swab`, `iflag=fullblock`, `oflag=append`, status modes, `--help`, and `--version`; unit evidence is in `MSPWorkerDByteStreamCommandTests`; Core100 oracle has 20 `dd` cases plus `stress-s2-dd-limited-copy`; vendored source is `coreutils-9.1/src/dd.c`.
  - **Implementation closure decision**: Coordinator action covers GNU suffix/trailing-B parsing, byte-oriented count/skip/seek flags, `cbs`, block/unblock/case/EBCDIC conversions, sparse/noerror/nocreat/excl/fsync/fdatasync, additional iflag/oflag semantics, progress status, exact stats, huge seek/output caps, and side-effect rollback.
  - **Oracle/stress closure plan**: Add suffix matrix, sparse holes, huge bounded seek/skip/count, partial reads, device/symlink rejection, every conversion/flag family, progress timing normalization, append/notrunc edge cases, output caps, and WorkspaceFS escape attempts.
  - **Deferred/forbidden with reason**: Linux descriptor/cache/direct-I/O flags may be virtualized or deferred where WorkspaceFS/iOS cannot expose them safely. Device paths, host paths outside WorkspaceFS, unbounded sparse growth, and unsafe symlink escapes are forbidden.

## diff
- **Command**: `diff`
- **MSP implementation**: `Commands/Comparison/MSPDiffCommand.swift:4-344`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/diffutils-3.8/src/diff.c:109-230` for short/long option tables; `diff.c:272-812` for option handling, style conflicts, algorithm flags, `--from-file`/`--to-file`, and operand arity; `diff.c:892-989` for help surface; `diff.c:1086-1478` for file/directory/stdin/symlink comparison routing. Output and edit-script rendering continue through diffutils helpers called by `diff_2_files`.
- **GNU/Linux parameter surface**: Operands are `FILE1 FILE2`, `DIR1 DIR2`, `DIR FILE`, `FILE DIR`, stdin `-`, or one-to-many `--from-file=FILE1`/`--to-file=FILE2`. Output/status formats include `--normal`, `-q/--brief`, `-s/--report-identical-files`, `-c/-C NUM/--context[=NUM]`, `-u/-U NUM/--unified[=NUM]`, `-e/--ed`, `-f/--forward-ed`, `-n/--rcs`, `-y/--side-by-side`, `-W/--width`, `--left-column`, `--suppress-common-lines`, `-D/--ifdef`, `--line-format`, `--old/new/unchanged-line-format`, and `--old/new/unchanged/changed-group-format`. Hunk context/function metadata includes `-p`, `-F RE`, `--label` twice, tab/layout options `-t`, `-T`, `--tabsize`, `--suppress-blank-empty`, and `-l/--paginate`. Directory/file traversal includes `-r`, `--no-dereference`, `-N`, `-P`, file-name case toggles, `-x`, `-X`, `-S`, from/to-file. Content normalization includes `-i`, `-E`, `-Z`, `-b`, `-w`, `-B`, `-I RE`, `-a/--text`, `--strip-trailing-cr`, and `--binary`. Algorithm/performance knobs include `-d/--minimal`, `-h` accepted as no-op, `--horizon-lines=NUM`, and `-H/--speed-large-files`; color includes `--color[=WHEN]` and `--palette`; help/version are source-backed.
- **Currently supported by MSP**: Exactly two operands; no directories, from/to-file, labels, ignore rules, text/binary controls, or alternate formats beyond normal and a simplified unified mode. Accepted options are `-u/--unified`, `-U NUM` as a unified toggle without honoring NUM, `-q/--brief`, `-s/--report-identical-files`, `--help`, and `-v/--version`. File/file `-q` streams chunks O(n); all non-brief paths materialize both files, detect binary by NUL, decode UTF-8 only, and build a full LCS table.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: `-l/--paginate` can be deferred or virtualized because it shells through `pr`/terminal pagination. Color and palette may be deferred until MSP defines terminal color policy. Core algorithms, formats, ignore modes, and directory traversal are not deferrable.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS and following symlinks outside the workspace.
- **Performance model**: Directory comparison is O(entries + compared bytes) but can recursively traverse large WorkspaceFS trees and produce unbounded output. File `-q` can be O(n) streaming. Current MSP non-brief diff is eager O(bytes1 + bytes2) memory before text decoding plus O(lines1 * lines2) time and memory for the LCS table, which is unsafe for large files or many repeated lines. A conforming implementation needs a bounded Myers-style algorithm, binary fast paths, cancellation in directory/file loops, and stdout caps for pathological hunks.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because the present implementation misses most source-backed formats and directory semantics while using an O(lines1 * lines2) algorithm for normal use.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPDiffCommand` supports exactly two operands, normal diff, simplified unified diff, `-U` as a toggle, `-q/--brief`, `-s/--report-identical-files`, `--help`, `-v/--version`, binary-NUL detection, stdin operands, metadata timestamps, and a chunked `-q` path; unit evidence is in `MSPDataAndTextCommandTests` and `MSPDataComparisonMetadataOracleTests`; Core100 oracle has 5 `diff` cases plus `stress-s2-diff-large-early-mismatch`; vendored source is `diffutils-3.8/src/diff.c` and related diffutils sources.
  - **Implementation closure decision**: Coordinator action covers correct GNU/Myers hunking, exact `-U/--unified=NUM`, context/ed/forward-ed/RCS/side-by-side/ifdef/custom formats, no-newline markers, labels, ignore modes, directory/recursive comparison, `-N/-P`, exclude/from/to-file, symlink rules, bounded algorithm/output, and exact diagnostics.
  - **Oracle/stress closure plan**: Add nontrivial hunks, context count variants, no-newline markers, all formats, ignore/label/binary/text flags, directories/recursion, exclude files, stdin combinations, repeated-line stress, symlink policy, and exact diffutils output captures.
  - **Deferred/forbidden with reason**: `-l/--paginate` can remain deferred or virtualized because it shells through `pr`; color/palette can wait for terminal color policy. Core diff algorithms, formats, ignore modes, and directory semantics are coordinator-tracked. Host-path reads outside WorkspaceFS are forbidden.

## expr
- **Command**: `expr`
- **MSP implementation**: `Commands/Numeric/MSPExprCommand.swift:4-327`.
- **Reference source**: `coreutils-9.1/src/expr.c`, `usage`, `eval*` precedence functions, multibyte helpers, regex `docolon`, and `mpz` arithmetic paths.
- **GNU/Linux parameter surface**: `expr EXPRESSION`; operators `|`, `&`, comparisons, `+`, `-`, `*`, `/`, `%`, `STRING : REGEXP`; keywords `match`, `substr`, `index`, `length`; `+ TOKEN`; parentheses; help/version; locale-aware string comparison and multibyte lengths; arbitrary precision integers.
- **Currently supported by MSP**: Main expression grammar, keywords, regex match with Foundation regex conversion, Int64 arithmetic, exit 1 for null/zero, diagnostics for syntax/non-integer/division by zero, `--help`, and `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: None beyond generic command runtime limits.
- **Performance model**: O(tokens) parser, regex depends on pattern engine. Huge integers and catastrophic regex patterns need limits and cancellation. Current Int64 can trap/diverge on overflow cases.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: medium, because the surface is moderate but numeric/regex parity is not yet trustworthy.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPExprCommand` implements the main grammar, keywords, comparisons, arithmetic, null/zero status, Foundation-backed regex conversion, `--help`, and `--version`; unit evidence is in `MSPTextLayoutCommandTests`, `MSPWorkerFMiscProcessNumericSearchTests`, and direct fixtures; Core100 oracle has 16 `expr` cases; vendored source is `coreutils-9.1/src/expr.c`.
  - **Implementation closure decision**: Coordinator action covers GMP-style arbitrary precision, overflow parity, POSIX BRE exactness, multibyte/locale behavior, exact diagnostics, shell-quoting edge cases, and cancellation for expensive regex/large arithmetic.
  - **Oracle/stress closure plan**: Add capture-group regex parity, BRE metacharacter matrix, multibyte lengths, huge integers, overflow/division edge cases, locale collation, syntax/error matrix, false/null status, option-like operands, and keyword quoting.
  - **Deferred/forbidden with reason**: None for common GNU options; only generic CPU/memory limits apply.

## factor
- **Command**: `factor`
- **MSP implementation**: `Commands/Numeric/MSPFactorCommand.swift:4-68`.
- **Reference source**: `coreutils-9.1/src/factor.c`, option table, `do_stdin`, `print_factors`, GMP-backed multi-precision factorization, Miller-Rabin/Lucas/Pollard-rho/SQUFOF paths.
- **GNU/Linux parameter surface**: `[NUMBER]...` or stdin tokens; help/version; arbitrary-size integers through GMP; internal `--debug` developer option in source.
- **Currently supported by MSP**: Operands or whitespace tokens from stdin; UInt64 parsing only; simple trial division; invalid token diagnostics; `--help`; `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: Developer `--debug` can remain deferred unless oracle requires it, because it is not normal user-facing compatibility.
- **Forbidden by policy**: None beyond CPU/time limits.
- **Performance model**: Current trial division is O(sqrt(n)) and can hang on large 64-bit primes; GNU uses probabilistic and advanced methods. Add timeouts/cancellation and avoid unbounded CPU.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because current implementation is algorithmically unsuitable for common large inputs.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPFactorCommand` handles operands and stdin tokens with UInt64 trial division, invalid token diagnostics, `--help`, and `--version`; direct fixture covers small numbers; unit evidence is in `MSPCore100ExtraCommandTests`; Core100 oracle has 3 `factor` cases; vendored source is `coreutils-9.1/src/factor.c`.
  - **Implementation closure decision**: Coordinator action covers arbitrary precision input, fast factorization for large primes/semiprimes, exact invalid diagnostics, tokenization parity, and cancellation/time budgets.
  - **Oracle/stress closure plan**: Add large 64-bit primes, 128-bit/big integers, semiprimes, invalid signs/decimals, mixed stdin streams, huge token counts, and timeout/cancellation cases.
  - **Deferred/forbidden with reason**: Source developer `--debug` can remain deferred unless oracle proves it user-facing. Common factoring behavior is coordinator-tracked.

## md5sum
- **Command**: `md5sum`
- **MSP implementation**: Registered via `MSPDigestCommand(name: "md5sum", algorithm: .md5)` at `Registry/MSPPOSIXCoreCommandPack.swift:40`; implementation in `Commands/Data/MSPChecksumCommands.swift:41-179`, `392-468`.
- **Reference source**: `coreutils-9.1/src/digest.c`, `long_options`, `usage`, `split_3`, check parser, and `main`.
- **GNU/Linux parameter surface**: FILE operands and stdin; `-b/--binary`, `-t/--text`, `-c/--check`, `--tag`, `--zero`; check-only `--ignore-missing`, `--quiet`, `--status`, `--strict`, `-w/--warn`; help/version.
- **Currently supported by MSP**: FILE/stdin/`-`; multi-file output; `-b`, `-t`; `-c/--check`; `--status`; lowercase hex output through CryptoKit MD5; `--tag`; `--zero`; `--warn`, `--strict`, `--quiet`, `--ignore-missing`; tagged check parsing; newline/backslash/CR filename escaping; `--help`; `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File hashing is chunked; stdin and check files are eager. Check mode can read many listed files and needs cancellation and output caps.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because check mode is easy to overtrust and currently lacks GNU's safety modifiers.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPDigestCommand` implements MD5 rows, stdin/file/multiple operands, `-b/-t`, `-c/--check`, `--status`, `--tag`, `--zero`, tagged check parsing, malformed/missing summaries, check modifiers, newline/backslash/CR filename escaping, chunked file hashing, `--help`, and `--version`; unit evidence is in `MSPDataAndTextCommandTests`, `MSPDataComparisonMetadataOracleTests`, and `MSPWorkerFIdentityEncodingDigestTests.testDigestSharedGNUCheckAndTaggedOutputOptions`; Core100 oracle has 5 baseline `md5sum` cases; vendored source is `coreutils-9.1/src/digest.c`.
  - **Implementation closure decision**: Coordinator action covers repeated-stdin behavior, streaming check parsing, exact unsupported-combination diagnostics, and full binary/escaped filename byte parity.
  - **Oracle/stress closure plan**: Add broader escaped/binary name cases, huge files/check files, repeated `-`, unsupported option combinations, and binary filename byte parity.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## numfmt
- **Command**: `numfmt`
- **MSP implementation**: `Commands/Numeric/MSPNumfmtCommand.swift:4-234`.
- **Reference source**: `coreutils-9.1/src/numfmt.c`, `usage`, long option parser, scaling/unit/format/invalid handling.
- **GNU/Linux parameter surface**: `[OPTION]... [NUMBER]...`; `-d/--delimiter`, `--field=FIELDS`, `--format=FORMAT`, `--from=UNIT`, `--from-unit=N`, `--grouping`, `--header[=N]`, `--invalid=abort|fail|warn|ignore`, `--padding=N`, `--round=up|down|from-zero|towards-zero|nearest`, `--suffix=SUFFIX`, `--to=UNIT`, `--to-unit=N`, `-z/--zero-terminated`, `--debug`, help/version; locale decimal/grouping.
- **Currently supported by MSP**: Long `--field`, `--from`, `--to`, `--suffix`, `--padding`, `--help`, and `--version`; stdin or command-line NUMBERs as lines; basic whitespace fields; `--from=si|iec|iec-i|auto|none`; `--to=si|iec|iec-i|none`; Double parsing and rounded integer fallback; streaming stdin path for records.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: Locale grouping beyond C/POSIX may be deferred only if MSP policy pins locale; otherwise it is debt.
- **Forbidden by policy**: None beyond generic resource limits.
- **Performance model**: Streaming path processes line by line, but non-streaming path eagerly reads stdin. Numeric conversion uses Double, so precision and huge values diverge from GNU decimal handling.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because current behavior is a tiny subset of a formatting-heavy command.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPNumfmtCommand` is streaming-capable for stdin and supports basic field selection, from/to unit conversion, suffix, padding, invalid-number failure, `--help`, and `--version`; unit evidence is in `MSPWorkerFMiscProcessNumericSearchTests` and `MSPDataAndTextCommandTests`; Core100 oracle has 5 `numfmt` cases; vendored source is `coreutils-9.1/src/numfmt.c`.
  - **Implementation closure decision**: Coordinator action covers full field lists/ranges, delimiter, zero-terminated records, `--format`, grouping/locale, headers, invalid modes, all rounding modes, `--from-unit`, `--to-unit`, `--debug`, decimal precision parity, exact diagnostics, argument-number edge cases, and output caps.
  - **Oracle/stress closure plan**: Add every option family above, invalid modes, locale/rounding/precision matrix, zero delimiters, headers, field ranges, suffix parsing, huge numbers, streaming backpressure, and argument-number behavior.
  - **Deferred/forbidden with reason**: Locale grouping can be deferred only if MSP explicitly pins locale; otherwise it is coordinator-tracked item. No common GNU option is otherwise deferred.

## od
- **Command**: `od`
- **MSP implementation**: `Commands/Data/MSPOdCommand.swift` plus `Commands/Data/Od/` owner files for option/config parsing, input/range loading, format models, and renderer/output formatting.
- **Reference source**: `coreutils-9.1/src/od.c`, `long_options`, `usage`, format decoding, traditional operand parser, and main option loop.
- **GNU/Linux parameter surface**: Modern `[OPTION]... [FILE]...`; traditional offset/label forms; `-A/--address-radix`, `--endian`, `-j/--skip-bytes`, `-N/--read-bytes`, `-S/--strings[=BYTES]`, `-t/--format=TYPE`, `-v`, `-w[BYTES]/--width[=BYTES]`, `--traditional`, old format options `-a -b -c -d -D -f -F -h -i -I -l -L -o -O -s -x -X -B`; integer, float, char, named-char formats and suffix parsing.
- **Currently supported by MSP**: Many integer/char old options; `-A`, `-j`, `-N`, `-t` for `d/o/u/x/a/c` integer and char formats only, `-v`, `-w`, `--endian`, `--traditional` as a no-op, `--help`, and `--version`; multiple inputs are concatenated eagerly except one-file range shortcut.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None for documented options. Some obsolete aliases are still in GNU source and should be handled unless proven absent from Debian help.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: Current run often combines all inputs into memory and builds all output lines before returning. O(n) time but O(input + output) memory; large dumps need streaming, cancellation, and output caps.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: medium, because small hex/octal cases work but format surface and memory behavior are incomplete.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPOdCommand` is now a thin facade over `Commands/Data/Od/` owners for configuration, format models, input/range loading, and renderer output. Together they support many integer/char format options, `-A`, `-j`, `-N`, `-t`, `-v`, `-w`, `--endian`, `--help`, `--version`, duplicate suppression, range reads for some one-file cases, and diagnostics; unit evidence is in `MSPDataAndTextCommandTests` and `MSPDataComparisonMetadataOracleTests`; Core100 oracle has 5 primary `od` cases plus several helper/stress cases; vendored source is `coreutils-9.1/src/od.c`.
  - **Implementation closure decision**: Coordinator action covers float formats, `-S/--strings`, true traditional offset/label parsing, full suffix/overflow parser, exact field widths/spacing, multi-file streaming across skip/read boundaries, and memory/output caps.
  - **Oracle/stress closure plan**: Add floats, strings mode, traditional offsets/labels, huge binary dumps, multi-file boundary skips, endian multi-byte values, suffix overflow, no-address spacing, helper-command byte parity, and exact GNU formatting captures.
  - **Deferred/forbidden with reason**: No documented GNU option is deferred. Host-path reads outside WorkspaceFS are forbidden.

## sha1sum
- **Command**: `sha1sum`
- **MSP implementation**: Registered at `Registry/MSPPOSIXCoreCommandPack.swift:75`; shared `MSPDigestCommand` in `Commands/Data/MSPChecksumCommands.swift:41-179`, SHA1 branch at `443-448`.
- **Reference source**: `coreutils-9.1/src/digest.c`, shared checksum parser, verifier, output renderer, and main.
- **GNU/Linux parameter surface**: Same digest surface as `md5sum`: FILE/stdin, `-b`, `-t`, `-c`, `--tag`, `--zero`, `--ignore-missing`, `--quiet`, `--status`, `--strict`, `-w`, help/version.
- **Currently supported by MSP**: FILE/stdin/`-`, multi-file output, `-b`, `-t`, `-c`, `--status`, tagged/NUL output, check modifiers, tagged check parsing, newline/backslash/CR filename escaping, `--help`, and `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File hashing chunked; stdin/check files eager. O(n), but check mode is unbounded over listed files without cancellation/output caps.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because the shared digest verifier gaps apply here too.
- **Closure status**:
  - **Implemented evidence**: Swift registers `sha1sum` through `MSPDigestCommand` and supports stdin/file/multiple rows, `-b/-t`, `-c`, `--status`, `--tag`, `--zero`, check modifiers, tagged check parsing, newline/backslash/CR filename escaping, chunked file hashing, `--help`, and `--version`; unit evidence includes basic rows in `MSPDataAndTextCommandTests`, `MSPDataComparisonMetadataOracleTests`, and the shared digest option test; Core100 oracle has 5 baseline `sha1sum` cases; vendored source is `coreutils-9.1/src/digest.c`.
  - **Implementation closure decision**: Coordinator action covers exact unsupported-combination diagnostics, repeated stdin, streaming check parsing, and full binary/escaped filename byte parity.
  - **Oracle/stress closure plan**: Add command-specific malformed/missing matrices, escaped/binary names, huge files/check files, repeated `-`, unsupported option combinations, and exact byte parity.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## sha256sum
- **Command**: `sha256sum`
- **MSP implementation**: Registered at `Registry/MSPPOSIXCoreCommandPack.swift:76`; shared `MSPDigestCommand` in `Commands/Data/MSPChecksumCommands.swift:41-179`, SHA256 branch at `449-454`.
- **Reference source**: `coreutils-9.1/src/digest.c`, shared checksum parser, verifier, output renderer, and main.
- **GNU/Linux parameter surface**: Same digest surface as `md5sum`: FILE/stdin, `-b`, `-t`, `-c`, `--tag`, `--zero`, `--ignore-missing`, `--quiet`, `--status`, `--strict`, `-w`, help/version.
- **Currently supported by MSP**: FILE/stdin/`-`, multi-file output, `-b`, `-t`, `-c`, `--status`, tagged/NUL output, check modifiers, tagged check parsing, newline/backslash/CR filename escaping, `--help`, and `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File hashing chunked; stdin/check files eager. O(n), bounded hasher memory, unbounded listed-file check workload.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because shared digest check semantics remain underimplemented.
- **Closure status**:
  - **Implemented evidence**: Swift registers `sha256sum` through `MSPDigestCommand` and supports stdin/file/multiple rows, `-b/-t`, `-c`, `--status`, `--tag`, `--zero`, check modifiers, tagged check parsing, newline/backslash/CR filename escaping, chunked file hashing, `--help`, and `--version`; unit evidence includes basic rows in `MSPDataAndTextCommandTests`, `MSPDataComparisonMetadataOracleTests`, and the shared digest option test; Core100 oracle has 5 baseline `sha256sum` cases; vendored source is `coreutils-9.1/src/digest.c`.
  - **Implementation closure decision**: Coordinator action covers exact unsupported-combination diagnostics, repeated stdin, streaming check parsing, and full binary/escaped filename byte parity.
  - **Oracle/stress closure plan**: Add command-specific check-mode combinations, invalid-line/missing matrices, escaped/binary names, huge files/check files, repeated `-`, unsupported option combinations, and exact byte parity.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## sha512sum
- **Command**: `sha512sum`
- **MSP implementation**: Registered at `Registry/MSPPOSIXCoreCommandPack.swift:77`; shared `MSPDigestCommand` in `Commands/Data/MSPChecksumCommands.swift:41-179`, SHA512 branch at `455-460`.
- **Reference source**: `coreutils-9.1/src/digest.c`, shared checksum parser, verifier, output renderer, and main.
- **GNU/Linux parameter surface**: Same digest surface as `md5sum`: FILE/stdin, `-b`, `-t`, `-c`, `--tag`, `--zero`, `--ignore-missing`, `--quiet`, `--status`, `--strict`, `-w`, help/version.
- **Currently supported by MSP**: FILE/stdin/`-`, multi-file output, `-b`, `-t`, `-c`, `--status`, tagged/NUL output, check modifiers, tagged check parsing, newline/backslash/CR filename escaping, `--help`, and `--version`.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File hashing chunked; stdin/check files eager. O(n), with larger digest output but small hasher state.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because "output length passed" is far below checksum compatibility.
- **Closure status**:
  - **Implemented evidence**: Swift registers `sha512sum` through `MSPDigestCommand` and supports stdin/file/multiple rows, `-b/-t`, `-c`, `--status`, `--tag`, `--zero`, check modifiers, tagged check parsing, newline/backslash/CR filename escaping, chunked file hashing, `--help`, and `--version`; unit evidence includes SHA512 rows and the shared digest option test in `MSPWorkerFIdentityEncodingDigestTests`; Core100 oracle has 10 baseline `sha512sum` cases including check ok/fail, binary/text, missing, zero-length, and space-path; vendored source is `coreutils-9.1/src/digest.c`.
  - **Implementation closure decision**: Coordinator action covers exact unsupported-combination diagnostics, repeated stdin, streaming check parsing, and full binary/escaped filename byte parity.
  - **Oracle/stress closure plan**: Add escaped/binary names, malformed mixed checks, huge files/check files, repeated `-`, unsupported option combinations, and exact byte parity.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## sum
- **Command**: `sum`
- **MSP implementation**: `Commands/Data/MSPSumCommand.swift:4-137`.
- **Reference source**: `coreutils-9.1/src/digest.c` HASH_ALGO_SUM option parser and usage; `coreutils-9.1/src/sum.c` BSD/SysV algorithms and output functions.
- **GNU/Linux parameter surface**: FILE operands and stdin; `-r` BSD algorithm/default with 1K blocks; `-s/--sysv` System V with 512-byte blocks; help/version; `-` as stdin.
- **Currently supported by MSP**: `-r`, `-s/--sysv`, `--help`, and `--version`; stdin when no operands; multiple file operands; `-` operand as consumed stdin among files; BSD/SysV algorithms with chunked `readFileRange` for file operands and in-memory stdin from the command context.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None.
- **Forbidden by policy**: Host-path reads outside WorkspaceFS.
- **Performance model**: File operands now stream via 32 KiB `readFileRange` chunks, matching the reference `sum.c` buffer size and O(1) checksum state; stdin is still provided by MSP as a single `Data` value. Algorithms are O(n). Large files still need cancellation and output/runtime caps from shared command execution.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: medium, because algorithms are simple but stdin/file semantics are incomplete.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPSumCommand` implements BSD/default and SysV algorithms for operands/stdin, `--sysv`, `--help`, `--version`, `-` as a consumed stdin operand among files, and 32 KiB chunked file reads; direct fixture covers default, `-r`, and `-s`; unit evidence in `MSPDataComparisonMetadataOracleTests.testSumSupportsSysvDashOperandAndRangeReads` and `MSPCore100ExtraCommandTests.testFactorAndSumUseGNUCoreutilsAlgorithms` covers `--sysv`, mixed file/stdin `-`, help/version, and range-read execution; Core100 oracle has 4 `sum` cases; vendored source is `coreutils-9.1/src/digest.c` and `src/sum.c`.
  - **Implementation closure decision**: Coordinator action covers exact spacing/diagnostics, huge-size overflow behavior, cancellation, and source-backed repeated-stdin parity.
  - **Oracle/stress closure plan**: Add VPS oracle for mixed stdin/file operands, huge streamed files, missing files, block rounding boundaries, SysV/BSD edge values, repeated `-`, and exact diagnostics.
  - **Deferred/forbidden with reason**: None for common GNU options. Host-path reads outside WorkspaceFS are forbidden.

## xxd
- **Command**: `xxd`
- **MSP implementation**: `Commands/Data/MSPXxdCommand.swift:4-136`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/vim-9.0.1378/src/xxd/xxd.c:211-242` for usage; `xxd.c:327-414` for reverse `huntype`; `xxd.c:485-739` for option parsing, input/output operands, reverse restrictions, seek, and outfile open modes; `xxd.c:767-889` for include, postscript/plain, normal, bits, little-endian, autoskip, and display rendering.
- **GNU/Linux parameter surface**: `xxd [options] [infile [outfile]]` or `xxd -r [-s [-]offset] [-c cols] [-ps] [infile [outfile]]`; `-` means stdin/stdout. Options from Vim source are `-a` autoskip toggle, `-b` bit dump, `-C` capitalize include variable names, `-c cols`/`-cols`, `-E` EBCDIC character column, `-e` little-endian dump, `-g bytes`/`-group`, `-h` help, `-i` C include output, `-l len`/`-len`, `-n name`/`-name`, `-o off`/`-offset`, `-p`/`-ps` postscript plain dump, `-r` reverse/patch, `-d` decimal offsets, `-s [+][-]seek`/`-seek`/`-skip`, `-u` uppercase hex, and `-v` version. Defaults are cols 16 normal/little, 12 include, 30 postscript, 6 bits; group defaults 2 normal, 4 little, 1 bits, 0 include/postscript; normal/bits/little cols max 256; little-endian group must be a power of two. `-r` accepts normal and postscript/plain hex only, can seek/patch the output, and output file mode differs from dump mode: dump truncates, reverse opens for patching.
- **Currently supported by MSP**: Accepted options are `-p`/`-ps`, `-r`, `-u`, `-h`, `-v`, `-c VALUE`, `-g VALUE`, and `-l VALUE`; `-r` currently decodes plain hex only and returns stdout bytes rather than patching an output file. No long-ish aliases, input/output operand distinction, reverse writes, seek/display offset, include output, bits, EBCDIC, little-endian, decimal offsets, autoskip, or side-effecting reverse patch. Operands are treated as generic input files and concatenated; the whole input is loaded into memory; output is returned as one string/data blob.
- **Must implement**: No remaining child-owned SDK item after this batch; verified scope and coordinator actions are listed under Closure status.
- **Deferred with reason**: None for read-only dump modes. Reverse output patching is implementable only inside WorkspaceFS and must be bounded; any host-device or sparse-file behavior outside that boundary is policy-forbidden rather than deferred.
- **Forbidden by policy**: Host-path reads or writes outside WorkspaceFS, device paths, unbounded seek-created sparse/zero-filled files, and reverse patching that can grow output beyond configured workspace or command limits.
- **Performance model**: Reference `xxd` streams input and writes each rendered line, O(n) time with O(cols) working memory, while include/plain output can expand bytes by several times. Current MSP is O(n) input memory plus O(output) memory and is risky for large binaries. Reverse is O(input hexdump) but can seek, patch, or zero-fill arbitrary offsets; MSP needs maximum seek/output sizes, streaming output, cancellation, and side-effect rollback/error handling.
- **Oracle/stress gaps**: No remaining child-owned fixture edit after this batch; safe capture drafts and coordinator actions are listed under Closure status.
- **Risk**: high, because current MSP is still mostly a small read-only dumper while source `xxd` includes output-file side effects and reverse patch semantics.
- **Closure status**:
  - **Implemented evidence**: Swift `MSPXxdCommand` supports normal dump, `-p`, `-ps`, `-u`, `-h`, `-v`, `-c`, `-g`, `-l`, and plain `-r` decoding; unit evidence is in `MSPDataAndTextCommandTests` and `MSPDataComparisonMetadataOracleTests`; Core100 oracle has 4 `xxd` cases; vendored source is `vim-9.0.1378/src/xxd/xxd.c`.
  - **Implementation closure decision**: Coordinator action covers two-operand infile/outfile writes, full reverse normal/patch behavior, `-s`, `-o`, `-i`, `-n`, `-C`, `-b`, `-E`, `-e`, `-d`, `-a`, exact numeric parsing, spacing/grouping/ascii parity, output caps, and side-effect limits.
  - **Oracle/stress closure plan**: Add broader normal spacing and postscript/plain alias matrices beyond the existing Core100 cases, seek/display offsets, outfile writes, reverse normal and patch cases, sparse caps, include output, bits/EBCDIC/little-endian/decimal/autoskip, invalid option values, huge binaries, and exact Vim `xxd` diagnostics.
  - **Deferred/forbidden with reason**: No read-only dump mode is deferred. Reverse patching is allowed only inside WorkspaceFS with caps; host paths/devices and unbounded sparse/zero-filled growth are forbidden.
