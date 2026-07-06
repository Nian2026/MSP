# Batch 02 - Filesystem Commands

Source-backed compatibility matrix for Core100 filesystem commands. This is a
working conformance inventory, not a final compatibility certification. All commands here are registered as `implemented` in
`Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`, but none
should be called complete without option-surface, side-effect, policy, and oracle
closure.

Shared evidence and boundaries:

- MSP implementations are virtualized through `MSPWorkspaceFileSystem` and the
  Apple implementation under `Implementations/Swift/Sources/MSPApple/Workspace/MSPAppleWorkspace.swift`.
- Default WorkspaceFS hides `/.msp`, keeps trash storage hidden, and makes
  command-level removal recoverable via trash instead of physical unlink.
- `MSPResolvedPath` can carry `physicalPath`; command stdout/stderr must keep
  virtual/display paths and never leak host paths.
- Apple WorkspaceFS `enumerateDirectory` streams to the caller only after one
  directory level has been materialized and policy-ordered.
- `mspCore100MaximumMaterializedFileSize` is 64 MiB; commands that read or write
  whole files must be treated as bounded WorkspaceFS behavior, not GNU sparse or
  large-file parity.

## chmod

- **Command**: `chmod`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPChmodCommand.swift`, `MSPChmodCommand` and `mspPOSIXChmodPermissions`; uses `fileSystem.chmod`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/chmod.c`, `long_options`, `usage`, `main`, `mode_compile`, recursive processing.
- **GNU/Linux parameter surface**: mode forms `MODE[,MODE]... FILE...`, `OCTAL-MODE FILE...`, `--reference=RFILE FILE...`; options `-c/--changes`, `-f/--silent/--quiet`, `-v/--verbose`, `-R/--recursive`, `--preserve-root`, `--no-preserve-root`, `--help`, `--version`; symbolic modes include `rwxXst` and permission copying from `ugo`.
- **Currently supported by MSP**: one mode operand plus one or more targets; `--` terminator; `-R/--recursive` recursive descent through WorkspaceFS; `--reference=RFILE`, `-c/--changes`, `-f/--silent/--quiet`, `-v/--verbose`, `--preserve-root`, and `--no-preserve-root`; octal modes are accepted but masked to `0o777`; symbolic clauses support `ugoa`, `+/-/=`, and `rwxX`; each non-symlink target resolves through WorkspaceFS and calls `chmod`.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: none for common GNU chmod behavior. Owner/group/security-label behavior belongs to other commands and must not be hidden here.
- **Forbidden by policy**: changing permissions outside the WorkspaceFS root, exposing host physical paths in diagnostics, or letting recursive chmod cross hidden `/.msp`/trash storage. A future host-backed chmod must never chmod the real device root.
- **Performance model**: current implementation is O(number of targets plus recursively visited entries) when `-R` is used. Recursive chmod currently descends through WorkspaceFS listing; it requires explicit streaming/cancellation posture, cycle protection, hidden-path filtering, and bounded diagnostics.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because the current command mutates permissions and now has basic recursion, but still omits reference/special-bit/symlink-root semantics and relies on WorkspaceFS policy for containment.
- **Closure status**:
  - **Implemented evidence**: current Swift parses `--`, `-R/--recursive`, `--reference`, `-c/-f/-v`, preserve-root variants, octal/symbolic `ugoa +/-= rwxX`, skips symlink chmod, and applies modes through `fileSystem.chmod`; unit tests include recursive chmod and reference/verbosity/silent behavior, WorkspaceFS parity tests include invalid modes, partial missing-target diagnostics, and `stat -c %a`; direct parity has `chmod 600`, and Core100 oracle fixtures contain 5 chmod cases including octal, symbolic, and recursive-relative.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining hard-deferred items are special bits, symbolic permission copy, umask-sensitive symbolic defaults, exact GNU invalid-mode parsing, and full recursive symlink/root behavior because the current chmod parser is permission-bit-only and WorkspaceFS lacks a 0o7777/umask/symlink traversal contract.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: `chmod --reference=ref -v target`, `chmod -c 600 target`, `chmod -f 600 missing`, `chmod --preserve-root -R /`, plus existing symbolic `s/t/ugo` copy, symlink loop, hidden-root denial, multi-target partial-failure, and mode side-effect cases inside audited temp roots.
  - **Deferred/forbidden with reason**: no common chmod option is deferred; only out-of-workspace/host-root permission mutation and hidden storage traversal are forbidden by WorkspaceFS policy.

## cp

- **Command**: `cp`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPCpCommand.swift`; delegates to `fileSystem.copy`. Apple WorkspaceFS implements copy in `MSPAppleWorkspace.swift`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cp.c`, `long_opts`, `usage`, `main`; copy engine in `coreutils-9.1/src/copy.c` and `copy.h`.
- **GNU/Linux parameter surface**: forms `SOURCE DEST`, `SOURCE... DIRECTORY`, `-t DIRECTORY SOURCE...`; common options include `-a`, `--attributes-only`, `-b/--backup`, `--copy-contents`, `-d`, `-f`, `-H`, `-i`, `-l`, `-L`, `-n`, `-P`, `-p/--preserve`, `--no-preserve`, `--parents`, `-R/-r/--recursive`, `--reflink`, `--remove-destination`, `--sparse`, `--strip-trailing-slashes`, `-s`, `-S`, `-t`, `-T`, `-u`, `-v`, `-x`, `-Z/--context`, `--help`, `--version`.
- **Currently supported by MSP**: `-r`, `-R`, `--recursive`, `-f`, `--force`, `-n/--no-clobber`, `-t/--target-directory`, `-T/--no-target-directory`, `--parents`, `--strip-trailing-slashes`, and `-v/--verbose`; source(s) plus destination; recursive directory copies; destination directory resolution; parent-preserving destination creation under a directory operand; trailing-slash destination must already be a directory; same-virtual-path check; overwrite existing destination is requested from WorkspaceFS unless no-clobber wins.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: `--reflink` can be deferred until WorkspaceFS has clone/CoW capability; sparse-file physical allocation parity can be deferred where the backend has no sparse abstraction. Both still need deterministic diagnostics.
- **Forbidden by policy**: copying into or out of hidden policy paths, preserving raw host ownership/xattrs/security contexts by mutating the host, and leaking physical paths from symlink or error handling.
- **Performance model**: current command delegates recursion to the backend. Apple WorkspaceFS uses `FileManager.copyItem`; preflight is small but full-tree copy has no visible cancellation/progress and overwriting first moves the destination to trash. Large trees, symlink loops, and hidden paths require stress limits.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because copy is broad, destructive on destination, and currently supports only a thin subset of GNU's metadata/symlink/overwrite surface.
- **Closure status**:
  - **Implemented evidence**: current Swift parses recursive/force/no-clobber, target-directory, no-target-directory, and verbose, validates directory destinations and same-file copies, and delegates copy side effects to WorkspaceFS; WorkspaceFS parity tests cover missing source, directory without `-r`, directory-over-file, same-file, and simple copies; unit tests cover `-t`, `-T`, `-n`, and `-v`; direct parity has `cp source.txt copied.txt`, and Core100 oracle fixtures contain 5 cp cases including recursive and target-dir.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require shared metadata (`-a/-p`, same-inode), prompt policy (`-i`), sparse/clone APIs (`--sparse/--reflink`), backup naming policy, or WorkspaceFS symlink/dereference contracts; implementing them locally would either silently lie or bypass backend policy.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented `-T/-v`, symlink recursion, overwrite/trash diffs, no-clobber/update/backup matrices, metadata preservation, sparse/cap cases, huge-tree cancellation, and hidden/physical path leak scans inside audited temp roots.
  - **Deferred/forbidden with reason**: reflink/physical sparse allocation may be deferred until WorkspaceFS exposes clone/sparse capabilities; host xattr/security-context preservation and hidden-path access are forbidden.

## du

- **Command**: `du`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPDuCommand.swift`, `mspPOSIXCollectDuRows`, `mspPOSIXDuBlockSizeStyle`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/du.c`, `long_options`, `usage`, traversal and hard-link accounting.
- **GNU/Linux parameter surface**: operands default to `.` or `--files0-from=F`; options include `-0/--null`, `-a/--all`, `--apparent-size`, `-B/--block-size`, `-b/--bytes`, `-c/--total`, `-D/-H/--dereference-args`, `-d/--max-depth`, `--files0-from`, `-h`, `--inodes`, `--si`, `-k`, `-L`, `-l/--count-links`, `-m`, `-P`, `-S/--separate-dirs`, `-s`, `-t/--threshold`, `--time`, `--time-style`, `-X/--exclude-from`, `--exclude`, `-x`, `--help`, `--version`.
- **Currently supported by MSP**: default operands, `-0/--null`, `-s`, `-h`, `-a`, `-b`, `-k`, `-m`, `-c`, `-B VALUE`, `-d VALUE`; long `--summarize`, `--human-readable`, `--all`, `--bytes`, `--apparent-size`, `--total`, `--block-size`, `--max-depth`. Size model is synthetic: directories are 4096 bytes, allocated size rounds regular files to 4096.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: true inode/device accounting can be deferred until WorkspaceFS exposes stable inode/device metadata; it must still produce deterministic virtual values or diagnostics when options are accepted.
- **Forbidden by policy**: descending hidden trash/storage paths, reporting host device IDs, or leaking physical paths from backend errors.
- **Performance model**: recursive traversal is O(entries); rows are accumulated in memory before output, and each directory layer is materialized by WorkspaceFS. Needs streaming output, cancellation, row/output caps, and cycle/hard-link tracking.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because current numbers are synthetic and traversal lacks GNU hard-link/symlink/accounting semantics.
- **Closure status**:
  - **Implemented evidence**: current Swift supports default operands, summarize/all/bytes/apparent-size/total, `-0/--null`, `-h/-k/-m`, `-B`, and `-d/--max-depth` with synthetic 4096-byte directory/allocation accounting; WorkspaceFS parity tests cover missing paths, file/dir block output, invalid max-depth, and `-b -c`; direct parity has `du -b`, unit tests cover NUL-terminated rows, and Core100 oracle fixtures contain 4 du cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require virtual inode/device/link identity, WorkspaceFS dereference/xdev policy, files0-from input plumbing, exclude/time metadata, and exact GNU block-size grammar; local synthetic accounting cannot prove those safely.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented `-0/--null`, hard-link double counts, symlink matrix, depth/summarize/all conflicts, files0-from, large/wide/deep traversal, hidden paths, and byte-exact block/total outputs.
  - **Deferred/forbidden with reason**: true inode/device reporting can wait for stable virtual metadata; host device IDs, hidden storage traversal, and physical path leakage are forbidden.

## find

- **Command**: `find`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Search/MSPFindCommand.swift`, `FindQuery`, `FindExpressionParser`, `FindPredicate`, `FindAction`, streaming writers, and batched `-exec`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/findutils-4.9.0/find/parser.c`, `parse_table[]`, special `parse_entry_newerXY`, parser helpers including `insert_type`, `insert_exec_ok`, `parse_size`, `parse_perm`, `parse_time`; traversal in `find/ftsfind.c`, `find`, `consider_visiting`, `process_all_startpoints`, `main`; predicates/actions in `find/pred.c`, especially `pred_delete`, `pred_exec*`, `pred_prune`, `pred_quit`, `pred_size`, `pred_type`, `pred_xtype`.
- **GNU/Linux parameter surface**: from findutils 4.9.0 source tables: form `find [-H] [-L] [-P] [-Olevel] [-D debugopts] [path...] [expression]`, default path `.`, default expression `-print`, leading `--`, and `-files0-from FILE` as an alternate NUL-delimited start-point source. Operators are `!`, `-not`, `(`, `)`, `,`, implicit and, `-a/-and`, `-o/-or`. Positional/normal options are `-daystart`, `-follow`, `-nowarn`, `-warn`, `-regextype TYPE`, `-depth`, deprecated `-d`, `-maxdepth LEVELS`, `-mindepth LEVELS`, `-mount/-xdev`, `-noleaf`, `-ignore_readdir_race`, `-noignore_readdir_race`. Tests are `-amin`, `-anewer`, `-atime`, `-cmin`, `-cnewer`, `-ctime`, `-context`, `-empty`, `-false`, `-fstype`, `-gid`, `-group`, `-ilname`, `-iname`, `-inum`, `-ipath`, `-iregex`, `-iwholename`, `-links`, `-lname`, `-mmin`, `-mtime`, `-name`, `-newer`, special `-newerXY`, `-nogroup`, `-nouser`, `-path`, `-perm [-/]MODE`, `-readable`, `-writable`, `-executable`, `-regex`, `-samefile`, `-size N[bcwkMG]`, `-true`, `-type [bcdpflsD]`, `-uid`, `-used`, `-user`, `-wholename`, `-xtype [bcdpfls]`. Actions are `-delete`, `-print`, `-print0`, `-printf FORMAT`, `-fprintf FILE FORMAT`, `-fprint FILE`, `-fprint0 FILE`, `-ls`, `-fls FILE`, `-prune`, `-quit`, `-exec COMMAND ;`, `-exec COMMAND {} +`, `-execdir COMMAND ;`, `-execdir COMMAND {} +`, `-ok COMMAND ;`, `-okdir COMMAND ;`, plus GNU `--help`/`--version`.
- **Currently supported by MSP**: default path `.`, path operands before the first expression token, expression parsing with `!`, `-not`, implicit and, `-a/-and`, `-o/-or`, parentheses and escaped parentheses; tests `-name`, `-iname`, `-path`, `-ipath`, `-regex`, `-iregex`, `-type f/d/l`, `-true`, `-false`, `-empty`, `-readable`, `-writable`, `-executable`, `-newer`, `-mtime`, `-mmin`, `-size` with block/default, `b`, `c`, `k`, `M`, `G`, octal `-perm` with exact/all/any, and `-prune`; options `-mindepth`, `-maxdepth`, and `-xdev/-mount` parsed as no-op. Actions are `-print`, `-print0`, limited `-printf`, `-exec ... ;`, `-exec ... {} +`, and `-quit`. Traversal is pre-order only through WorkspaceFS, with virtual-display paths.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: none for the parser-table surface as a compatibility target. Policy-sensitive items such as physical `-delete`, directory-relative execution, interactive `-ok*`, SELinux `-context`, and block/char/socket/FIFO host metadata may stage behind explicit virtual policy or deterministic unsupported diagnostics, but they remain deferred compatibility items when the option is accepted or advertised.
- **Forbidden by policy**: traversing or mutating the real host root, exposing physical paths, descending hidden `/.msp` or trash storage, hard-deleting workspace content by default, executing arbitrary host programs outside registered MSP command/runtime policy, using `-execdir` with unsafe PATH/current-directory semantics, or letting `-files0-from` read host files outside WorkspaceFS.
- **Performance model**: GNU `ftsfind.c` streams one `FTSENT` at a time through `fts_read`; `-maxdepth` calls `FTS_SKIP` before descent, `-mindepth` suppresses predicate evaluation above the threshold, `-depth` switches to post-order, and `-xdev` maps to `FTS_XDEV`. GNU `pred_prune` returns true and sets `state.stop_at_current_level`, causing `visit` to call `FTS_SKIP`; it has no pruning effect under `-depth`. GNU `pred_quit` runs `cleanup()` before exit, so pending `-exec ... {} +` batches are executed before early termination. GNU `-exec ... {} +` uses buildcmd with ARG_MAX/environment headroom and flushes at cleanup or `-execdir` directory-level boundaries. MSP can stream stdout only when a stream is attached; buffered mode materializes output, traversal materializes one WorkspaceFS directory level per recursion, `-prune` currently applies even in cases where `-mindepth` should suppress evaluation, `-xdev` is no-op, and batched exec flushes at fixed 128 item/32 KiB limits. Large trees need cancellation, recursion-depth protection, symlink-cycle policy, output caps, and downstream broken-pipe behavior comparable to GNU close/SIGPIPE handling so `find ... | head` stops traversal instead of walking the whole tree.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because the current MSP command covers only a small pre-order, virtualized subset of findutils' parser table while `find` combines traversal control, predicate evaluation, file mutation, output files, and command execution.
- **Closure status**:
  - **Implemented evidence**: current Swift has a real expression parser, pre-order WorkspaceFS traversal, supported tests/actions listed above, streaming output paths, and limited batched `-exec`; smoke/parity tests cover name/path/type/empty/perm/size/printf/print0/exec/delete rejection and error edges; performance tests exercise streaming traversal; direct parity has one complex find case, and Core100 oracle fixtures contain 5 direct find cases plus stress cases and 31 total generated/reference cases involving find.
  - **Implementation closure / hard deferred**: child-owned marker closed for current scope. Remaining parser-table surface needs shared traversal controls, metadata/time predicates, file-output actions, command-exec policy, prompt channel, ARG_MAX batching, and delete policy; these are coordinating/shared-runtime work rather than safe single-command edits.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: parser-table matrix, path/expression boundaries, depth/prune, symlink loops, xdev, special file types, time windows, `/000` perm, size rounding, file-output actions, delete policy, execdir/ok prompts, quit batch flushing, broken-pipe `| head`, hidden paths, and physical path leakage.
  - **Deferred/forbidden with reason**: no parser-table surface is deferred as compatibility target; physical hard-delete, arbitrary host execution, unsafe execdir PATH/current-directory semantics, host-root traversal, and host-file files0-from are forbidden unless virtual policy explicitly models them.

## install

- **Command**: `install`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPInstallCommand.swift`; uses whole-file `readFile`/`writeFile`, `chmod`, simple backup, and directory creation helpers.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/install.c`, `long_options`, `usage`, `main`; shared copy behavior from `copy.c`.
- **GNU/Linux parameter surface**: forms `SOURCE DEST`, `SOURCE... DIRECTORY`, `-t DIRECTORY SOURCE...`, `-d DIRECTORY...`; options `-b/--backup`, `-c` ignored, `-C/--compare`, `-d/--directory`, `-D`, `-g/--group`, `-m/--mode`, `-o/--owner`, `-p/--preserve-timestamps`, `-s/--strip`, `--strip-program`, `-S/--suffix`, `-t`, `-T`, `-v`, `--preserve-context`, `-Z/--context`, `--help`, `--version`.
- **Currently supported by MSP**: `-b`, `-c`, `-C`, `-D`, `-d`, `-p`, `-s`, `-T`, `-v`, `-g`, `-m`, `-o`, `-t` and long equivalents for backup/compare/directory/strip/strip-program/preserve-timestamps/mode/target-directory/owner/group. `-c` is GNU-compatible no-op; `--strip-program` is parsed but never executed unless `-s` reaches the existing deterministic strip failure; `install -d -v` reports created directories; `-m` accepts only octal and masks to permission bits; `-g/-o/-p` are parsed but currently ignored; backup writes `DEST~`.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: actual binary stripping can be deferred because it requires external tool execution and binary format support; preserve-context/SELinux can be deferred or rejected on non-Linux virtual backends with GNU-like diagnostics.
- **Forbidden by policy**: mutating real host uid/gid/security context, running arbitrary host strip programs by default, installing outside the workspace, or writing hidden policy/trash paths.
- **Performance model**: regular file install reads the whole source into memory and compares/writes whole `Data`, capped by the shared 64 MiB limit. Backups also read whole files. Needs streaming copy, checksum/metadata compare, cancellation, and bounded diagnostics.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because accepted options currently include ignored metadata flags and whole-file materialization diverges from GNU install.
- **Closure status**:
  - **Implemented evidence**: current Swift parses and implements copy, `-D`, `-d`, octal `-m`, `-t`, `-T`, `-b`, `-c`, `-C`, `-s` failure, `--strip-program` parsing, and `-v`; unit tests cover backup/mode, directory ancestor creation, ignored `-c`, and strip-program parsing; direct parity has install copy/mode output, and Core100 oracle fixtures contain 18 install cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining hard-deferred items are symbolic modes/special bits, owner/group virtual metadata, timestamp preservation, backup control/suffix, compare including metadata/time, exact verbose/target diagnostics, and streaming copy because they require shared chmod 0o7777 parsing, WorkspaceFS metadata APIs, or streaming copy primitives.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: `install -c src dst`, `install --strip-program=prog src dst`, symbolic/special `-m`, `-D/-d/-t/-T`, backup control/suffix, compare unchanged/changed, owner/group policy diagnostics, large file cap, overwrite/trash diffs, and missing operand cases inside audited temp roots.
  - **Deferred/forbidden with reason**: binary stripping and SELinux/context behavior can be deferred behind explicit virtual capability; host uid/gid/security-context mutation, arbitrary host strip programs, hidden paths, and out-of-workspace writes are forbidden.

## link

- **Command**: `link`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPLinkCommand.swift`; calls `fileSystem.createHardLink`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/link.c`, `usage`, `main`, `parse_gnu_standard_options_only`, `link(2)` call.
- **GNU/Linux parameter surface**: `link FILE1 FILE2`; standard `--help`/`--version`; exactly two operands; no recursive/force behavior.
- **Currently supported by MSP**: `--help`, `--version`, and exactly two operands after generic option parsing; creates a WorkspaceFS hard link; extra/missing operand diagnostics; no directory special case in command itself beyond backend behavior.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: true inode/link-count reporting can be deferred until WorkspaceFS exposes inode metadata, but link identity must be testable by content mutation or virtual metadata.
- **Forbidden by policy**: hard links to directories, links crossing out of workspace or into hidden storage, and surfacing host device/inode paths in errors.
- **Performance model**: O(1) metadata operation in current backend; no large data copy. Needs policy check before backend mutation.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: medium, because the surface is small but hard links can pierce safety assumptions if WorkspaceFS containment is wrong.
- **Closure status**:
  - **Implemented evidence**: current Swift delegates exactly two operands to `fileSystem.createHardLink` via generic option parsing; unit tests cover successful delegation plus existing and missing destination diagnostics; direct parity has `link src.txt hard.txt`, and Core100 oracle fixtures contain 3 link cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require standard help/version policy and virtual inode/link-count identity plus backend-specific directory/cross-device diagnostics; local command code already delegates the only safe mutation to WorkspaceFS.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: existing destination, missing source, directory source, symlink source, hidden/cross-workspace paths, and mutate-through-hard-link proof.
  - **Deferred/forbidden with reason**: inode/link-count reporting can wait for virtual metadata; hard-linking directories, linking outside workspace, hidden storage links, and host inode/path leakage are forbidden.

## ln

- **Command**: `ln`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPLnCommand.swift`, `MSPLnCommand`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/ln.c`, `long_options`, `usage`, `main`, link creation helpers.
- **GNU/Linux parameter surface**: forms `TARGET LINK_NAME`, `TARGET`, `TARGET... DIRECTORY`, `-t DIRECTORY TARGET...`; options `-b/--backup`, `-d/-F/--directory`, `-f/--force`, `-i/--interactive`, `-L/--logical`, `-n/--no-dereference`, `-P/--physical`, `-r/--relative`, `-s/--symbolic`, `-S/--suffix`, `-t/--target-directory`, `-T/--no-target-directory`, `-v`, `--help`, `--version`.
- **Currently supported by MSP**: `-s/--symbolic`, `-f/--force`, `-n/--no-dereference`, `-t/--target-directory`, `-T/--no-target-directory`, `-v/--verbose`, `--` terminator, one-target default link name, explicit two-operand links, and multiple targets into an existing directory. Hard links reject directories; symbolic links can target arbitrary text.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: `-d/-F` hard-linking directories should stay unimplemented unless a future virtual backend can model it safely; GNU itself says it usually fails due to system restrictions.
- **Forbidden by policy**: hard-linking directories, linking outside workspace, hidden path links, and storing or exposing host physical paths. Current Apple WorkspaceFS turns absolute virtual symlink targets into physical path strings on disk; that needs a policy fix before claiming parity.
- **Performance model**: O(1) link creation, but force removal enters recoverable trash. Multiple links are O(target count). Needs atomicity and rollback/oracle for partial failures.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because link semantics can leak host paths and hard links/symlinks interact directly with containment policy.
- **Closure status**:
  - **Implemented evidence**: current Swift supports `--`, `-s/--symbolic`, `-f/--force`, `-n/--no-dereference`, `-t/--target-directory`, `-T/--no-target-directory`, `-v/--verbose`, single-target default name, explicit two operands, and multiple targets into an existing directory; smoke/parity tests cover hard links, symlinks, force overwrite, missing targets, directory hard-link rejection, and readlink round trips; unit tests cover target-directory, no-target-directory, and verbose output; direct parity has hard and symbolic link behavior, and Core100 oracle fixtures contain 4 direct ln cases plus 11 generated/reference cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require prompt policy, backup naming, logical/physical dereference contracts, relative symlink canonicalization, data-loss prevention across multiple link targets, and shared fix for absolute virtual symlink physical-path storage.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented `-t/-T/-v`, absolute/relative symlink targets, forced overwrite trash diffs, `-n` with symlink-to-dir, multi-target partial failures, backup behavior, and host physical path leak inspection.
  - **Deferred/forbidden with reason**: directory hard-link options `-d/-F` should remain unavailable unless a virtual backend can model them safely; out-of-workspace links, hidden path links, and physical path exposure are forbidden.

## ls

- **Command**: `ls`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPLsCommand.swift` plus `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/Ls/`; command entry, options, listing/recursive collection, long-format rendering, and limited streaming paths are separate owners.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/ls.c`, `long_options`, `usage`, `decode_switches`, sort/format/color code.
- **GNU/Linux parameter surface**: very large GNU surface including `-a/-A`, `--author`, `-b`, `--block-size`, `-B`, `-c`, `-C`, `--color`, `-d`, `-D`, `-f`, `-F/--classify`, `--file-type`, `--format`, `--full-time`, `-g`, `--group-directories-first`, `-G`, `-h/--si`, `-H`, `--dereference-command-line-symlink-to-dir`, `--hide`, `--hyperlink`, `-i`, `-I`, `-k`, `-l`, `-L`, `-m`, `-n`, `-N`, `-o`, `-p`, `-q`, `--show-control-chars`, `-Q`, `--quoting-style`, `-r`, `-R`, `-s`, `-S`, `--sort`, `--time`, `--time-style`, `-t`, `-T`, `-u`, `-U`, `-v`, `-w`, `-x`, `-X`, `-Z`, `--zero`, `-1`, `--help`, `--version`.
- **Currently supported by MSP**: `-1`, `-R`, `-l`, `-a`, `-A`, `-d`, `-f`, `-h`, `-r`, `-t`, `-S`, `-U`; long `--all`, `--almost-all`, `--recursive`, `--directory`, `--human-readable`, `--reverse`, `--sort=time|size|name|none`, `--zero`. Long format is simplified relative to GNU but includes mode, link count, virtual owner/group, size, timestamp, and name; streaming is used only for safe single-directory cases without sort/long/reverse/directory-as-self.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: SELinux `-Z/--context`, terminal color, and OSC-8 hyperlinks can be deferred until the virtual terminal/product surface defines them; if accepted, they must be deterministic and sanitized.
- **Forbidden by policy**: revealing host owner/group/security context, physical paths, hidden trash storage, or following symlinks outside the workspace.
- **Performance model**: unsorted simple single-directory listings can stream; most options buffer groups/sections and sort arrays. Recursive buffered path builds strings recursively; streaming recursive path still holds one child-directory array per level. Needs output limits, cancellation, and cycle protection.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because `ls` is a common inspection command and current output is intentionally much simpler than GNU.
- **Closure status**:
  - **Implemented evidence**: current Swift supports buffered and limited streaming `ls` with `-1/-R/-l/-a/-A/-d/-f/-h/-r/-t/-S/-U/--zero` and selected long options; parity tests cover dotfiles, recursive headers, missing paths, simple sort/order, and no host path leakage; pipeline tests cover `ls -U | head` and recursive streaming; unit tests cover NUL-terminated `--zero` output; direct parity has `ls list`, and Core100 oracle fixtures contain 5 direct/generated cases plus a large-directory stress case.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require virtual owner/group/inode/block/time metadata, terminal/quoting/color policy, dereference contracts, column layout width policy, dired/hyperlink product decisions, and broader format/sort implementation.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented `--zero`, wide-directory order/sort, recursive broken pipe, symlink-to-dir dereference matrix, hidden path filtering, long format exactness, weird filenames/quoting, and multi-operand diagnostics.
  - **Deferred/forbidden with reason**: SELinux context, terminal color, and OSC-8 hyperlinks can wait for virtual terminal semantics; host owner/group/context, physical paths, hidden trash, and outside-workspace symlink following are forbidden.

## mkdir

- **Command**: `mkdir`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPMkdirCommand.swift`; calls `fileSystem.createDirectory` with `context.directoryCreationMode`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/mkdir.c`, `longopts`, `usage`, `main`.
- **GNU/Linux parameter surface**: `DIRECTORY...`; options `-m/--mode=MODE`, `-p/--parents`, `-v/--verbose`, `-Z/--context`, `--help`, `--version`.
- **Currently supported by MSP**: `-p/--parents`, `-m/--mode` with chmod-style symbolic/octal parsing through shared chmod mode support, and `-v/--verbose`; multiple operands; default creation mode from context/umask; existing directory with `-p` succeeds.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: SELinux/SMACK context can be deferred on virtual WorkspaceFS, but accepted context options must not silently mutate host labels.
- **Forbidden by policy**: creating hidden policy paths, escaping workspace via path normalization/symlink parents, and host security-context mutations.
- **Performance model**: O(number of path components) per operand; parent creation is iterative in backend. Needs path length/depth limits and cancellation for pathological operands.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: medium, because creation is simple but missing `-m` changes build-script behavior.
- **Closure status**:
  - **Implemented evidence**: current Swift parses `-p/--parents`, `-m/--mode`, and `-v/--verbose`, uses shared chmod-style mode parsing, and passes creation modes to WorkspaceFS; unit tests cover `-m 700`, verbose output, and existing-dir diagnostics; shell-state tests cover umask-created directory modes; direct parity has `mkdir -p made/sub`, and generated/reference fixtures include mkdir in many shell/setup cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items are exact GNU parent/intermediate mode rules under umask, help/version policy, and path-diagnostic parity; WorkspaceFS already owns creation and symlink-parent containment.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented verbose output, symbolic/octal `-m`, parent modes under umask, existing file/dir matrix, hidden path denial, very deep paths, and multi-operand failures.
  - **Deferred/forbidden with reason**: SELinux/SMACK context can wait for virtual label support; hidden policy paths, workspace escape through symlink parents, and host security-context mutation are forbidden.

## mktemp

- **Command**: `mktemp`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPMktempCommand.swift`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/mktemp.c`, `longopts`, `usage`, `main`.
- **GNU/Linux parameter surface**: optional `TEMPLATE`; default `tmp.XXXXXXXXXX` with `--tmpdir`; options `-d/--directory`, `-u/--dry-run`, `-q/--quiet`, `--suffix=SUFF`, `-p DIR/--tmpdir[=DIR]`, `-t`, undocumented `-V`, `--help`, `--version`. Template must contain at least three consecutive `X`s in the last component.
- **Currently supported by MSP**: `-d/--directory`, `-u/--dry-run`, `-q/--quiet`, `-p DIR`, `--tmpdir[=DIR]`, `--suffix=SUFF`, and `-t`; zero or one template; default template is `tmp.XXXXXXXXXX` placed in virtual `/tmp` or virtual `TMPDIR`; file mode `0600`, directory mode `0700`; tries 100 random candidates; validates at least three consecutive `X` before the suffix and rejects slash-containing suffixes.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: none for common mktemp options now parsed by MSP; dry-run remains policy-sensitive but is implemented as virtual name generation without filesystem mutation.
- **Forbidden by policy**: using host `/tmp`, returning host temp paths, creating outside WorkspaceFS, or exposing random physical directories.
- **Performance model**: O(100) bounded attempts today; no tree traversal. Collision-heavy directories need deterministic failure and no unbounded random loops.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: medium, because temp paths are security-sensitive and current default path differs from GNU's `/tmp` semantics by design.
- **Closure status**:
  - **Implemented evidence**: current Swift parses directory/dry-run/quiet/tmpdir/suffix/deprecated `-t`, honors virtual `TMPDIR`, validates X runs before suffix, and creates files or directories with fixed modes; WorkspaceFS parity tests cover too-few X, too many templates, relative file and directory creation; unit tests cover suffix append/rejection and dry-run no-create; direct parity has `mktemp case.XXXXXX`, and Core100 oracle fixtures contain 5 mktemp cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items are exact deprecated `-t` corner cases, umask-mode integration, collision exhaustion parity, and GNU diagnostic text; host `/tmp` behavior is forbidden and must stay virtualized.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: `--suffix`, default/tmpdir/TMPDIR matrix, slash templates, too-few-X edge cases, collision exhaustion, mode under umask, dry-run no-create proof, and hidden path denial.
  - **Deferred/forbidden with reason**: no common option should be marked deferred; host `/tmp`, host temp paths, out-of-workspace creation, and physical directory disclosure are forbidden.

## mv

- **Command**: `mv`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPMvCommand.swift`; delegates to `fileSystem.move`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/mv.c`, `long_options`, `usage`, `main`; shared move/copy behavior from `copy.c`.
- **GNU/Linux parameter surface**: forms `SOURCE DEST`, `SOURCE... DIRECTORY`, `-t DIRECTORY SOURCE...`; options `-b/--backup`, `-f`, `-i`, `-n`, `-t`, `-T`, `--strip-trailing-slashes`, `-S`, `-u`, `-v`, `-Z/--context`, `--help`, `--version`.
- **Currently supported by MSP**: `-f/--force`, `-n/--no-clobber`, `-t/--target-directory`, `-T/--no-target-directory`, `--strip-trailing-slashes`, and `-v/--verbose`; source(s) plus destination; multiple sources to existing directory; same-path check; directory over non-directory guard; move delegates with overwrite existing unless no-clobber wins.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: SELinux `-Z` can be deferred on non-Linux virtual backends.
- **Forbidden by policy**: moving into/out of hidden paths, moving workspace root, mutating host security labels, and leaking physical paths.
- **Performance model**: backend `FileManager.moveItem` is O(1) within a volume but may be expensive across volumes; overwrite first moves destination to trash, adding side effects. Needs cancellation/progress for cross-backend moves and rollback for partial multi-source moves.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because overwrite semantics can silently trash an existing destination and common safety flags are absent.
- **Closure status**:
  - **Implemented evidence**: current Swift supports force/no-clobber, target-directory, no-target-directory, verbose, multi-source-to-directory moves, same-path checks, directory-over-file guards, and WorkspaceFS move delegation; parity tests cover missing source, missing multi-target directory, directory-over-file, same-file, and simple rename; unit tests cover `-t`, `-T`, `-n`, and `-v`; direct parity has `mv old.txt new.txt`, and Core100 oracle fixtures contain 4 mv cases including no-clobber.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require prompt policy, update timestamp comparison, backup naming, symlink/directory/trailing-slash backend contracts, cross-device fallback policy, and rollback semantics over WorkspaceFS moves.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented `-t/-T/-v`, overwrite/trash side effects, no-clobber/update/backup, symlink source/destination, multi-source partial failure, trailing slash, hidden path, and large tree/cross-directory moves.
  - **Deferred/forbidden with reason**: SELinux context can wait for virtual labels; moving hidden paths, workspace root, host labels, or physical path exposure is forbidden.

## rm

- **Command**: `rm`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPRmCommand.swift`; calls `fileSystem.remove`. Real safety boundary is WorkspaceFS trash in `MSPAppleWorkspace.swift`/`MSPWorkspaceTrash.swift`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/rm.c`, `long_opts`, `usage`, `main`; remove engine in `remove.c` and `remove.h`.
- **GNU/Linux parameter surface**: `FILE...`; options `-f`, `-i`, `-I`, `--interactive[=never|once|always]`, `--one-file-system`, `--no-preserve-root`, `--preserve-root[=all]`, `-r/-R/--recursive`, `-d/--dir`, `-v`, `--help`, `--version`.
- **Currently supported by MSP**: `-r`, `-R`, `--recursive`, `-f`, `--force`, `-d/--dir`, and `-v/--verbose`; missing operand suppressed by force; `-d` removes only empty directories after an emptiness check; non-recursive directory removal without `-d` fails through backend; actual removal is recoverable trash when Apple WorkspaceFS trash is configured.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: interactive prompting can be deferred until the command runner has a user-confirmation channel, but options must not be silently accepted with wrong behavior.
- **Forbidden by policy**: physical hard delete by default, `rm -rf /` against host/device root, deleting hidden trash storage, crossing workspace roots, and command-visible empty-trash without explicit host/user authorization.
- **Performance model**: command loops operands; backend moves each removed item to trash. Recursive delete cost is whole subtree move/metadata record. Needs cancellation, traversal limits, and bounded trash-record writes for large trees.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because deletion is policy-critical and GNU hard-delete semantics intentionally diverge from MSP recoverable delete.
- **Closure status**:
  - **Implemented evidence**: current Swift parses `-r/-R/--recursive`, `-f/--force`, `-d/--dir`, and `-v/--verbose`, suppresses missing operands/missing paths under force, checks empty directories for `-d`, and routes removal to WorkspaceFS; WorkspaceFS parity tests cover missing operands, missing path, non-recursive directory refusal, file removal, and recursive removal; unit tests cover `-d` and verbose success; direct parity has `rm remove.txt`, and Core100 oracle fixtures contain 4 rm cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require prompt policy, virtual device/xdev metadata, root-preserve policy over WorkspaceFS roots, trash-disabled behavior, and recursive side-effect accounting; physical hard delete remains forbidden.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: `-d/-v`, large recursive tree, force missing, root-preserve, interactive contracts, symlink recursion, hidden paths, trash record/diff capture, and physical path leak scan.
  - **Deferred/forbidden with reason**: interactive prompting can wait for a user-confirmation channel but accepted options must not silently misbehave; physical hard delete by default, host/device root deletion, hidden trash deletion, cross-root deletion, and command-visible empty-trash without explicit authorization are forbidden.

## rmdir

- **Command**: `rmdir`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPRmdirCommand.swift`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/rmdir.c`, `longopts`, `usage`, `main`.
- **GNU/Linux parameter surface**: `DIRECTORY...`; options `--ignore-fail-on-non-empty`, `-p/--parents` plus deprecated `--path`, `-v/--verbose`, `--help`, `--version`.
- **Currently supported by MSP**: `-p/--parents`, deprecated `--path`, `-v/--verbose`, `--ignore-fail-on-non-empty`, and `--` terminator; verifies target is directory and empty before `fileSystem.remove`.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: none for common surface; deprecated `--path` is small and should not be deferred.
- **Forbidden by policy**: removing hidden trash/storage roots, physical directory deletion outside workspace, and leaking host paths.
- **Performance model**: current emptiness check calls `listDirectory`, materializing one directory. `-p` walks parents one by one. Wide non-empty directories can be expensive just to prove non-empty; should have an early-exit empty check.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: medium, because the option surface is small but removal still routes through recoverable trash and hidden policy.
- **Closure status**:
  - **Implemented evidence**: current Swift supports `--`, `-p/--parents`, deprecated `--path`, `-v/--verbose`, and `--ignore-fail-on-non-empty`, validates directory emptiness before WorkspaceFS removal, and emits GNU-like diagnostics; unit tests cover empty/non-empty removal and `--path` parent removal; direct parity has `rmdir empty-dir`, and Core100 oracle fixtures contain 12 rmdir cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items are exact GNU verbose/parent diagnostic text, help/version policy, root/hidden refusal verification, and coordinating-agent decision on recoverable-trash side effects for empty-directory removal.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: `--path`, non-empty ignore matrix, parent partial failure, hidden/root paths, verbose output, very wide non-empty early-exit behavior, and trash side-effect capture.
  - **Deferred/forbidden with reason**: no common rmdir surface should be deferred; hidden trash/storage roots, physical removal outside workspace, and host path leakage are forbidden.

## touch

- **Command**: `touch`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPTouchCommand.swift`; calls `fileSystem.touch`.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/touch.c`, `longopts`, `usage`, `main`.
- **GNU/Linux parameter surface**: `FILE...`; special `FILE` value `-` changes stdout's file; options `-a`, `-c/--no-create`, `-d/--date=STRING`, ignored `-f`, `-h/--no-dereference`, `-m`, `-r/--reference=FILE`, `-t STAMP`, `--time=WORD`, `--help`, `--version`.
- **Currently supported by MSP**: `-c/--no-create`; parses `-a`, `-m`, ignored `-f`, `-h/--no-dereference`, `-d/--date`, `-r/--reference`, `-t`, and `--time`; creates empty files with context regular-file mode or updates timestamps through WorkspaceFS; `-d` only accepts `@SECONDS` and `now`, `-t` accepts a strict UTC `YYYYMMDDhhmm[.ss]`, and reference/date updates only modify mtime through a physical-path-backed WorkspaceFS.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: symlink timestamp mutation can be deferred on backends without `lutimes`, but `-h` must not silently touch the referent.
- **Forbidden by policy**: touching hidden policy paths, host stdout file descriptors outside WorkspaceFS, or leaking physical paths.
- **Performance model**: O(number of operands), no data reads. Timestamp parsing is CPU-small but must be bounded for arbitrary date strings.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: medium, because build systems depend on timestamp semantics and current support is only create/update-now.
- **Closure status**:
  - **Implemented evidence**: current Swift parses the common timestamp flags listed above, implements no-create, limited date/reference/timestamp mtime updates, and file creation through WorkspaceFS; parity tests cover missing operand, no-create missing, missing parent, and created files; direct parity has `touch touched.txt`, and Core100 oracle fixtures contain 4 direct touch cases plus 9 generated/reference cases including date/reference.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require WorkspaceFS atime/mtime/lutimes APIs, full GNU date parser, stdout-file special handling, timestamp precision/time-zone policy, and conflict diagnostics; `-h` must not silently mutate host referents.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: date/reference/atime/mtime matrix, symlink no-deref, no-create missing, special `-`, precision, multiple failures, hidden paths, and created-file modes under umask.
  - **Deferred/forbidden with reason**: symlink timestamp mutation may wait for backend `lutimes`-like support but `-h` must not be silently wrong; hidden paths, host stdout file descriptors, and physical path leakage are forbidden.

## tree

- **Command**: `tree`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPTreeCommand.swift`; streaming render with recursive directory traversal.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/tree-2.1.0/tree.c`, `main`, manual option parser, `usage`; traversal/render helpers in `file.c`, `list.c`, `unix.c`, `filter.c`, `json.c`, `xml.c`, `html.c`.
- **GNU/Linux parameter surface**: operands `[directory ...]`; listing options `-a`, `-d`, `-l`, `-f`, `-x`, `-L`, `-R`, `-P`, `-I`, `--gitignore`, `--gitfile`, `--ignore-case`, `--matchdirs`, `--metafirst`, `--prune`, `--info`, `--infofile`, `--noreport`, `--charset`, `--filelimit`, `-o`; file options `-q`, `-N`, `-Q`, `-p`, `-u`, `-g`, `-s`, `-h`, `--si`, `--du`, `-D`, `--timefmt`, `-F`, `--inodes`, `--device`; sorting `-v`, `-t`, `-c`, `-U`, `-r`, `--dirsfirst`, `--filesfirst`, `--sort`; graphics `-i`, `-A`, `-S`, `-n`, `-C`; XML/HTML/JSON `-X`, `-J`, `-H`, `-T`, `--nolinks`, `--hintro`, `--houtro`; input `--fromfile`, `--fflinks`; `--help`, `--version`.
- **Currently supported by MSP**: `-a`, `-d`, `-f`, `-i`, `-L`, `-P`, `-I`, `-o`, `--noreport`, `--charset`, and multiple operands; ASCII charset recognized specially, other values map to Unicode. It sorts names ascending, shows symlink target text, counts symlink-to-dir as directory-like, can write output through WorkspaceFS, and does not emit metadata columns or alternate formats.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: HTML hyperlink customization, `.gitignore` parsing, and `--info` files are complex but common enough to remain debt; they may be staged after core traversal/sort/output parity. Device/inode metadata can wait for virtual metadata.
- **Forbidden by policy**: writing `-o` outside WorkspaceFS, reading arbitrary host git/info files, following symlinks outside workspace, and exposing physical link targets.
- **Performance model**: current renderer streams text but materializes one directory level, filters/sorts it, and recurses. Reference `tree` documents `--prune`/`--du` as whole-tree memory consumers; MSP must set explicit limits before adding them.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because the visible command exists but covers a small fraction of tree's option and output formats.
- **Closure status**:
  - **Implemented evidence**: current Swift streams traversal, supports `-a/-d/-f/-i/-L/-P/-I/-o/--noreport/--charset` and multiple operands, renders symlink targets, sorts ascending, writes `-o` output through WorkspaceFS, and avoids eager `listDirectory` in the tested path; unit tests cover default tree output, invalid option usage, multiple roots, no-report, and output-file writes; direct parity has `tree --charset ascii`, and Core100 oracle fixtures contain 14 tree cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require symlink-follow/xdev traversal policy, virtual metadata columns, sort/prune/filelimit algorithms, gitignore/info file policy, alternate format renderers, fromfile input, terminal color/graphics policy, and exact report-count oracle.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented multiple roots, `-o`, `--noreport`, symlink-follow loops, prune/filelimit, huge wide/deep trees, `--du` memory, alternate formats, metadata columns, pattern slash/case behavior, fromfile, and hidden path leakage.
  - **Deferred/forbidden with reason**: HTML customization, gitignore/info parsing, and inode/device metadata can stage after core traversal parity; writing outside WorkspaceFS, reading host git/info files, following symlinks outside workspace, and physical link targets are forbidden.

## truncate

- **Command**: `truncate`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPTruncateCommand.swift`; whole-file read/range/write implementation.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/truncate.c`, `longopts`, `usage`, `main`, `do_ftruncate`.
- **GNU/Linux parameter surface**: `OPTION... FILE...`; options `-c/--no-create`, `-o/--io-blocks`, `-r/--reference=RFILE`, `-s/--size=SIZE`, `--help`, `--version`; size modifiers `+`, `-`, `<`, `>`, `/`, `%`; size suffixes include GNU size syntax such as `K`, `M`, `G`, `T`, `P`, `E`, `Z`, `Y`, `b`, and block-size forms.
- **Currently supported by MSP**: `-c`, `-o`, `-r`, `-s` and long equivalents; absolute size, `+` relative grow, `-` relative shrink, `<` at most, `>` at least, `/` round down, `%` round up; suffixes through `E`/`EiB` where they fit `Int64`; reference size requires a relative size when combined; no-create skip; creates missing files; hard cap at 64 MiB.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: physical sparse allocation parity can be deferred until WorkspaceFS has sparse-file metadata; byte reads must still return zeros without materializing unbounded data.
- **Forbidden by policy**: truncating hidden paths, host files outside workspace, or huge files beyond configured safe limits without explicit capability.
- **Performance model**: current implementation materializes up to target size in memory and writes the whole file, capped at 64 MiB. GNU `ftruncate` is metadata-oriented and can create sparse holes. Needs sparse/streaming backend API and cancellation for large files.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: high, because current behavior can only emulate small files and diverges sharply from GNU sparse/large-file semantics.
- **Closure status**:
  - **Implemented evidence**: current Swift parses `-c/-o/-r/-s` and long equivalents, supports absolute size plus `+/-/</>///%` relative modes, `K/M/G/T/P/E` binary suffix family where representable, reference-relative validation, no-create skip, create missing, zero-fill grow, and the 64 MiB materialization cap; unit tests cover shrink/grow/no-create and the new relative limit/rounding modes; direct parity has `truncate -s 5`, and Core100 oracle fixtures contain 14 truncate cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require sparse-file/large-file backend APIs, special-file type diagnostics, full GNU suffix overflow grammar, and standard help/version policy; current command intentionally caps materialization for safety.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: newly implemented relative modifiers/suffixes, sparse grow readback, large file cap, suffix matrix, reference conflicts, no-create missing versus missing parent, directory errors, hidden paths, and binary zero-fill checks.
  - **Deferred/forbidden with reason**: physical sparse allocation can wait for sparse-file metadata/API support, but reads must remain deterministic; hidden paths, host files outside workspace, and huge-file mutation beyond configured caps are forbidden.

## unlink

- **Command**: `unlink`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Filesystem/MSPUnlinkCommand.swift`; calls `fileSystem.remove(... recursive: false)` after rejecting directories.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/unlink.c`, `usage`, `main`, `parse_gnu_standard_options_only`, `unlink(2)` call.
- **GNU/Linux parameter surface**: `unlink FILE`; standard `--help`/`--version`; exactly one operand; no recursive/force behavior.
- **Currently supported by MSP**: `--help`, `--version`, exactly one operand, `--` terminator, directory rejection, WorkspaceFS non-recursive remove; extra/missing operand diagnostics.
- **Must implement**: None for command-local scope after this batch; validated local additions are recorded in Closure status and non-local capabilities are classified under Deferred with reason.
- **Deferred with reason**: none for the small GNU surface.
- **Forbidden by policy**: physical hard delete by default, unlinking hidden policy/trash storage, unlinking outside workspace, or leaking host paths.
- **Performance model**: O(1) command operation; backend trash move may be O(file metadata/record write). Needs atomic trash record and bounded failure behavior.
- **Oracle/stress gaps**: None for child-owned fixture changes; capture cases that require centralized safety review are listed under Closure status.
- **Risk**: medium, because the option surface is small but removal semantics intentionally differ from GNU hard unlink.
- **Closure status**:
  - **Implemented evidence**: current Swift supports `--`, exactly one operand, extra/missing operand diagnostics, directory rejection, symlink-self removal, and WorkspaceFS non-recursive remove; unit tests cover symlink-self removal and directory rejection, direct parity has `unlink f.txt`, and Core100 oracle fixtures contain 8 unlink cases.
  - **Implementation closure / hard deferred**: child-owned marker closed. Remaining items require standard help/version policy, virtual hard-link identity, and coordinating-agent confirmation that recoverable WorkspaceFS remove is the unlink contract; physical hard unlink remains forbidden by product policy.
  - **Oracle/stress closure / coordinated capture**: worker cannot promote oracle fixtures. Coordinated capture draft: symlink operand, hard-linked file, directory/missing errors, leading dash via `--`, hidden path, trash record/diff capture, and physical path leak scan.
  - **Deferred/forbidden with reason**: no common unlink surface should be deferred; physical hard delete by default, hidden policy/trash storage unlink, outside-workspace unlink, and host path leakage are forbidden.
