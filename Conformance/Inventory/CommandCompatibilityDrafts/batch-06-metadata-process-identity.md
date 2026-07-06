# Batch 06: Metadata, Process, Identity

Source-backed compatibility matrix for: `file`, `groups`, `hostname`, `id`, `ldd`, `nproc`, `pathchk`, `ps`, `readlink`, `realpath`, `sleep`, `stat`, `timeout`, `tty`, `uname`, `whoami`.

Evidence baseline: command names/status are from `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`; current MSP ownership is in `Implementations/Swift/Sources/MSPPOSIXCore/Commands/{Metadata,Process,Path,Utility}` plus `MSPPOSIXCoreCommandPack`; shell execution context is in `Implementations/Swift/Sources/ModelShellProxy`; vendored Debian source checked under `References/LinuxSourceSnapshot/debian12-bookworm/sources/{coreutils-9.1,bash-5.2.15,dash-0.5.12,file-5.44,glibc-2.36,procps-ng-4.0.2,hostname-3.23+nmu1}`.

## file

- **Command**: `file`
- **MSP implementation**: `Implementations/Swift/Sources/MSPPOSIXCore/Commands/Metadata/MSPFileCommand.swift` lines 4-222; registered in `MSPPOSIXCoreCommandPack.swift` line 34.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/file-5.44/src/file.c`, option table included from `src/file_opts.h`, and libmagic engine helpers under `file-5.44/src/`; relevant entry points are `main`, `load`, `unwrap`, `process`, `setparam`, and `applyparam`.
- **GNU/Linux parameter surface**: Source surface is `file [-bcCdE...iklLmnNpPrsSvzZ0] [--apple] [--extension] [--mime-type] [--mime-encoding] [-e TEST] [--exclude-quiet TEST] [-F SEPARATOR] [-f NAMEFILE] [-m MAGICFILES] [-P PARAMETER=VALUE] FILE...`, plus `file -C [-m MAGICFILES]`, `file [--help]`, and `-v/--version`. Short/long option pairs from `file_opts.h`: `-b/--brief`, `-c/--checking-printout`, `-C/--compile`, `-d/--debug`, `-e/--exclude`, `-E`, `-f/--files-from`, `-F/--separator`, `-h/--no-dereference`, `-i/--mime`, `-k/--keep-going`, `-L/--dereference`, `-l/--list`, `-m/--magic-file`, `-n/--no-buffer`, `-N/--no-pad`, `-0/--print0`, `-p/--preserve-date`, `-P/--parameter`, `-r/--raw`, `-s/--special-files`, `-S/--no-sandbox`, `-z/--uncompress`, `-Z/--uncompress-noreport`, plus long-only `--apple`, `--extension`, `--mime-type`, `--mime-encoding`, `--exclude-quiet`, and `--help`. `-e/--exclude` test names are `apptype`, `ascii`/`text`, `cdf`, `compress`, `csv`, `elf`, `encoding`, `soft`, `tar`, `json`, and obsolete ignored `tokens`; `-P` parameters are `bytes`, `elf_notes`, `elf_phnum`, `elf_shnum`, `encoding`, `indir`, `name`, and `regex`.
- **Currently supported by MSP**: Accepts operands, `--help`, `-v/--version`, `-b/--brief`, `-i/--mime`, `--mime-type`, `--mime-encoding`, `-f/--files-from`, `-F/--separator`, `-0/--print0`, stdin operand `-`, `-e/--exclude` validation, `-P bytes=N`, and source-shaped no-op parsing for safe formatting/probing flags. Policy/data features such as `-c/-C/-l/-m`, `--apple`, and `--extension` fail with explicit MSP virtual-classifier diagnostics. It stats WorkspaceFS entries, treats directories and symlinks as their own types, reads a bounded range for regular files, and hand-classifies empty, PDF, JPEG, zip/docx, MP4, WebVTT, SRT-like text, ASCII/UTF-8 text, NUL data, and generic short/binary data. Missing paths are printed on stdout with exit 0, matching current fixture behavior.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Full obscure libmagic database parity, `--apple`, `--extension`, and magic authoring actions `-c/-C/-l` may be staged because they are large and data-driven; if implemented, they must operate only on bundled or workspace-approved magic files and preserve the same MSP data limits.
- **Forbidden by policy**: Probing real host devices/block/char files via `-s/--special-files`; resolving outside WorkspaceFS; implicitly reading host `/usr/share/file/magic` or user `~/.magic`; spawning host decompression helpers or executing/loading host/workspace binaries for classification; honoring `-S/--no-sandbox` as a way to disable MSP safety.
- **Performance model**: Current implementation is O(operands * min(size, 4096)) and eager per operand. Libmagic parity must remain bounded by explicit byte/encoding/regex/indir/name/ELF limits, stream only where a magic rule requires it, cap decompression expansion, and be cancellable for large or adversarial files.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because the command is marked implemented while the real source surface is libmagic-driven and the current MSP classifier is intentionally tiny.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPFileCommand.swift` now accepts the source-shaped common parser surface for `--help`, `-v/--version`, `--mime-encoding`, `-f/--files-from`, `-F/--separator`, `-0/--print0`, `-N/--no-pad`, `-n/--no-buffer`, `-r/--raw`, `-k/--keep-going`, `-e/--exclude`, `-P bytes=N`, stdin operand `-`, and policy/data options; it keeps bounded WorkspaceFS-only classification. `MSPDataComparisonMetadataOracleTests.testMetadataCommandsMatchStableGNUOracle` covers help-adjacent parser behavior, MIME encoding, files-from, stdin, separator, print0, bounded probing, invalid excludes, unsupported compile/list/magic actions, and virtual no-host behavior; existing Core100 oracle cases still cover text, binary, directory, and missing-path baseline behavior.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: full obscure libmagic database parity, `--apple`, `--extension`, custom magic DB loading, archive decompression, and authoring/listing actions `-c/-C/-l` require a bundled/workspace-only magic database and safety policy, so they are deferred to parent approval; probing host special files, reading host magic databases, escaping WorkspaceFS, spawning helpers, or treating `-S/--no-sandbox` as disabling MSP safety is forbidden.

## groups

- **Command**: `groups`
- **MSP implementation**: `MSPPOSIXVirtualIdentity.swift` lines 1-48 and `MSPGroupsCommand.swift` lines 3-64; registered in `MSPPOSIXCoreCommandPack.swift` line 46.
- **Reference source**: `coreutils-9.1/src/groups.c`, `main` and `usage`; uses `getuid`, `getgid`, `getegid`, `getpwnam`, and `print_group_list`.
- **GNU/Linux parameter surface**: `[OPTION]... [USERNAME]...`; long options are only GNU standard `--help` and `--version`; no short command-specific options.
- **Currently supported by MSP**: No operands prints virtual current group `nogroup`; operands resolve virtual login names `nobody` and `root`, printing `USER : GROUP`; numeric-looking operands are treated as login names and rejected unless such a login exists; unknown user returns exit 1; `--help`, `--version`, and `--` are supported.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Supplementary groups beyond one primary virtual group can wait until MSP has a richer virtual passwd/group database, but the database shape must be explicit before public release.
- **Forbidden by policy**: Reading host `/etc/group`, macOS Directory Services, or actual process group memberships.
- **Performance model**: O(number of operands) in a tiny virtual identity table; future richer identity DB remains bounded and in-memory.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because the identity boundary is safe but option and user-database parity are incomplete.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPGroupsCommand.swift` is registered, uses `MSPPOSIXVirtualIdentity`, supports no-operand current group, virtual `root`/`nobody` login-name lookup, `--`, `--help`, and `--version`, and rejects numeric-looking names (`0`, `65534`) as usernames. Direct fixture `groups root nobody missing-user`, Core100 cases `core100-required-groups-current` and `core100-required-groups-root-nobody-missing`, and `MSPWorkerFIdentityEncodingDigestTests.testIdentityCommandsExposeGNUHelpVersionAndVirtualLookupBoundaries` cover the virtual identity boundary.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: supplementary groups beyond the current primary virtual group are deferred until the parent defines a richer virtual passwd/group DB; reading host `/etc/group`, Directory Services, or real process group memberships remains forbidden.

## hostname

- **Command**: `hostname`
- **MSP implementation**: `MSPPOSIXVirtualIdentity.swift` lines 1-5 and `MSPHostnameCommand.swift` lines 3-138; registered in `MSPPOSIXCoreCommandPack.swift` line 47.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/hostname-3.23+nmu1/hostname.c`; relevant entry points are `main`, `show_name`, `set_name`, `read_file`, `localhost`, `localdomain`, and `localnisdomain`.
- **GNU/Linux parameter surface**: Source surface is `hostname [-b] {hostname|-F file}`, `hostname [-a|-A|-d|-f|-i|-I|-s|-y]`, bare `hostname`, `hostname -V|--version|-h|--help`, plus program-name aliases `dnsdomainname`, `domainname`, `ypdomainname`, and `nisdomainname`. Long options are `--domain`, `--boot`, `--file FILE`, `--fqdn`, `--all-fqdns`, `--help`, `--long`, `--short`, `--version`, `--alias`, `--ip-address`, `--all-ip-addresses`, `--nis`, and `--yp`; short parser is `aAdfbF:h?iIsVy`. Query paths call `gethostname`, `getdomainname`, `getaddrinfo`, `gethostbyname`, and `getifaddrs`; setter paths validate RFC-style names, read `-F` files, then call `sethostname` or `setdomainname`.
- **Currently supported by MSP**: Returns virtual `happy-swan-1.localdomain`; `-s` returns `happy-swan-1`; `-d` returns `localdomain`; `-f`/`--fqdn`/`--long` return full virtual hostname; alias/IP/NIS query options return a blank line; `-b`, `-F`, and operands fail with "changing host name is not supported"; `-h/--help` and `-V/--version` are implemented.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Rich multi-interface DNS/NIS simulation can wait until MSP has a virtual network profile with aliases and interface inventory; default/short/domain/FQDN and deterministic policy-denied setter behavior are not deferred.
- **Forbidden by policy**: Calling `sethostname`/`setdomainname`; reading host DNS, `/etc/hosts`, NIS, resolver state, `getifaddrs`, or real network interfaces; exposing macOS/iOS device names or current hostnames; treating `-F` as permission to change global host identity.
- **Performance model**: O(1) virtual identity lookup.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because hostname is a visible identity surface and the source-backed query/setter split must be virtualized exactly without host network leakage.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPHostnameCommand.swift` is registered, returns values from `MSPPOSIXVirtualIdentity.profile`, implements `-s`, `-f/--fqdn/--long`, `-d/--domain`, empty alias/IP/NIS query forms, `-h/--help`, `-V/--version`, and policy-denies setter-shaped operands, `-b`, `-F`, `--file`, and `--file=...`; Core100 covers default, short, FQDN, domain, invalid option, and help slice, and `MSPWorkerFIdentityEncodingDigestTests` covers the short virtual host.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: rich multi-interface DNS/NIS simulation and program-name alias registration are deferred until the parent defines a virtual network/interface profile and registry alias policy; calling host setters or reading host DNS, `/etc/hosts`, resolver state, NIS, `getifaddrs`, real interfaces, or device hostnames is forbidden.

## id

- **Command**: `id`
- **MSP implementation**: `MSPPOSIXVirtualIdentity.swift` lines 1-48 and `MSPIdCommand.swift` lines 3-167; registered in `MSPPOSIXCoreCommandPack.swift` line 48.
- **Reference source**: `coreutils-9.1/src/id.c`, option table and `main`; uses `getuid/geteuid/getgid/getegid`, passwd/group lookup, SELinux/SMACK context, and group-list expansion.
- **GNU/Linux parameter surface**: `id [OPTION]... [USER]...`; `-a`, `-Z/--context`, `-g/--group`, `-G/--groups`, `-n/--name`, `-r/--real`, `-u/--user`, `-z/--zero`, `--help`, `--version`.
- **Currently supported by MSP**: Virtual current user is `nobody` uid/gid 65534 group `nogroup`; virtual root also exists; supports `-a`, `-Z`, `-g`, `-G`, `-n`, `-r`, `-u`, `-z`, long equivalents, `--help`, `--version`, `--`, name lookup, and numeric uid lookup for `id`; `-Z` always fails as non-SELinux; validates incompatible only-mode/default-format combinations.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: SELinux/SMACK context output is deferred because MSP has no virtual security-label model; failure for `-Z` is acceptable and must remain source-matched for a non-SELinux virtual kernel.
- **Forbidden by policy**: Reading host uid/gid/group database or security labels; exposing macOS account names.
- **Performance model**: O(users * groups) over a tiny virtual DB; no file-system traversal.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because core identity is virtualized but group-list and option parity are thin.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPIdCommand.swift` is registered, uses `MSPPOSIXVirtualIdentity`, supports `-a`, `-Z`, `-g`, `-G`, `-n`, `-r`, `-u`, `-z`, long forms including `--help` and `--version`, multi-user output, virtual root/current lookup by name or uid string, and non-SELinux `-Z` failure. Direct fixtures and Core100 cases cover the existing identity matrix, and `MSPWorkerFIdentityEncodingDigestTests` now covers version, numeric root lookup, and consistency with `whoami`/`uname`.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: supplementary groups beyond the current primary group and SELinux/SMACK context output are deferred until virtual group/security-label models exist; reading host uid/gid/group/security-label state or macOS account names is forbidden.

## ldd

- **Command**: `ldd`
- **MSP implementation**: `MSPProcessMetadataCommands.swift` lines 101-149; registered in `MSPPOSIXCoreCommandPack.swift` line 51.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/glibc-2.36/elf/ldd.bash.in`; relevant parser/runner blocks are the top-level option loop, `try_trace`, and the per-file loop.
- **GNU/Linux parameter surface**: Source surface is `ldd [OPTION]... FILE...` with `--help`, `--version`, `-d/--data-relocs`, `-r/--function-relocs`, `-u/--unused`, `-v/--verbose`, and `--` to end option parsing. The script accepts abbreviated long forms shown in source (`--vers...--version`, `--h...--help`, prefixes for `--data-relocs`, `--function-relocs`, `--unused`, `--verbose`) and treats `--v`, `--ve`, and `--ver` as ambiguous. Runtime behavior sets `LD_TRACE_LOADED_OBJECTS=1` plus `LD_WARN`, `LD_BIND_NOW`, `LD_VERBOSE`, optional `LD_DEBUG=unused`, probes each `RTLDLIST` dynamic linker with `--version` and `--verify`, then invokes the selected loader through `try_trace`.
- **Currently supported by MSP**: `--help`, accepted help/version abbreviations, `--version`, `--`, `-d/-r/-u/-v` and accepted long prefixes are parsed; ambiguous `--v/--ve/--ver` and unknown options are diagnosed. With file operands, MSP stats WorkspaceFS paths, reports directories as `not regular file`, reports every regular file as `not a dynamic executable`, and prefixes relative missing paths with `./`.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Exact relocation/bind-now/unused-dependency diagnostics are deferred because glibc obtains them by executing a dynamic loader against the target; MSP may not do that. Static dependency extraction and all option/error semantics are not deferred.
- **Forbidden by policy**: Executing workspace binaries; invoking host or bundled dynamic linkers as loaders; using `LD_TRACE_LOADED_OBJECTS`, `LD_DEBUG`, `LD_WARN`, or `LD_BIND_NOW` to run real code; reading host `/lib`, `/proc`, loader cache, or macOS dylib state; resolving dependencies outside WorkspaceFS or an explicit virtual Linux sysroot.
- **Performance model**: Current model is O(operands) stat plus no content parse. Safe ELF parsing should be O(header + program headers + dynamic string tables actually referenced), with bounded seeks/reads, integer-overflow checks, malformed-file caps, and cancellation.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because the real source implements `ldd` by running the dynamic loader, which is exactly the behavior MSP must forbid while still providing useful static ELF parity.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPLddCommand` in `MSPProcessMetadataCommands.swift` is registered and now implements the safe source-shaped parser for `--help`, version/help abbreviations, `--`, `-d/-r/-u/-v` and their long prefixes, ambiguity diagnostics for `--v/--ve/--ver`, unknown options, missing operands, WorkspaceFS stat checks, directory diagnostics, missing-file diagnostics, and "not a dynamic executable" for regular files. Direct/Core100 baseline plus `MSPWorkerFMiscProcessNumericSearchTests.testPsTimeoutAndLddMatchStableGNUOracleCases` cover help, abbreviations, ambiguity, accepted options, version, missing, directory, and non-ELF behavior.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: exact dynamic dependency listing, relocation/bind-now checks, unused dependency analysis, and loader-cache/sysroot resolution are deferred until parent approves a bounded static ELF reader and virtual sysroot contract; executing workspace binaries, invoking loaders, using LD_TRACE/LD_DEBUG to run code, reading host `/lib`/`/proc`/loader cache, or resolving dependencies outside WorkspaceFS/explicit virtual sysroot is forbidden.

## nproc

- **Command**: `nproc`
- **MSP implementation**: `MSPPOSIXVirtualIdentity.swift` line 5 and `MSPNprocCommand.swift` lines 4-80; registered in `MSPPOSIXCoreCommandPack.swift` line 55.
- **Reference source**: `coreutils-9.1/src/nproc.c`, option table and `main`; uses `num_processors` with current/installed query mode and `--ignore`.
- **GNU/Linux parameter surface**: `nproc [OPTION]...`; `--all`, `--ignore=N`, `--help`, `--version`; no operands.
- **Currently supported by MSP**: Returns virtual processor count `3` from `MSPPOSIXVirtualIdentity.profile`; supports `--all`, `--ignore N`, `--ignore=N`, `--help`, `--version`, and `--`; clamps below 1; rejects operands and unknown options.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Modeling cgroup/cpuset differences between available and installed processors is deferred until MSP has virtual resource limits; both modes can intentionally return the same virtual count for now.
- **Forbidden by policy**: Reading actual host CPU count or iOS/macOS hardware details by default.
- **Performance model**: O(1).
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because the virtual boundary is clear but hardcoded and under-covered.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPNprocCommand.swift` is registered, returns `MSPPOSIXVirtualIdentity.profile.processorCount` (`3`), supports `--all`, `--ignore N`, `--ignore=N`, `--`, `--help`, `--version`, large-ignore clamping to `1`, extra operand diagnostics, and invalid ignore diagnostics; direct/Core100 cases plus `MSPCore100ExtraCommandTests.testEnvironmentIdentityProcessAndPathUtilitiesMatchStableOracleCases` cover current behavior and help/version.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: cgroup/cpuset distinction between installed and available processors is deferred until virtual resource limits exist; reading actual host CPU count or hardware details is forbidden by default.

## pathchk

- **Command**: `pathchk`
- **MSP implementation**: `MSPPathchkCommand.swift` lines 4-120; registered in `MSPPOSIXCoreCommandPack.swift` line 58.
- **Reference source**: `coreutils-9.1/src/pathchk.c`, option table, `main`, and `validate_file_name`.
- **GNU/Linux parameter surface**: `pathchk [OPTION]... NAME...`; `-p`, `-P`, `--portability`, `--help`, `--version`.
- **Currently supported by MSP**: Supports `-p`, `-P`, `--portability`, `--help`, `--version`, `--`, operands, portable-character check, POSIX path length 255/256 check, POSIX component length 14 check, empty path checks, leading-hyphen component check, and default-mode virtual checks for invalid paths and non-directory existing parent components.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Host filesystem `pathconf` parity is not applicable directly; a virtual WorkspaceFS limit model can stand in and should be explicit.
- **Forbidden by policy**: Calling host `pathconf` on real workspace backing paths in a way that leaks host filesystem details.
- **Performance model**: O(path length * operands), no IO today except future virtual parent checks.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because common options exist but default-mode semantics are too shallow.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPPathchkCommand.swift` is registered, supports `-p`, `-P`, `--portability`, `--`, `--help`, `--version`, empty-path diagnostics, POSIX portable character checks, path/component length checks, and leading-hyphen component checks; direct/Core100 cases plus `MSPCore100ExtraCommandTests.testEnvironmentIdentityProcessAndPathUtilitiesMatchStableOracleCases` cover the current parser surface and help/version.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: source-exact default-mode `pathconf` and directory-searchability behavior is deferred until parent defines explicit WorkspaceFS path/name limits and parent-directory accessibility semantics; calling host `pathconf` on backing paths in a way that leaks filesystem details is forbidden.

## ps

- **Command**: `ps`
- **MSP implementation**: `MSPProcessMetadataCommands.swift` lines 4-99; registered in `MSPPOSIXCoreCommandPack.swift` line 61.
- **Reference source**: `References/LinuxSourceSnapshot/debian12-bookworm/sources/procps-ng-4.0.2/src/ps/parser.c`, `display.c`, and `output.c`; relevant source owners are `arg_parse`, `parse_sysv_option`, `parse_bsd_option`, `parse_gnu_option`, `parse_trailing_pids`, `simple_spew`, `fancy_spew`, `arg_check_conflicts`, `show_one_proc`, `format_array`, and `macro_array`.
- **GNU/Linux parameter surface**: Procps-ng parses three forms. SysV/Unix98 dashed options include `-A`, `-C CMDLIST`, `-F`, `-G GROUPLIST`, `-H`, `-L`, `-M`, `-N`, `-O FORMAT`, `-P`, `-T`, `-U USERLIST`, `-V`, `-Z`, `-a`, `-c`, `-d`, `-e`, `-f`, `-g SESSION_OR_GROUP`, `-j`, `-l`, `-m`, `-o FORMAT`, `-p PIDLIST`, `-q PIDLIST`, `-s SESSIONLIST`, `-t TTYLIST`, `-u USERLIST`, `-w`, and `-y` (`-x` is personality-gated). BSD options include digit PID selectors, `H`, `L`, `M`, `O FORMAT`, `S`, `T`, `U USERLIST`, `V`, `X`, `Z`, `a`, `c`, `e`, `f`, `g`, `h`, `j`, `k SORT`, `l`, `m`, `n`, `o FORMAT`, `p PIDLIST`, `q PIDLIST`, `r`, `s`, `t [TTYLIST]`, `u`, `v`, `w`, and `x`; common clusters such as `aux` and `ax` are BSD syntax. GNU long options are `--Group`, `--User`, `--cols/--columns/--width`, `--context`, `--cumulative`, `--deselect`, `--forest`, `--format`, `--group`, `--header/--headers/--heading/--headings`, `--no-header/--no-headers/--no-heading/--no-headings/--noheader/--noheaders/--noheading/--noheadings`, `--info`, `--lines/--rows`, `--pid`, `--ppid`, `--quick-pid`, `--sid`, `--sort`, `--tty`, `--user`, `--version`, and `--help [simple|list|output|threads|misc|all]`; trailing operands select PID, `+SID`, or `-PGRP`. `output.c` exposes a large specifier table including common `pid`, `ppid`, `pgid`, `sid`, `user`/`uid`/`euid`/`ruid`, `group`/`gid`, `comm`/`ucmd`/`ucomm`, `args`/`cmd`/`command`, `tty`/`tt`/`tname`, `stat`/`state`, `time`, `etime`, `start`/`stime`, `pcpu`, `pmem`, `vsz`, `rss`, `nice`/`ni`, `pri`, `wchan`, `lwp`/`tid`/`nlwp`, and context/label fields; defaults and `aux`-style layouts come from `macro_array`.
- **Currently supported by MSP**: Virtual single-process view only. Supports `--version`, `--help [category]`, unknown long option diagnostics, `aux`/`ax`, `-e`, `-A`, `-ef`, `-f`, `-o FORMAT`, repeated/comma/space `--format`, empty headers, header/no-header aliases, `-p`/`--pid`, `-q`/`--quick-pid`, `--ppid`, and default output. Custom output recognizes `pid`, `ppid`, `comm`, `cmd`, `args`, `user`, and `uid`; unknown columns render `-`.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Multi-process virtual jobs, thread/task rows, forest trees, sort on every exotic key, and real CPU/memory accounting can be staged until MSP has a richer virtual process registry; parsing and policy-safe diagnostics for their flags should still exist. SELinux/context output can remain virtual placeholder/no-op until there is a security-label model.
- **Forbidden by policy**: Calling procps/libproc, `/proc`, `sysctl`, `ps`, or platform APIs to enumerate real macOS/iOS processes; exposing host PIDs, TTYs, sessions, process groups, CPU/memory, usernames, command lines, environment, namespaces, cgroups, start times, or executable paths; controlling or signaling processes.
- **Performance model**: O(virtual_processes * requested_columns) plus optional virtual sort. Current table size is one; future registries must be bounded, snapshot-based, and cancellable, with no host `/proc` backing.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because `ps` is a prime host-leak surface and the vendored procps-ng parser/display surface is much larger than the current single-row stub.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPPsCommand` in `MSPProcessMetadataCommands.swift` is registered and intentionally exposes only a virtual single-process view; it supports `--version`, `--help [category]`, unknown long option diagnostics, default output, `aux`/`ax`, `-e`/`-A`/`-ef`, `-o`, repeated/comma/space `--format`, empty header names, header/no-header aliases, `-p`/`--pid`, and `-q`/`--quick-pid` filtering over the virtual row. Direct/Core100 cases and `MSPWorkerFMiscProcessNumericSearchTests.testPsTimeoutAndLddMatchStableGNUOracleCases` cover invalid options, formatting, headerless output, PID misses, help category, and version.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: multi-process jobs, threads, forest rendering, exhaustive sort keys, selectors beyond the current single virtual row, and real CPU/memory accounting are deferred until a shared virtual process registry exists; enumerating host processes through procps/libproc, `/proc`, `sysctl`, host `ps`, platform APIs, or leaking host PIDs/users/TTY/env/command lines is forbidden.

## readlink

- **Command**: `readlink`
- **MSP implementation**: `MSPReadlinkCommand.swift` lines 3-127 and `MSPPOSIXPathCanonicalization.swift` lines 3-127; registered in `MSPPOSIXCoreCommandPack.swift` line 62.
- **Reference source**: `coreutils-9.1/src/readlink.c`, option table, `main`, `areadlink_with_size`, and `canonicalize_filename_mode`.
- **GNU/Linux parameter surface**: `readlink [OPTION]... FILE...`; `-f/--canonicalize`, `-e/--canonicalize-existing`, `-m/--canonicalize-missing`, `-n/--no-newline`, `-q/--quiet`, `-s/--silent`, `-v/--verbose`, `-z/--zero`, `--help`, `--version`.
- **Currently supported by MSP**: Supports short `-z -n -f -e -m -q -s -v`, long `--zero`, `--no-newline`, canonicalize/quiet/silent/verbose forms, `--help`, and `--version`; non-canonical mode reads workspace symlink target; virtual `/bin/sh` returns `dash`; canonical mode follows workspace symlinks with a 40-hop guard; missing/non-link errors are silent unless verbose.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: None for common readlink options; all missing common options are debt.
- **Forbidden by policy**: Resolving symlinks outside WorkspaceFS root or exposing backing host paths.
- **Performance model**: O(path components + symlink hops) per operand; bounded at 40 hops; no whole-file IO.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because core workspace canonicalization exists but common long options and edge oracles are missing.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPReadlinkCommand.swift` is registered, supports short `-z`, `-n`, `-f`, `-e`, `-m`, `-q`, `-s`, `-v`, long `--zero`, `--no-newline`, canonicalize/quiet/silent/verbose forms, `--help`, `--version`, virtual `/bin/sh -> dash`, WorkspaceFS symlink reads, and bounded canonicalization; direct/Core100 cases and `MSPPathCommandTests` cover common modes, delimiter behavior, help/version, mixed errors, and quiet/verbose behavior.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: loop/broken-link diagnostic exactness remains parent-sampling dependent; resolving outside WorkspaceFS or exposing backing host paths is forbidden.

## realpath

- **Command**: `realpath`
- **MSP implementation**: `MSPRealpathCommand.swift` lines 3-131 and `MSPPOSIXPathCanonicalization.swift` lines 3-127; registered in `MSPPOSIXCoreCommandPack.swift` line 63.
- **Reference source**: `coreutils-9.1/src/realpath.c`, option table, `realpath_canon`, `process_path`, and relative-output helpers.
- **GNU/Linux parameter surface**: `realpath [OPTION]... FILE...`; `-e/--canonicalize-existing`, `-m/--canonicalize-missing`, `-L/--logical`, `-P/--physical`, `-q/--quiet`, `-s/--strip/--no-symlinks`, `-z/--zero`, `--relative-to=DIR`, `--relative-base=DIR`, `--help`, `--version`.
- **Currently supported by MSP**: Supports `-z -m -e -q -P -L -s`, long zero/canonicalize-missing/canonicalize-existing/quiet/logical/no-symlinks/physical/strip/canonicalize, `--relative-to`, `--relative-base`, `--help`, and `--version`; default allows missing final component; `-s` avoids symlink expansion; `-L` and `-P` parse but are behaviorally equivalent except `-s`; canonicalization follows workspace symlinks with 40-hop guard.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: None for common realpath options; relative output is common and should be implemented.
- **Forbidden by policy**: Returning backing filesystem paths or resolving outside the virtual workspace root.
- **Performance model**: O(path components + symlink hops) per operand; bounded at 40 hops; no file-content IO.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because canonicalization is present but path semantics are subtle and under-stressed.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPRealpathCommand.swift` is registered and implements `--relative-to`, `--relative-base`, `--help`, `--version`, `-z`, `-m`, `-e`, `-q`, `-P`, `-L`, `-s`, long zero/canonicalize/quiet/logical/no-symlinks/physical/strip aliases, missing-final default, quiet errors, and no-symlink output; direct/Core100 cases plus `MSPPathCommandTests` cover relative output, help/version, and the updated canonicalization surface.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: true logical-vs-physical `..` behavior around symlinks and exact loop/broken-link/non-directory diagnostics are deferred until parent approves deeper canonicalization semantics; returning backing filesystem paths or resolving outside the virtual workspace root is forbidden.

## sleep

- **Command**: `sleep`
- **MSP implementation**: `MSPSleepCommand.swift` lines 4-142; registered in `MSPPOSIXCoreCommandPack.swift` line 79.
- **Reference source**: `coreutils-9.1/src/sleep.c`, `usage`, `apply_suffix`, and `main`; uses `xstrtod`, suffix parsing, sum of operands, and `xnanosleep`.
- **GNU/Linux parameter surface**: `sleep NUMBER[SUFFIX]...` or `sleep OPTION`; suffixes `s`, `m`, `h`, `d`; floating-point nonnegative numbers; GNU standard `--help`, `--version`.
- **Currently supported by MSP**: Requires at least one operand unless `--help` or `--version` is used; parses nonnegative `Double` prefix, `inf`/`infinity`, and optional one-character suffix `s/m/h/d`; sums operands; sleeps in 60-second chunks using `Task.sleep`; infinite values loop in chunks and remain cancellable.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: None for parsing/help/version; very long real-time sleeps can be tested with cancellation instead of wall-clock completion.
- **Forbidden by policy**: Blocking the main/UI thread or ignoring task cancellation.
- **Performance model**: O(number of operands) parse; runtime delay is requested duration, cancellable through Swift task cancellation; memory O(1).
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because cancellation/timeout behavior is a runtime safety boundary, not just formatting.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPSleepCommand.swift` is registered, parses multiple GNU-style numeric operands including fractional, hex floats, `inf`/`infinity`, suffixes `s/m/h/d`, `--`, `--help`, `--version`, invalid-option/invalid-interval diagnostics, and cancellable chunked `Task.sleep`; Core100/stress cases and `MSPWorkerFMiscProcessNumericSearchTests` cover interval parsing, help/version, timeout interruption, infinite sleep cancellation, and non-blocking behavior.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: very long wall-clock completion tests should be represented by cancellation/timeouts instead of waiting; an agent-wide wall-clock cap is deferred to parent runtime policy; blocking the main/UI thread or ignoring task cancellation is forbidden.

## stat

- **Command**: `stat`
- **MSP implementation**: `MSPStatCommand.swift` lines 4-230; registered in `MSPPOSIXCoreCommandPack.swift` line 87.
- **Reference source**: `coreutils-9.1/src/stat.c`, option table, `do_stat`, `do_statfs`, `print_it`, and `usage` format list.
- **GNU/Linux parameter surface**: `stat [OPTION]... FILE...`; `-L/--dereference`, `-f/--file-system`, `-c/--format=FORMAT`, `--printf=FORMAT`, `-t/--terse`, `--cached=MODE`, `--help`, `--version`; file format sequences include `%a %A %b %B %C %d %D %Hd %Ld %f %F %g %G %h %i %m %n %N %o %s %r %R %Hr %Lr %t %T %u %U %w %W %x %X %y %Y %z %Z`; filesystem sequences include `%a %b %c %d %f %i %l %n %s %S %t %T`.
- **Currently supported by MSP**: Supports `-L/--dereference`, `-f/--file-system`, `-c`, `--format`, `--printf`, `-t/--terse`, `--cached=MODE`, `--help`, and `--version`; default output uses virtual device/inode/mode/timestamps and virtual `nobody/nogroup`; implemented file format codes include `%% %a %A %b %B %C %d %D %f %F %g %G %h %i %m %n %N %o %r %R %s %t %T %u %U %w %W %x %y %z %X %Y %Z`; `--printf` handles a bounded escape set; stats WorkspaceFS paths only.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Real filesystem cache modes are not applicable; `--cached` should parse and map to virtual no-op/default semantics rather than leak host statx behavior.
- **Forbidden by policy**: Exposing host device IDs, mount points, inode numbers, owner names, or backing file paths; statting outside WorkspaceFS.
- **Performance model**: O(operands * format length) plus WorkspaceFS stat; no content read. Future filesystem mode should be O(1) virtual aggregate, not host traversal.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because metadata can leak host identity and current uid/gid output conflicts with virtual identity.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPStatCommand.swift` is registered and now implements `-f/--file-system`, real `-L/--dereference` path canonicalization, `-t/--terse`, `-c/--format`, `--printf`, `--cached=MODE` as a virtual no-op, `--help`, `--version`, default output, filesystem `%T`, common file format codes, stable virtual inode/device placeholders, virtual `nobody/nogroup` uid/gid consistency with `id`, and WorkspaceFS-only stat; direct/Core100 cases and `MSPDataComparisonMetadataOracleTests.testMetadataCommandsMatchStableGNUOracle` cover format, filesystem, terse, default, missing, cached, help/version, and identity consistency.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: real statx cache behavior, exhaustive directives, full printf flags/width/precision, mount-point modeling, device major/minor realism, birth time, and SELinux placeholders are deferred until parent defines virtual metadata policy; exposing host device IDs, mount points, inode numbers, owner names, or backing paths, or statting outside WorkspaceFS, is forbidden.

## timeout

- **Command**: `timeout`
- **MSP implementation**: `MSPTimeoutCommand.swift` lines 4-159; subcommand execution through `MSPCommandContext.runSubcommand` lines 102-125, `ModelShellProxy` context creation lines 1208-1218 and subcommand runner lines 4799-4824; registered in `MSPPOSIXCoreCommandPack.swift` line 89.
- **Reference source**: `coreutils-9.1/src/timeout.c`, option table, `parse_duration`, signal/timer setup, fork/exec, wait, and documented exit statuses.
- **GNU/Linux parameter surface**: `timeout [OPTION] DURATION COMMAND [ARG]...`; `--preserve-status`, `--foreground`, `-k/--kill-after=DURATION`, `-s/--signal=SIGNAL`, `-v/--verbose`, `--help`, `--version`; duration suffixes `s/m/h/d`; exit statuses 124/125/126/127/137 or child status.
- **Currently supported by MSP**: Parses `-v/--verbose`, `--foreground`, `--preserve-status`, `-k`, `--kill-after`, `-s`, `--signal`, `--help`, and `--version`; validates duration and target; executes only MSP subcommands through the virtual runner; timeout returns 124, emits verbose TERM diagnostics when requested, and cancels the Swift task; duration `0` disables timeout. Signal, kill-after, preserve-status, and foreground remain virtual no-ops beyond parsing.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Real POSIX signal delivery, process groups, foreground tty control, and SIGKILL escalation are deferred because MSP does not fork host processes; they need virtual semantics only.
- **Forbidden by policy**: Sending signals to real host processes, spawning untrusted workspace binaries, changing host process groups, or using host TTY foreground control.
- **Performance model**: O(1) setup plus child command cost; current implementation races a child `Task` and timer. Safety depends on cooperative cancellation in child commands.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: high, because non-cooperative cancellation can leave work running after the model-visible timeout result.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPTimeoutCommand.swift` is registered, parses `-v/--verbose`, `--foreground`, `--preserve-status`, `-k/--kill-after`, `-s/--signal`, `--help`, `--version`, validates duration/target, supports `timeout 0`, runs only MSP subcommands, returns 127 for missing registered commands, returns 124 promptly on timeout, emits verbose TERM diagnostics, and cancels cooperative child tasks; direct/Core100/stress cases and `MSPWorkerFMiscProcessNumericSearchTests` cover success, failure, invalids, help/version, verbose timeout, sleep interruption, infinite sleep interruption, and non-cooperative prompt return.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: real POSIX signal delivery, process groups, foreground tty control, SIGKILL escalation, 126 cannot-invoke distinction for host exec, and full `--preserve-status` process semantics are deferred because MSP does not fork host processes; sending host signals, spawning untrusted binaries, changing process groups, or controlling host TTY foreground state is forbidden.

## tty

- **Command**: `tty`
- **MSP implementation**: `MSPTtyCommand.swift` lines 3-27; registered in `MSPPOSIXCoreCommandPack.swift` line 94.
- **Reference source**: `coreutils-9.1/src/tty.c`, option table and `main`; uses `isatty` and `ttyname`.
- **GNU/Linux parameter surface**: `tty [OPTION]...`; `-s/--silent/--quiet`, `--help`, `--version`; exit 0 if stdin is a tty, 1 if not, 2 usage error, 3 write error.
- **Currently supported by MSP**: Supports `-s`, `--silent`, `--quiet`, `--help`, and `--version`; always reports `not a tty` with exit 1 or silent exit 1; extra operands exit 2.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Interactive virtual TTY support can wait until MSP has an explicit terminal abstraction; current non-tty default is policy-safe for noninteractive agents.
- **Forbidden by policy**: Returning real `/dev/ttys*`, `/dev/pts/*`, or macOS terminal paths; probing host stdin with `isatty` by default.
- **Performance model**: O(1).
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because current default is safe but hardcoded and incomplete for interactive surfaces.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPTtyCommand.swift` is registered, supports `-s`, `--silent`, `--quiet`, `--help`, `--version`, extra operand exit 2, invalid option diagnostics, and hardcoded non-tty output; direct/Core100 cases plus `MSPCore100ExtraCommandTests.testEnvironmentIdentityProcessAndPathUtilitiesMatchStableOracleCases` cover the current noninteractive agent path and help/version.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: positive interactive virtual TTY support and output write-error semantics are deferred until parent adds an explicit terminal/output abstraction to `MSPCommandContext`; returning real `/dev/ttys*`/`/dev/pts/*`/macOS terminal paths or probing host stdin with `isatty` by default is forbidden.

## uname

- **Command**: `uname`
- **MSP implementation**: `MSPPOSIXVirtualIdentity.swift` lines 1-29 and `MSPUnameCommand.swift` lines 4-158; registered in `MSPPOSIXCoreCommandPack.swift` line 96.
- **Reference source**: `coreutils-9.1/src/uname.c`, `uname_long_options`, `decode_switches`, and `main`.
- **GNU/Linux parameter surface**: `uname [OPTION]...`; `-a/--all`, `-s/--kernel-name/--sysname`, `-n/--nodename`, `-r/--kernel-release/--release`, `-v/--kernel-version`, `-m/--machine`, `-p/--processor`, `-i/--hardware-platform`, `-o/--operating-system`, `--help`, `--version`.
- **Currently supported by MSP**: Supports all listed information flags, long aliases, `--help`, `--version`, and `--`; default prints `Linux`; `-a` prints virtual Debian-like fields and omits unknown processor/hardware entries; fields come from the current virtual Linux profile.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: Dynamic kernel profile selection can wait, but the current hardcoded values must be treated as a named virtual profile, not host facts.
- **Forbidden by policy**: Calling host `uname` or exposing macOS/iOS kernel, architecture, device name, or OS version by default.
- **Performance model**: O(number of requested fields), all in-memory.
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: medium, because virtualization is correct in spirit but hardcoded and not fully covered.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPUnameCommand.swift` is registered, supports `-a`, `-s`, `-n`, `-r`, `-v`, `-m`, `-p`, `-i`, `-o`, long aliases, `--help`, `--version`, `--`, invalid/extra operand diagnostics, and virtual Debian-like fields from `MSPPOSIXVirtualIdentity.profile`; direct/Core100 cases and `MSPWorkerFIdentityEncodingDigestTests` cover the main virtual profile and version.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: dynamic kernel profile selection beyond the current virtual profile is deferred to parent configuration policy; calling host `uname` or exposing macOS/iOS kernel, architecture, device name, or OS version is forbidden.

## whoami

- **Command**: `whoami`
- **MSP implementation**: `MSPPOSIXVirtualIdentity.swift` lines 7-12 and `MSPWhoamiCommand.swift` lines 3-54; registered in `MSPPOSIXCoreCommandPack.swift` line 102.
- **Reference source**: `coreutils-9.1/src/whoami.c`, `main` and `usage`; equivalent to `id -un`.
- **GNU/Linux parameter surface**: `whoami [OPTION]...`; GNU standard `--help`, `--version`; no operands.
- **Currently supported by MSP**: Returns virtual current user `nobody`; supports `--help`, `--version`, and `--`; rejects operands and unknown options; ignores host `USER`/`LOGNAME`.
- **Must implement**: None after the command-local implementation and tests recorded in Closure status; shared or policy-incompatible behavior is recorded under Deferred with reason.
- **Deferred with reason**: None.
- **Forbidden by policy**: Reading host effective uid or account name; honoring host `USER`/`LOGNAME` as identity source.
- **Performance model**: O(1).
- **Oracle/stress gaps**: None for command-local coverage after the tests recorded in Closure status; fixture expansion or shared-runtime validation that cannot be done inside this batch is recorded under Deferred with reason.
- **Risk**: low, because the command is small and safely virtualized, with only standard-option debt.
- **Closure status (2026-06-29)**:
  - **Implemented evidence**: `MSPWhoamiCommand.swift` is registered, returns the virtual current user from `MSPPOSIXVirtualIdentity`, supports `--help`, `--version`, rejects operands/unknown options, accepts `--`, and ignores host `USER`; direct/Core100 cases plus `MSPWorkerFIdentityEncodingDigestTests` cover default output, version, env independence, and `id -un` consistency.
  - **Implementation open after this batch**: None after command-local closure.
  - **Oracle/stress open after this batch**: None after command-local tests and existing Core100 fixture coverage.
  - **Deferred/forbidden with reason**: no whoami feature is intentionally deferred; reading host effective uid/account names or honoring host `USER`/`LOGNAME` as identity is forbidden.
