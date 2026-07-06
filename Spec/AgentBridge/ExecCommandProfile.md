# MSP `exec_command` Profile

MSP exposes a shell surface to agents through a Codex-style `exec_command`
session contract. The long-term contract includes ordinary pipe execution,
PTY-backed execution, yielded background sessions, stdin continuation, and
model-visible output that matches Codex unified exec.

This profile is part of the MSP public surface. It is not named after any host
application or implementation.

## Boundary Rule

MSP keeps two surfaces separate:

- Internal runtime result: structured data for SDK users, policy, audit, tests,
  and diagnostics.
- Agent-facing result: plain shell text.

The agent-facing bridge must not JSON-wrap command output.

MSP also keeps two polling paths separate:

- Model-visible polling is `write_stdin` with omitted or empty `chars`; it must
  keep Codex's empty-poll timing semantics.
- Runtime/UI polling may use SDK-owned `readSession`/`readExec` operations to
  read buffered output and status without writing stdin. This runtime read path
  is for UI synchronization, diagnostics, and oracle runners. It must not be
  exposed to the model as a replacement for `write_stdin`.

## Tool Shape

The primary command tool is:

```text
exec_command
```

The command string is passed through `cmd`. The model-visible shape is aligned
with Codex unified exec:

```json
{
  "type": "object",
  "properties": {
    "cmd": {
      "type": "string"
    },
    "workdir": {
      "type": "string"
    },
    "shell": {
      "type": "string"
    },
    "tty": {
      "type": "boolean"
    },
    "yield_time_ms": {
      "type": "number"
    },
    "max_output_tokens": {
      "type": "number"
    }
  },
  "required": ["cmd"],
  "additionalProperties": false
}
```

`tty=false` or omission selects ordinary pipe semantics. `tty=true` selects a
PTY backend, where terminal output is an ordered byte stream and stdout/stderr
are not separate model-visible pipes. `yield_time_ms` controls how long the
runtime waits before yielding output and a session id for a still-running
process.

The continuation tool is:

```text
write_stdin
```

```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "number"
    },
    "chars": {
      "type": "string"
    },
    "yield_time_ms": {
      "type": "number"
    },
    "max_output_tokens": {
      "type": "number"
    }
  },
  "required": ["session_id"],
  "additionalProperties": false
}
```

Omitted or empty `chars` means poll the running session without writing stdin.
Non-empty `chars` writes to the session stdin and then reads recent output.
Result fields such as `stdout`, `stderr`, `exit_code`, `ok`, or `tool_name`
must not appear in either tool input schema.

The timing policy follows Codex unified exec:

- initial `exec_command` defaults to 10000 ms and clamps to 250..30000 ms;
- non-empty `write_stdin` defaults to 250 ms and caps at 30000 ms;
- empty `write_stdin` polls default to 5000 ms and clamp to the configured
  background maximum, 300000 ms by default.

Tests and UI code must not weaken the empty-poll minimum. If they need to read
session state faster, they must use the runtime read path instead of changing
the model-visible `write_stdin` contract.

## Output Shape

The model-visible output is terminal text.

Allowed:

```text
Wall time: 0.0031 seconds
Process exited with code 0
Original token count: 3
Output:
notes.txt
report.pdf
```

Not allowed as the default bridge output:

```json
{
  "stdout": "notes.txt\nreport.pdf\n",
  "stderr": "",
  "exit_code": 0
}
```

JSON is allowed only when the invoked command itself emits JSON, for example
`some-command --json`. The bridge must not add a JSON envelope around ordinary
command output.

A still-running command is reported as:

```text
Wall time: 0.2500 seconds
Process running with session ID 92492
Original token count: 0
Output:
```

Later `write_stdin` calls must use the same output envelope and either keep the
session running or report a final exit code.

## Internal Result

Implementations may keep structured data internally:

- stdout
- stderr
- exit code
- cwd
- wall time
- truncation metadata
- touched paths
- policy decision
- audit record
- session id
- tty/pipe backend
- stdin writes
- termination state

That structured data is for SDK APIs, logs, audit, diagnostics, and conformance
tests. It is not the default agent-facing shell output.

## Completion Gates

This profile is not complete merely because `exec_command` can run a command.
The Codex-equivalent gate requires:

- source-backed parity with current Codex unified exec and Readex session
  bridge behavior;
- executable `yield_time_ms` tests for quick exit, yielded background process,
  empty-poll `write_stdin`, non-empty stdin writes, termination, output
  truncation, and concurrent sessions;
- executable exec-session stress tests for multi-session concurrency, silent
  long-running processes, 10MB+ PTY output, high-frequency stdin writes, and
  process-group termination cleanup;
- Debian 12 noninteractive oracle conformance;
- Debian 12 PTY byte-stream oracle conformance for all imported
  `pty-cases.json` cases;
- real UI simulator validation with real model requests when the app surface
  is being certified.

The PTY gate must be proven against Linux/Debian terminal semantics. A local
macOS native PTY backend is useful for development smoke tests, but it is not
enough to certify Debian PTY parity because canonical input, echo, and line
discipline limits differ observably from Linux.

The required executable Debian PTY gate is:

```bash
MSP_RUN_DEBIAN12_PTY_ORACLE=1 \
MSP_DEBIAN12_PTY_ORACLE_BACKEND=linux-external \
MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX=1 \
swift test --filter ModelShellProxyDebian12PTYOracleConformanceTests/testMSPV1Debian12PTYOracleConformanceRunner
```

By default the `linux-external` backend calls
`Conformance/Scripts/run_debian12_pty_oracle_container.sh`, which runs the
Python PTY oracle runner in a Debian 12 based container and writes
`.build/msp-conformance/debian12-pty-linux-report.json`. A custom runner may be
provided with `MSP_DEBIAN12_PTY_ORACLE_RUNNER`, but it must execute the same
`pty-cases.json` fixture on Linux/Debian and emit the same report shape.

The full release gate must also verify the report:

```bash
Conformance/Scripts/verify_debian12_pty_oracle_report.py \
  --report .build/msp-conformance/debian12-pty-linux-report.json \
  --require-zero-failures \
  --require-linux-runner \
  --require-all-fixture-cases \
  --require-python-pty-cases \
  --expected-case-count 157
```

This verifier is intentionally stricter than a smoke run. It rejects reports
from macOS/Darwin runners, partial case selections, nonzero failures, unknown
case ids, and any PTY Python case that is not in the passed case set.

The repository-level final gate that combines the Codex-style session contract,
local exec-session stress, Debian noninteractive oracle, Linux PTY oracle,
report verification, and real iOS Simulator pressure runs is:

```bash
MSP_PLAYGROUND_MODEL_BASE_URL=... \
MSP_PLAYGROUND_MODEL_API_KEY=... \
MSP_PLAYGROUND_MODEL=gpt-5.5 \
  Conformance/Scripts/run_final_exec_session_release_gate.sh
```

That command is the certification entrypoint for this profile. It must not be
replaced by a macOS PTY smoke run, a partial pressure matrix, a mock provider,
or a model other than `gpt-5.5`.

## Compatibility Principle

MSP can expose rich SDK APIs to app developers. To agents, the bridge must look
like the Codex command surface: a shell command/session protocol with terminal
text output, not a generic structured tool result protocol.
