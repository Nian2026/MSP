# MSP v1 Debian 12 Oracle

This directory contains sanitized Linux oracle fixtures for MSP conformance.
The public files intentionally omit live host addresses, local machine paths,
private source tree names, transport logs, and random temporary directories.

Evidence levels:

- `linux_and_candidate_parity_pass`: a private historical run proved that the
  captured Linux output and the candidate implementation output matched with
  zero mismatches.
- `linux_capture_only`: the Linux output was captured and normalized, but this
  public fixture does not claim a completed candidate comparison.

The fixtures compare normalized observable behavior. Random case roots and
private paths are represented as placeholders such as `<CASE_ROOT>`,
`<CASE_RUNNER_ROOT>`, `<CASE_COMMAND>`, and `<LINUX_ORACLE_HOST>`.

Files:

- `noninteractive-cases.json`: non-PTY shell and command-layer cases. This is
  the MSP v1 target for ordinary `exec_command` style runs, including long
  commands, complex shell syntax, stdin, binary output, Python, Node, and common
  Linux command behavior.
- `pty-cases.json`: PTY stream cases for interactive shell behavior. These are
  kept separate because the observable contract is a byte stream, not separate
  stdout and stderr pipes.

Cases marked `linux_capture_only` are still part of the MSP target. The label
only describes how much historical candidate-comparison evidence was available
at import time; it does not make the case optional.

Running the Swift conformance runner:

```sh
Conformance/Scripts/run_debian12_oracle_conformance.sh
```

Useful filters:

```sh
MSP_DEBIAN12_ORACLE_LIMIT=1 Conformance/Scripts/run_debian12_oracle_conformance.sh
MSP_DEBIAN12_ORACLE_CASE=existing-coreutils-text-pipeline Conformance/Scripts/run_debian12_oracle_conformance.sh
MSP_DEBIAN12_ORACLE_EVIDENCE=linux_and_candidate_parity_pass Conformance/Scripts/run_debian12_oracle_conformance.sh
MSP_DEBIAN12_ORACLE_EXCLUDE_CATEGORIES=python,node Conformance/Scripts/run_debian12_oracle_conformance.sh
MSP_DEBIAN12_ORACLE_CATEGORIES=existing-commands,complex-syntax Conformance/Scripts/run_debian12_oracle_conformance.sh
MSP_DEBIAN12_ORACLE_EXCLUDE_COMMANDS=python3,node Conformance/Scripts/run_debian12_oracle_conformance.sh
```

The runner writes its latest report to
`.build/msp-conformance/debian12-noninteractive-report.json`. That report keeps
the base64 byte fields and also includes UTF-8 previews plus first differing
byte offsets for quick diagnosis.

The PTY fixture is an executable Linux/Debian oracle gate through
`Conformance/Scripts/run_debian12_pty_oracle_container.sh`; final verification
requires all 157 byte-stream cases, including the Python PTY cases, to pass with
`--require-linux-runner`.

Python runtime coverage is tracked separately in
`Conformance/Fixtures/MSPV1PythonRuntimeCoverage.json`. The current iOS
embedded-CPython app gate covers the noninteractive Python cases that do not
require Node; Node-mixed noninteractive cases are still accounted separately,
while PTY stream cases are covered by the Debian/Linux PTY oracle gate.

```sh
Conformance/Scripts/check_python_oracle_coverage.py
```
