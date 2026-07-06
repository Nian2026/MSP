# `.chat` Command Timeline Guide

Status: draft developer guidance.

Goal: read and write MSP command history as command spans, not as generic tool
calls or host shell transcripts.

## Read Versus Execute

`command-timeline` means the package contains command events.

`read_command_timeline` means an implementation can display those events.

`execute_msp_commands` means an implementation can execute MSP commands and
append resulting events.

A lightweight reader may support `read_command_timeline` without executing
anything.

## Command Span Shape

A command span starts with `command_call` and ends with `command_complete`,
`command_error`, or a cancellation event.

Important identifiers:

- `command_id`: identifies the command span.
- `call_id` or `correlation_id`: pairs related events.
- `turn_id`: links the command to a larger agent turn when applicable.

`command_call` should record:

- raw command text;
- dialect/profile;
- parse status;
- parsed script before expansion;
- expanded invocation;
- expansion diagnostics;
- current working directory;
- stdin reference or closed state;
- policy decision reference;
- source transport reference when applicable.

## Stages

Pipelines and compound command forms need stage evidence. Use stage events or an
equivalent `stage_spans` payload:

- `command_stage_started`
- `command_stage_output`
- `command_stage_completed`

For skipped work, record `skipped: true` and `skip_reason`, such as
`and_previous_failed` or `or_previous_succeeded`.

## Output

Use `command_output` or `command_stage_output` for canonical stdout/stderr.

Required distinctions:

- canonical raw output belongs in command events or blob refs;
- model-rendered text belongs in projections;
- source transport output belongs in `source_transport` or journal data.

Do not let a shortened model-facing projection overwrite canonical output.

## Exit Status

`command_complete` should include:

- `exit_status`;
- `stage_exit_codes`;
- `pipefail`;
- `negated`;
- `final_exit_formula`;
- timeout/cancel/parse/permission flags when applicable.

The final status must be derivable from stage exits, `pipefail`, and negation, or
the event must say why the formula is unavailable.

## Policy And Application Commands

Command events may need policy evidence:

- permission request and decision;
- workspace roots;
- touched paths;
- redirection targets;
- external runner policy;
- device or application capability.

Application-owned commands should declare command pack id/version, origin, stdin
contract, stdout contract, artifact contract, side-effect contract, and
capability permissions. This lets app-specific commands compose with other MSP
commands while preserving evidence.

## Source Transport

Source transport may preserve raw provider, tool, or runtime envelopes. It is
useful for heavy runtimes and parity work, but it is not a substitute for
canonical command events.

## Acceptance

A command timeline implementation is acceptable when the validator can check
call/output ordering, stage ordering, skipped work, stdout/stderr stream order,
exit formula, artifact refs, policy linkage, and unsupported command errors.
