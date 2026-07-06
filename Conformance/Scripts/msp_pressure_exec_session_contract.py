"""Exec-session evidence checks for MSP pressure event logs."""

from __future__ import annotations

from typing import Any

from msp_pressure_event_fields import events_named, field, field_int


def exec_session_contract_summary(events: list[dict[str, Any]]) -> dict[str, int]:
    exec_before = events_named(events, "probe_agent_runtime_bridge_run_before")
    exec_after = events_named(events, "probe_agent_runtime_bridge_run_after")
    stdin_before = events_named(events, "probe_agent_runtime_bridge_write_stdin_before")
    stdin_after = events_named(events, "probe_agent_runtime_bridge_write_stdin_after")
    tool_completed = events_named(events, "tool_completed")
    return {
        "exec_before_count": len(exec_before),
        "exec_after_count": len(exec_after),
        "stdin_before_count": len(stdin_before),
        "stdin_after_count": len(stdin_after),
        "bounded_yield_exec_count": len([event for event in exec_before if (field_int(event, "yield_time_ms") or 0) > 0]),
        "yielded_session_count": len([event for event in exec_after if field(event, "session_id")]),
        "running_envelope_count": len([event for event in tool_completed if "Process running with session ID" in field(event, "content_text")]),
        "exited_envelope_count": len([event for event in tool_completed if "Process exited with code" in field(event, "content_text")]),
        "pty_exec_count": len([event for event in exec_before if field(event, "tty").lower() == "true"]),
        "poll_write_count": len([event for event in stdin_before if field(event, "chars_kind") == "empty_poll"]),
        "input_write_count": len([event for event in stdin_before if field(event, "chars_kind") == "input"]),
        "interrupt_write_count": len([event for event in stdin_before if field(event, "chars_kind") == "interrupt"]),
    }


def validate_exec_session_contract(summary: dict[str, int]) -> list[str]:
    failures = []
    if summary["bounded_yield_exec_count"] <= 0:
        failures.append("exec-session contract did not observe an exec_command with yield_time_ms")
    if summary["yielded_session_count"] <= 0:
        failures.append("exec-session contract did not observe a yielded running session id")
    if summary["running_envelope_count"] <= 0:
        failures.append("exec-session contract did not observe Process running with session ID")
    if summary["exited_envelope_count"] <= 0:
        failures.append("exec-session contract did not observe Process exited with code")
    if summary["pty_exec_count"] <= 0:
        failures.append("exec-session contract did not observe tty=true exec_command")
    if summary["poll_write_count"] <= 0:
        failures.append("exec-session contract did not observe empty write_stdin poll")
    if summary["input_write_count"] <= 0:
        failures.append("exec-session contract did not observe non-empty interactive write_stdin")
    if summary["interrupt_write_count"] <= 0:
        failures.append("exec-session contract did not observe Ctrl-C write_stdin")
    return failures
