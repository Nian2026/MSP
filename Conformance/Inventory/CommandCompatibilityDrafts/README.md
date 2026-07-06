# Core100 Command Compatibility Drafts

This directory is a pre-release audit matrix for closing MSP Core100 command
compatibility gaps. It is not a compatibility statement and must not be used to
justify broad unsupported behavior.

## Scope

Each batch file audits a disjoint group of Core100 commands. The audit output is
read-only with respect to implementation: do not edit SDK source, tests, oracle
fixtures, or shared runtime files while producing these drafts.

## Required Evidence Per Command

For every command, include these fields:

| Field | Requirement |
| --- | --- |
| `Command` | Exact command name from `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`. |
| `MSP implementation` | Swift source path(s) that currently implement the command. Include line anchors when useful. |
| `Reference source` | Local Debian source path(s), plus the relevant entry function or parser/helper functions when identifiable. |
| `GNU/Linux parameter surface` | Options and operand forms exposed by the reference implementation or its option table/help surface. |
| `Currently supported by MSP` | Options/forms that the Swift implementation actually accepts today. |
| `Must implement` | Default bucket for missing common options/forms. Treat `unsupported` branches as debt unless proven otherwise. |
| `Deferred with reason` | Only for extremely cold, very complex, or policy-incompatible behavior. Every entry needs a concrete reason. |
| `Forbidden by policy` | Host/device/system mutations that MSP must never expose by default. |
| `Performance model` | Streaming vs eager behavior; expected time/memory complexity; whole-tree or whole-file risks; cancellation/limit needs. |
| `Oracle/stress gaps` | Required VPS oracle, long-input, complex-shell, side-effect, or byte-level cases missing from current coverage. |
| `Risk` | `low`, `medium`, or `high`, with a one-sentence reason. |

## Non-Negotiable Rules

- Do not write "fully supported" unless the current Swift implementation and
  oracle coverage prove it.
- Do not mark a missing common GNU option as deferred just because it is not
  implemented yet.
- Compare against local reference source under
  `References/LinuxSourceSnapshot/debian12-bookworm/sources/`.
- Prefer source evidence over help text; help text is acceptable only as a
  secondary map of the option surface.
- If a command is virtualized by MSP, state the virtualization boundary
  explicitly.
- Keep every batch file self-contained. A reviewer should not need another
  batch file to understand a command's current gap.

## Batch Files

| Batch | Owner output | Commands |
| --- | --- | --- |
| 01 shell/path/runtime | `batch-01-shell-path-runtime.md` | `:`, `[`, `[[`, `basename`, `builtin`, `cd`, `command`, `dirname`, `echo`, `env`, `false`, `printf`, `printenv`, `pwd`, `test`, `true`, `type`, `which` |
| 02 filesystem | `batch-02-filesystem.md` | `chmod`, `cp`, `du`, `find`, `install`, `link`, `ln`, `ls`, `mkdir`, `mktemp`, `mv`, `rm`, `rmdir`, `touch`, `tree`, `truncate`, `unlink` |
| 03 text streams | `batch-03-text-streams.md` | `cat`, `comm`, `cut`, `expand`, `fmt`, `fold`, `grep`, `head`, `join`, `nl`, `paste`, `sort`, `tail`, `tac`, `tee`, `tr`, `uniq`, `unexpand`, `wc`, `yes` |
| 04 text languages/search | `batch-04-text-languages-search.md` | `awk`, `sed`, `rg`, `xargs`, `seq`, `shuf`, `strings`, `tsort`, `split` |
| 05 data/comparison/numeric | `batch-05-data-comparison-numeric.md` | `b2sum`, `base32`, `base64`, `basenc`, `bc`, `cksum`, `cmp`, `date`, `dd`, `diff`, `expr`, `factor`, `md5sum`, `numfmt`, `od`, `sha1sum`, `sha256sum`, `sha512sum`, `sum`, `xxd` |
| 06 metadata/process/identity | `batch-06-metadata-process-identity.md` | `file`, `groups`, `hostname`, `id`, `ldd`, `nproc`, `pathchk`, `ps`, `readlink`, `realpath`, `sleep`, `stat`, `timeout`, `tty`, `uname`, `whoami` |
