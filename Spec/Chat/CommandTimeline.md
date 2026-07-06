# `.chat` Command Timeline

Status: draft standard candidate.

This document defines command timeline semantics for MSP-style shell-like
commands. A command is not a generic tool call named `shell`, and it is not a
host shell transcript. It is a standard runtime span with parse, expansion,
execution, output, policy, artifacts, and exit-code semantics.

## 1. Command Profile

The `command-timeline` data profile means the package contains canonical command
events. The `execute_msp_commands` capability is separate and means an
implementation can execute MSP commands and append new command events.

A lightweight reader may support `read_command_timeline` without implementing an
MSP runtime.

## 2. Command Span

Every command span starts with `command_call` and ends with one of:

- `command_complete`;
- `command_error`;
- `turn_aborted` or related cancellation event.

The span is identified by `command_id` and pairable through `call_id` or
`correlation_id`.

`command_call` payload should include:

- `command_id`;
- `raw_command`;
- `dialect`;
- `profile`;
- `parse_status`;
- `parsed_script`;
- `parsed_before_expansion`;
- `expanded_invocation`;
- `expansion_diagnostics`;
- `expansion_env_delta`;
- `cwd_before`;
- `runtime_context_snapshot_ref`;
- `stdin_ref`;
- `stdin_closed`;
- `source_transport_ref`;
- `policy_decision_ref`;
- `artifact_refs`.

## 3. Parser And Expansion

The command timeline must preserve enough information to explain what was parsed
and what was executed.

Required distinction:

- raw command text;
- parsed script before expansion;
- expansion diagnostics;
- expanded invocation;
- actual executed stage.

Expansion may change environment, variables, argv, redirection, glob results, or
other runtime state. Such changes must be recorded as `expansion_env_delta`,
`state_changes`, or linked state patch events when they matter for replay,
audit, or continuation.

## 4. Pipeline And Stage Events

Commands with pipelines or compound execution must record stage subspans. A
writer may represent stages as separate events or as `stage_spans` in the
completion payload, but validators must be able to check ordering and exit-code
rules.

Standard stage events:

- `command_stage_started`
- `command_stage_output`
- `command_stage_completed`

Stage fields:

- `command_id`;
- `stage_index`;
- `raw_command`;
- `expanded_command`;
- `input_source`;
- `output_routing`;
- `stdout_ref`;
- `stderr_ref`;
- `touched_paths`;
- `duration_ms`;
- `exit_code`;
- `skipped`;
- `skip_reason`.

## 5. Sequencing And Skipped Work

The timeline must explain shell-like control flow:

- sequence operator;
- pipeline operator;
- `&&`;
- `||`;
- negation;
- `pipefail`;
- skipped pipeline or stage;
- skip reason.

Examples of skip reasons:

- `and_previous_failed`;
- `or_previous_succeeded`;
- `policy_denied`;
- `parse_failed`;
- `input_unavailable`;
- `runtime_aborted`.

Skipped stages are still part of the command span. They should be recorded as
not executed rather than omitted when their absence would make the command result
ambiguous.

## 6. Exit Status

`command_complete` must include:

- `exit_status`;
- `stage_exit_codes`;
- `pipefail`;
- `negated`;
- `final_exit_formula`;
- `duration_ms`;
- `cancelled`;
- `timeout`;
- `parse_error`;
- `permission_denied`;
- `state_changes`;
- `artifact_refs`.

The final exit status must be derivable from stage exit codes, pipefail, and
negation rules, or the event must explicitly mark the formula as unavailable
with a reason.

## 7. Output

`command_output` and `command_stage_output` record canonical command output.

Output fields:

- `command_id`;
- `stage_index`;
- `stream`: `stdout`, `stderr`, or extension stream;
- `seq`;
- `text`;
- `bytes_ref`;
- `byte_count`;
- `encoding`;
- `truncated`;
- `projection_only`;
- `artifact_refs`.

Raw stdout/stderr, model-facing projection text, and source transport output are
different layers. They must not overwrite one another.

Layer distinction:

- canonical raw output: command output events or blob refs;
- model-rendered output: projection data;
- source transport output: raw provider/tool/runtime envelope.

If a projection shortens output, the canonical output reference must remain
available or be explicitly marked missing, redacted, or external-only.

## 8. Policy And Environment

Command execution may require policy decisions. The timeline should record:

- `policy_request`;
- `policy_decision`;
- requested capability;
- affected workspace roots;
- touched path set;
- redirection targets;
- external runner policy;
- device or application capability;
- environment snapshot reference;
- permission snapshot reference.

The command context may include process environment, shell options, shell
variables, arrays, functions, aliases, file descriptor table, current directory,
and stdin state.

## 9. Command Origins

MSP command language can include standard command packs, application-owned
commands, and optional external runners. Command origin must be explicit:

- `posix_core`;
- `app`;
- `external`;
- extension origin.

Application-owned commands should declare:

- `command_pack_id`;
- `command_pack_version`;
- stdin contract;
- stdout contract;
- artifact contract;
- side-effect contract;
- capability permissions;
- provenance for generated artifacts.

This allows application commands to compose with other command primitives through
pipes, redirection, exit-code logic, and artifact references.

## 10. Source Transport

Raw tool calls, protocol calls, provider-native items, and runtime-native items
may be retained as `source_transport`. Heavy runtimes may need this for lossless
replay or parity.

Recommended source transport fields:

- `transport_kind`;
- `provider`;
- `response_id`;
- `native_item_id`;
- `output_index`;
- `tool_call_id`;
- `tool_name`;
- `tool_batch_id`;
- `raw_arguments_ref`;
- `schema_name`;
- `schema_version`;
- `schema_strict`;
- `retry_index`;
- `mapped_command_id`.

Canonical command semantics still belong to command timeline events. Source
transport retention is not a replacement for standard command events.
