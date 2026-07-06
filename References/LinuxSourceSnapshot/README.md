# Linux Source Snapshot

This directory is the public index for local-only Core100 MSP command source
references. The Swift implementation must stay MSP-native, but command
semantics should be derived from the Linux/GNU/bash/dash sources listed here
instead of guesses or case-specific patches.

The extracted source tree under
`References/LinuxSourceSnapshot/debian12-bookworm/sources/` is intentionally
ignored by Git and is not part of the default open-source repository surface.
Restore it locally when doing source-backed command work; keeping the tree in
place locally does not affect the publishable repo surface.

## Snapshot Roots

```text
References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1
References/LinuxSourceSnapshot/debian12-bookworm/sources/bash-5.2.15
References/LinuxSourceSnapshot/debian12-bookworm/sources/dash-0.5.12
References/LinuxSourceSnapshot/debian12-bookworm/sources/binutils-2.40
References/LinuxSourceSnapshot/debian12-bookworm/sources/tree-2.1.0
References/LinuxSourceSnapshot/debian12-bookworm/sources/findutils-4.9.0
References/LinuxSourceSnapshot/debian12-bookworm/sources/grep-3.8
References/LinuxSourceSnapshot/debian12-bookworm/sources/sed-4.9
References/LinuxSourceSnapshot/debian12-bookworm/sources/mawk-1.3.4-20200120
References/LinuxSourceSnapshot/debian12-bookworm/sources/diffutils-3.8
References/LinuxSourceSnapshot/debian12-bookworm/sources/bc-1.07.1
References/LinuxSourceSnapshot/debian12-bookworm/sources/vim-9.0.1378
References/LinuxSourceSnapshot/debian12-bookworm/sources/file-5.44
References/LinuxSourceSnapshot/debian12-bookworm/sources/procps-ng-4.0.2
References/LinuxSourceSnapshot/debian12-bookworm/sources/glibc-2.36
References/LinuxSourceSnapshot/debian12-bookworm/sources/hostname-3.23+nmu1
References/LinuxSourceSnapshot/debian12-bookworm/sources/debianutils-5.7
References/LinuxSourceSnapshot/debian12-bookworm/sources/ripgrep-13.0.0
```

The `coreutils`, `bash`, and `dash` snapshots were copied from local Debian 12
source-package artifacts. The `binutils` and `tree` snapshots were fetched from
Debian 12 source packages on the reference VPS and copied back as extracted
source trees. The later command-compatibility
snapshot additions were fetched from Debian bookworm source packages, extracted
locally, and had Debian `debian/patches/series` patches applied where present:
`findutils 4.9.0-4`, `grep 3.8-5`, `sed 4.9-1+deb12u1`,
`mawk 1.3.4.20200120-3.1`, `diffutils 3.8-4`, `bc 1.07.1-3`,
`vim 9.0.1378-2+deb12u2`, `file 5.44-3`, `procps 4.0.2-3`,
`glibc 2.36-9+deb12u14`, `hostname 3.23+nmu1`, `debianutils
5.7-0.5~deb12u1`, and `rust-ripgrep 13.0.0-4`.

## Core100 Reference Map

### A: Shell State

- `export`, shell attributes: `bash-5.2.15/builtins/setattr.def`
- `unset`: `bash-5.2.15/builtins/set.def`, `bash-5.2.15/builtins/common.c`
- `set`: `bash-5.2.15/builtins/set.def`
- `umask`: `bash-5.2.15/builtins/umask.def`
- dash comparison: `dash-0.5.12/src/options.c`, `dash-0.5.12/src/var.c`

### B: Shell Input, Source, Alias

- `read`: `bash-5.2.15/builtins/read.def`
- `source`, `.`: `bash-5.2.15/builtins/source.def`
- `alias`, `unalias`: `bash-5.2.15/builtins/alias.def`
- alias expansion/runtime context: `bash-5.2.15/parse.y`
- dash `read` / dot behavior: `dash-0.5.12/src/miscbltin.c`,
  `dash-0.5.12/src/eval.c`
- `which`: `debianutils-5.7/which`

### C: Filesystem

- `find`: `findutils-4.9.0/find/parser.c`,
  `findutils-4.9.0/find/ftsfind.c`, `findutils-4.9.0/find/pred.c`
- `rmdir`: `coreutils-9.1/src/rmdir.c`
- `unlink`: `coreutils-9.1/src/unlink.c`
- `truncate`: `coreutils-9.1/src/truncate.c`
- `install`: `coreutils-9.1/src/install.c`
- `tree`: `tree-2.1.0/tree.c`, `tree-2.1.0/file.c`,
  `tree-2.1.0/list.c`, `tree-2.1.0/filter.c`

### D: Byte Streams And Graph/Random Utilities

- `xargs`: `findutils-4.9.0/xargs/xargs.c`
- `dd`: `coreutils-9.1/src/dd.c`
- `split`: `coreutils-9.1/src/split.c`
- `shuf`: `coreutils-9.1/src/shuf.c`
- `tsort`: `coreutils-9.1/src/tsort.c`

### E: Text Layout And Binary Text Recognition

- `grep`: `grep-3.8/src/grep.c`
- `sed`: `sed-4.9/sed/sed.c`, `sed-4.9/sed/execute.c`
- `awk`: `mawk-1.3.4-20200120/main.c`,
  `mawk-1.3.4-20200120/parse.c`,
  `mawk-1.3.4-20200120/scan.c`,
  `mawk-1.3.4-20200120/execute.c`
- `rg`: `ripgrep-13.0.0/crates/core/main.rs`,
  `ripgrep-13.0.0/crates/core/args.rs`
- `expr`: `coreutils-9.1/src/expr.c`
- `strings`: `binutils-2.40/binutils/strings.c`
- `bc`: `bc-1.07.1/bc/main.c`, `bc-1.07.1/bc/bc.y`
- `diff`, `cmp`: `diffutils-3.8/src/diff.c`,
  `diffutils-3.8/src/cmp.c`
- `xxd`: `vim-9.0.1378/src/xxd/xxd.c`
- `fold`: `coreutils-9.1/src/fold.c`
- `expand`: `coreutils-9.1/src/expand.c`
- `unexpand`: `coreutils-9.1/src/unexpand.c`
- `fmt`: `coreutils-9.1/src/fmt.c`

### F: Identity, Encoding, Digest, Time

- `uname`: `coreutils-9.1/src/uname.c`
- `whoami`: `coreutils-9.1/src/whoami.c`
- `id`: `coreutils-9.1/src/id.c`
- `hostname`: `hostname-3.23+nmu1/hostname.c`; hostname mutation remains
  forbidden.
- `file`: `file-5.44/src/file.c`
- `ps`: `procps-ng-4.0.2/src/ps/parser.c`,
  `procps-ng-4.0.2/src/ps/display.c`,
  `procps-ng-4.0.2/src/ps/output.c`
- `ldd`: `glibc-2.36/elf/ldd.bash.in`
- `sleep`: `coreutils-9.1/src/sleep.c`
- `base32`, `basenc`: `coreutils-9.1/src/basenc.c`,
  `coreutils-9.1/lib/base32.c`, `coreutils-9.1/lib/base64.c`
- `sha512sum`: `coreutils-9.1/src/digest.c`,
  `coreutils-9.1/lib/sha512.c`, `coreutils-9.1/lib/sha512-stream.c`
- `b2sum`: `coreutils-9.1/src/blake2/b2sum.c`,
  `coreutils-9.1/src/digest.c`

## Rules For Workers

- Treat locally restored source files under
  `References/LinuxSourceSnapshot/debian12-bookworm/sources/**` as read-only
  reference material.
- Do not commit or force-add
  `References/LinuxSourceSnapshot/debian12-bookworm/sources/**`.
- Do not edit local restored snapshot files.
- Cite the exact source files/functions inspected in each worker summary.
- When an oracle mismatch is found, fix the underlying MSP parser/runtime,
  workspace, streaming, option parsing, or byte handling behavior. Do not
  hard-code oracle output or case IDs.
