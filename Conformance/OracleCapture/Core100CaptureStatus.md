# Core100 Oracle Capture Status

Last updated: 2026-07-14 Asia/Shanghai.

## Current Accepted Capture

- Case generator: `Conformance/Scripts/core100_oracle_capture.py`.
- Generated cases: `Conformance/OracleCapture/Core100CaptureCases.generated.json`.
- Public oracle fixture: `Conformance/ReferenceOutputs/MSPV1Core100Debian12Oracle/noninteractive-cases.json`.
- Safety policy: `Conformance/OracleCapture/DebianOracleCaptureSafetyPolicy.md`.

Current public fixture summary:

```text
case_count: 905
linux_capture_only_count: 905
core100_command_count: 100
covered_core100_command_count: 100
missing_core100_commands: []
shell_stress_case_count: 57
timeout_count: 0
limit_exceeded_count: 0
```

Coverage is counted by `primary_command`, not by helper commands appearing in
the same shell line. This prevents helper calls such as `printf`, `sort`, or
`find` from falsely proving another command's own oracle coverage.

The per-command primary sample counts live in the fixture summary:

```text
Conformance/ReferenceOutputs/MSPV1Core100Debian12Oracle/noninteractive-cases.json
  evidence_summary.per_command_case_count
```

## Latest Local Gates

These gates passed for the 905-case fixture:

```sh
python3 -m py_compile Conformance/Scripts/core100_oracle_capture.py
python3 Conformance/Scripts/core100_oracle_capture.py generate-cases --output Conformance/OracleCapture/Core100CaptureCases.generated.json
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit --cases Conformance/OracleCapture/Core100CaptureCases.generated.json
```

Safety self-test result:

```text
valid_case_count: 2
rejected_unsafe_case_count: 9
status: passed
```

Safety audit result:

```text
accepted_case_count: 905
finding_count: 0
```

The runner enforces command text, fixture path, fixture size, stdin size,
stdout/stderr, file-tree, single-file, run-root, and cleanup limits before a
public oracle fixture can be promoted.

## Latest VPS Capture

Configured host:

```text
provided at capture time through --host or MSP_VPS_HOST
```

Reference command packages confirmed or installed for this capture:

```text
bc: /usr/bin/bc, bc 1.07.1
rg: /usr/bin/rg, ripgrep 13.0.0
xxd: /usr/bin/xxd
tree: installed from Debian package tree 2.1.0
```

The `bc`, `rg`, and `xxd` packages were installed after an implementation
baseline exposed that the earlier oracle had captured `command not found` for
commands that Core100 declares implemented. The fixture was then recaptured
from the corrected Debian reference environment.

Full capture command:

```sh
python3 Conformance/Scripts/core100_oracle_capture.py run-vps \
  --cases Conformance/OracleCapture/Core100CaptureCases.generated.json \
  --output Conformance/ReferenceOutputs/MSPV1Core100Debian12Oracle/noninteractive-cases.json \
  --raw-dir .codex-tmp/core100-oracle-capture
```

Result:

```text
case_count: 905
linux_capture_only_count: 905
core100_command_count: 100
covered_core100_command_count: 100
missing_core100_commands: []
shell_stress_case_count: 57
timeout_count: 0
limit_exceeded_count: 0
```

The current 905-case fixture was regenerated from
`Conformance/OracleCapture/Core100CaptureCases.generated.json`, passed the
Core100 safety audit with `finding_count: 0`, and was captured on the Debian
reference VPS through `core100_oracle_capture.py run-vps`.

Post-capture checks passed:

- Public fixture contains no raw `/tmp/msp-oracle-capture-*` paths.
- Public fixture contains no private `vps_case_root` or `vps_runner_root`
  fields.
- Public fixture contains no concrete SSH host marker.
- Read-only remote `/tmp` residue check found no remaining
  `msp-oracle-capture-*` directories.

## Current MSP Implementation Baseline

The final-gate contract for the implementation-level Core100 oracle report is:

```text
selected_case_count: 905
passed_case_count: 905
failed_case_count: 0
```

This document records the accepted Core100 fixture baseline. Full release
closure is determined separately by `check_core100_closure.py` and the final
gate verifier.

## Host Key And SSH Notes

- Strict host-key checking remains enabled.
- Project-local known hosts may be used through
  `.codex-tmp/core100-oracle-capture/known_hosts`,
  `--known-hosts`, or `MSP_VPS_KNOWN_HOSTS`.
- The runner also supports `--identity-file` / `MSP_VPS_IDENTITY_FILE`.
- No global `~/.ssh/known_hosts` update is required by the runner.

## Resume Commands

Regenerate and validate locally:

```sh
python3 Conformance/Scripts/core100_oracle_capture.py generate-cases \
  --output Conformance/OracleCapture/Core100CaptureCases.generated.json
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit \
  --cases Conformance/OracleCapture/Core100CaptureCases.generated.json
```

Capture on VPS after local gates pass:

```sh
python3 Conformance/Scripts/core100_oracle_capture.py run-vps \
  --cases Conformance/OracleCapture/Core100CaptureCases.generated.json \
  --output Conformance/ReferenceOutputs/MSPV1Core100Debian12Oracle/noninteractive-cases.json \
  --raw-dir .codex-tmp/core100-oracle-capture
```

Private raw SSH artifacts remain under:

```text
.codex-tmp/core100-oracle-capture/
```
