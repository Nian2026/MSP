# Core100 Baseline Failure Summary

Last updated: 2026-06-28 17:45 Asia/Shanghai.

This file records the first MSP Swift SDK baseline against the Core100 Debian
oracle. It is an implementation work input, not an oracle fixture.

## Commands

Fixture/safety check:

```sh
swift test --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleFixtureLoadsAndStaysPublicSafe
```

Full baseline:

```sh
MSP_RUN_CORE100_ORACLE=1 swift test --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner
```

Group rerun example:

```sh
MSP_RUN_CORE100_ORACLE=1 MSP_CORE100_ORACLE_GROUPS=A swift test --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner
```

Command rerun example:

```sh
MSP_RUN_CORE100_ORACLE=1 MSP_CORE100_ORACLE_COMMANDS=tree swift test --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner
```

Single case rerun example:

```sh
MSP_RUN_CORE100_ORACLE=1 MSP_CORE100_ORACLE_CASE=core100-tree-default swift test --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner
```

## Machine Report

The machine-readable report is generated at:

```text
.build/msp-conformance/core100-noninteractive-report.json
```

## Baseline Result

```text
selected_case_count: 435
passed_case_count: 88
failed_case_count: 347
```

Failure likely-layer counts:

| Layer | Failures |
| --- | ---: |
| `command_registry_or_external_runner` | 316 |
| `command_output_or_exit_semantics` | 27 |
| `workspace_fs_or_side_effects` | 4 |

## Command Baseline

| Group | Command | Cases | Passed | Failed |
| --- | --- | ---: | ---: | ---: |
| A shell-state | `export` | 12 | 0 | 12 |
| A shell-state | `unset` | 11 | 7 | 4 |
| A shell-state | `set` | 15 | 10 | 5 |
| A shell-state | `umask` | 12 | 10 | 2 |
| B shell-input-source-alias | `read` | 16 | 8 | 8 |
| B shell-input-source-alias | `source` | 13 | 11 | 2 |
| B shell-input-source-alias | `alias` | 16 | 0 | 16 |
| B shell-input-source-alias | `unalias` | 8 | 0 | 8 |
| C filesystem | `rmdir` | 12 | 0 | 12 |
| C filesystem | `unlink` | 8 | 0 | 8 |
| C filesystem | `truncate` | 14 | 0 | 14 |
| C filesystem | `install` | 18 | 0 | 18 |
| C filesystem | `tree` | 14 | 0 | 14 |
| D byte-stream | `dd` | 21 | 0 | 21 |
| D byte-stream | `split` | 19 | 0 | 19 |
| D byte-stream | `shuf` | 13 | 0 | 13 |
| D byte-stream | `tsort` | 10 | 0 | 10 |
| E text-layout | `expr` | 16 | 0 | 16 |
| E text-layout | `strings` | 12 | 0 | 12 |
| E text-layout | `fold` | 10 | 0 | 10 |
| E text-layout | `expand` | 10 | 0 | 10 |
| E text-layout | `unexpand` | 10 | 0 | 10 |
| E text-layout | `fmt` | 12 | 0 | 12 |
| F identity-encoding-time | `uname` | 10 | 0 | 10 |
| F identity-encoding-time | `whoami` | 4 | 0 | 4 |
| F identity-encoding-time | `id` | 14 | 0 | 14 |
| F identity-encoding-time | `hostname` | 6 | 0 | 6 |
| F identity-encoding-time | `sleep` | 10 | 10 | 0 |
| F identity-encoding-time | `base32` | 10 | 0 | 10 |
| F identity-encoding-time | `basenc` | 14 | 0 | 14 |
| F identity-encoding-time | `sha512sum` | 10 | 0 | 10 |
| F identity-encoding-time | `b2sum` | 10 | 0 | 10 |

Shell stress:

```text
stress_case_count: 57
stress_failed_count: 21
```

## Notes For Parallel Implementation

- The baseline runner executes Core100 `command_line` directly through
  `ModelShellProxy.run(...)`; it does not wrap cases in host `bash -c`.
- The conformance test is gated by `MSP_RUN_CORE100_ORACLE=1`, so ordinary
  `swift test` does not run the 435-case failure wall.
- Subagents should rerun only their own group or command filters.
- The parent agent owns final full baseline reruns and any shared harness
  changes.
