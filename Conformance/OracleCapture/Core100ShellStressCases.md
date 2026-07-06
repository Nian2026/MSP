# Core100 Shell Stress Oracle Cases

This file defines the required shell-runtime stress cases for Core100 oracle
capture. These cases are intentionally broad because parser/runtime behavior is
where an agent most easily distinguishes MSP from a real Linux shell.

Every case must follow `DebianOracleCaptureSafetyPolicy.md`: isolated temporary
case root, no host mutations, no dangerous absolute paths, no elevated
privileges, and byte-safe capture.

## Stress Tiers

| Tier | Purpose | Required before |
| --- | --- | --- |
| S0 | smoke parity for common composition | any Core100 implementation merge |
| S1 | long and complex syntax | claiming Core100 command expansion parity |
| S2 | pressure and cancellation | enabling Core100 by default in an app |

## S0 Common Composition

| Case id | Shell | Purpose |
| --- | --- | --- |
| `stress-s0-pipeline-basic` | sh | `printf | grep | sed | awk | wc` preserves stdout/stderr/exit code |
| `stress-s0-pipeline-failure-status` | bash | pipeline status and `pipefail` behavior |
| `stress-s0-redirection-basic` | sh | `>`, `>>`, `<`, `2>`, `2>&1` with WorkspaceFS files |
| `stress-s0-sequential-and-or` | sh | `;`, `&&`, `||`, `!` status propagation |
| `stress-s0-subshell-cwd` | sh | `(cd dir; pwd); pwd` state isolation |
| `stress-s0-group-redirection` | sh | `{ ...; } > out.txt` group redirection |
| `stress-s0-command-substitution` | sh | nested `$(...)` with newlines and trimming |
| `stress-s0-quoted-words` | sh | single quotes, double quotes, escaped spaces, empty args |
| `stress-s0-glob-basic` | bash | `*`, `?`, bracket classes, no-match behavior |
| `stress-s0-heredoc-basic` | sh | heredoc body exact bytes and exit status |
| `stress-s0-function-basic` | bash | function definition, arguments, return code |
| `stress-s0-loop-basic` | sh | `for`, `while`, `break`, `continue` |

## S1 Long and Complex Syntax

| Case id | Shell | Purpose |
| --- | --- | --- |
| `stress-s1-overlong-command-line` | bash | command line above ordinary app UI length, stable stdout |
| `stress-s1-overlong-single-argument` | bash | one huge argument through quote handling and `wc -c` |
| `stress-s1-overlong-env-assignment` | bash | long assignment prefix visible to child command only |
| `stress-s1-overlong-pipeline` | bash | dozens of stages with deterministic output |
| `stress-s1-many-redirections` | bash | fd 3+ writes, duplication, close, append |
| `stress-s1-nested-command-substitution` | bash | nested `$(printf "$(printf ...)")` behavior |
| `stress-s1-arithmetic-expansion` | bash | `$((...))`, variables, arrays, invalid arithmetic |
| `stress-s1-parameter-defaults` | bash | `${x:-}`, `${x:=}`, `${x:?}`, `${x:+}` |
| `stress-s1-parameter-substrings` | bash | `${x:offset:length}` and negative offsets |
| `stress-s1-parameter-patterns` | bash | `${x#}`, `${x##}`, `${x%}`, `${x%%}`, replace forms |
| `stress-s1-brace-expansion` | bash | nested braces and sequence expansion |
| `stress-s1-extglob` | bash | `shopt -s extglob`, pattern matching and no-match |
| `stress-s1-globstar` | bash | `shopt -s globstar`, recursive matching |
| `stress-s1-nullglob-failglob-dotglob` | bash | option-specific glob behavior |
| `stress-s1-heredoc-quoted` | bash | quoted delimiter prevents expansion |
| `stress-s1-heredoc-tabs` | bash | `<<-` tab stripping behavior |
| `stress-s1-here-string` | bash | `<<<` newline behavior and quoting |
| `stress-s1-case-patterns` | sh | `case` with fallthrough-like alternatives |
| `stress-s1-if-test-compound` | sh | `if`, `[`, `test`, `&&`, `||` combined |
| `stress-s1-functions-local-return` | bash | `local`, `return`, nested calls, stdout order |
| `stress-s1-source-state` | bash | source mutates parent vars/cwd/fds as Linux does |
| `stress-s1-eval-reparse` | bash | `eval` quoting and second-pass parsing |
| `stress-s1-arrays-indexed` | bash | sparse indexed arrays, expansion, unset |
| `stress-s1-arrays-associative` | bash | associative arrays, quoted keys, unset |
| `stress-s1-nameref` | bash | `declare -n` references and diagnostics |
| `stress-s1-process-substitution-input` | bash | `<(...)` path output normalized safely |
| `stress-s1-process-substitution-output` | bash | `>(...)` finalization and ordering |
| `stress-s1-binary-stdout` | bash | binary bytes through stdout, base64 fixture compare |
| `stress-s1-binary-stderr` | bash | binary bytes through stderr, base64 fixture compare |
| `stress-s1-non-utf8-stdin` | bash | non-UTF-8 bytes through pipeline without string loss |

## S2 Pressure and Cancellation

| Case id | Shell | Purpose |
| --- | --- | --- |
| `stress-s2-large-file-stream-head` | bash | large generated file through `cat | head` early close |
| `stress-s2-large-directory-find-head` | bash | large tree traversal stops after downstream close |
| `stress-s2-large-directory-ls-head` | bash | unsorted streaming list can be stopped |
| `stress-s2-large-grep-quiet` | bash | recursive `grep -q` stops after first match |
| `stress-s2-yes-head-broken-pipe` | bash | infinite producer exits promptly after `head` closes |
| `stress-s2-timeout-sleep` | bash | timeout returns 124 and cancels child |
| `stress-s2-timeout-noncooperative` | bash | timeout wins against busy producer |
| `stress-s2-xargs-batching-long-input` | bash | long stdin batched by `xargs` boundaries |
| `stress-s2-sort-large-input` | bash | global sort memory boundary with deterministic output |
| `stress-s2-diff-large-early-mismatch` | bash | `diff -q` stops after early mismatch |
| `stress-s2-cmp-large-early-mismatch` | bash | `cmp` stops after early mismatch |
| `stress-s2-dd-limited-copy` | bash | `dd` copies bounded chunks only inside case root |
| `stress-s2-split-output-fanout` | bash | `split` output count and names under policy limit |
| `stress-s2-shuf-deterministic` | bash | `shuf --random-source` produces stable oracle |
| `stress-s2-sleep-cancel` | bash | runner cancellation interrupts bounded sleep |

## Required Fixtures

The stress batch must include these fixture shapes:

1. empty case root;
2. small text tree;
3. paths with spaces;
4. paths starting with `-`;
5. paths containing glob characters;
6. unicode path names;
7. newline in a filename when safe for the runner;
8. symlink inside case root;
9. broken symlink inside case root;
10. binary file with NUL bytes;
11. non-UTF-8 byte file;
12. long-line text file;
13. large but bounded multi-chunk file;
14. large but bounded directory tree;
15. executable script file;
16. sourced script file;
17. deterministic random-source file for `shuf`.

## Comparison Fields

Each stress case must declare exact comparison fields:

- `stdout`;
- `stderr`;
- `exit_code`;
- `file_tree` when side effects are expected;
- `permissions` when mode behavior matters;
- `side_effects` for created, removed, appended, truncated, linked, or symlinked
  paths;
- `duration_class` only for cancellation/timeout cases, never as a replacement
  for stdout/stderr/exit-code equality.

## Promotion Rule

A stress case may enter public conformance only when the normalized fixture
preserves every byte of observable shell output. If a field is unstable because
it is truly host-dependent, the case must either define a narrow normalization
rule or remain private capture evidence until the MSP standard decides the
virtual behavior.
