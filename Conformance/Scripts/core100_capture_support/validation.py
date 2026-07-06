from __future__ import annotations

import base64
import re
from pathlib import Path
from typing import Any

from .config import (
    ALLOWED_ABSOLUTE_SNIPPETS,
    CASE_ID_RE,
    COMMAND_NAME_RE,
    FORBIDDEN_ABSOLUTE_PREFIXES,
    FORBIDDEN_PATTERNS,
    MAX_CASES_PER_RUN,
    MAX_COMMAND_LINE_BYTES,
    MAX_FIXTURE_DIRECTORIES,
    MAX_FIXTURE_FILES,
    MAX_FIXTURE_FILE_BYTES,
    MAX_STDIN_BYTES,
    SAFE_RELATIVE_PATH_RE,
)


def validate_relative_path(value: str, field: str, findings: list[str]) -> None:
    path = Path(value)
    if not value or value in {".", "./"} or path.is_absolute() or ".." in path.parts:
        findings.append(f"{field} escapes case root: {value!r}")
    if "\x00" in value or "\n" in value or "\r" in value:
        findings.append(f"{field} contains control characters: {value!r}")
    if not SAFE_RELATIVE_PATH_RE.fullmatch(value):
        findings.append(f"{field} contains unsupported characters: {value!r}")


def strip_allowed_absolute(text: str) -> str:
    stripped = text
    for snippet in ALLOWED_ABSOLUTE_SNIPPETS:
        stripped = re.sub(
            r"(?<![A-Za-z0-9._/-])" + re.escape(snippet) + r"(?![A-Za-z0-9._/-])",
            "",
            stripped,
        )
    return stripped


def validate_command_text(case_id: str, text: str, findings: list[str]) -> None:
    encoded_length = len(text.encode("utf-8"))
    if encoded_length > MAX_COMMAND_LINE_BYTES:
        findings.append(f"{case_id}: command_line exceeds {MAX_COMMAND_LINE_BYTES} bytes")
    if "\x00" in text:
        findings.append(f"{case_id}: command_line contains NUL byte")
    haystack = strip_allowed_absolute(text)
    for pattern in FORBIDDEN_PATTERNS:
        if re.search(pattern, haystack):
            findings.append(f"{case_id}: forbidden command pattern {pattern!r}")
    for prefix in FORBIDDEN_ABSOLUTE_PREFIXES:
        if re.search(r"(^|[\s'\"=])" + re.escape(prefix) + r"(/|[\s'\";]|$)", haystack):
            findings.append(f"{case_id}: forbidden absolute host path {prefix}")
    if re.search(r"(^|[\s;])/\s*($|[;&|])", haystack):
        findings.append(f"{case_id}: forbidden root path operand")
    if re.search(r"(^|[\s=<>])/(?!tmp/msp-oracle-capture-|bin/sh(?:\s|$)|bin/bash(?:\s|$)|usr/bin/env(?:\s|$))[A-Za-z._-]", haystack):
        findings.append(f"{case_id}: forbidden absolute path in command text")
    if re.search(r"\bhostname\s+[^-\s][^;\n]*", haystack):
        findings.append(f"{case_id}: hostname setter shape is forbidden")


def validate_case_count(cases: list[dict[str, Any]], findings: list[str]) -> None:
    if len(cases) > MAX_CASES_PER_RUN:
        findings.append(f"case file contains {len(cases)} cases; max is {MAX_CASES_PER_RUN}")


def validate_cases(cases: list[dict[str, Any]]) -> list[str]:
    findings: list[str] = []
    validate_case_count(cases, findings)
    seen: set[str] = set()
    for item in cases:
        case_id = item.get("id")
        if not isinstance(case_id, str) or not CASE_ID_RE.fullmatch(case_id):
            findings.append(f"invalid case id: {case_id!r}")
            continue
        if case_id in seen:
            findings.append(f"duplicate case id: {case_id}")
        seen.add(case_id)
        command_line = item.get("command_line")
        if not isinstance(command_line, str) or not command_line:
            findings.append(f"{case_id}: command_line must be non-empty string")
        else:
            validate_command_text(case_id, command_line, findings)
        commands = item.get("commands", [])
        if not isinstance(commands, list):
            findings.append(f"{case_id}: commands must be a list")
        else:
            for command_name in commands:
                if not isinstance(command_name, str) or not COMMAND_NAME_RE.fullmatch(command_name):
                    findings.append(f"{case_id}: invalid command name in commands: {command_name!r}")
        primary_command = item.get("primary_command")
        if primary_command is not None:
            if not isinstance(primary_command, str) or not COMMAND_NAME_RE.fullmatch(primary_command):
                findings.append(f"{case_id}: invalid primary_command: {primary_command!r}")
            elif isinstance(commands, list) and primary_command not in commands:
                findings.append(f"{case_id}: primary_command must be listed in commands: {primary_command!r}")
        shell = item.get("shell", {})
        if shell.get("dialect") not in {"sh", "bash"}:
            findings.append(f"{case_id}: shell dialect must be sh or bash")
        fixture = item.get("fixture", {})
        directories = fixture.get("directories", [])
        files = fixture.get("files", [])
        if not isinstance(directories, list):
            findings.append(f"{case_id}: fixture.directories must be a list")
            directories = []
        if not isinstance(files, list):
            findings.append(f"{case_id}: fixture.files must be a list")
            files = []
        if len(directories) > MAX_FIXTURE_DIRECTORIES:
            findings.append(f"{case_id}: too many fixture directories: {len(directories)}")
        if len(files) > MAX_FIXTURE_FILES:
            findings.append(f"{case_id}: too many fixture files: {len(files)}")
        for directory in directories:
            if not isinstance(directory, str):
                findings.append(f"{case_id}: directory path must be string")
                continue
            validate_relative_path(directory, f"{case_id}.fixture.directories", findings)
        for file_record in files:
            if not isinstance(file_record, dict):
                findings.append(f"{case_id}: fixture file record must be object")
                continue
            path = file_record.get("path")
            if not isinstance(path, str):
                findings.append(f"{case_id}: file path must be string")
                continue
            validate_relative_path(path, f"{case_id}.fixture.files", findings)
            content_b64 = file_record.get("content_b64")
            if not isinstance(content_b64, str):
                findings.append(f"{case_id}: file content_b64 must be string")
            else:
                try:
                    decoded = base64.b64decode(content_b64, validate=True)
                except Exception:
                    findings.append(f"{case_id}: file content_b64 is invalid base64")
                else:
                    if len(decoded) > MAX_FIXTURE_FILE_BYTES:
                        findings.append(f"{case_id}: fixture file exceeds {MAX_FIXTURE_FILE_BYTES} bytes: {path!r}")
            mode = file_record.get("mode", "0644")
            if not isinstance(mode, str) or not re.fullmatch(r"[0-7]{3,4}", mode):
                findings.append(f"{case_id}: fixture file mode must be octal string: {mode!r}")
        standard_input = item.get("standard_input_b64", "")
        if not isinstance(standard_input, str):
            findings.append(f"{case_id}: standard_input_b64 must be string")
        else:
            try:
                decoded_stdin = base64.b64decode(standard_input, validate=True)
            except Exception:
                findings.append(f"{case_id}: standard_input_b64 is invalid base64")
            else:
                if len(decoded_stdin) > MAX_STDIN_BYTES:
                    findings.append(f"{case_id}: standard_input_b64 exceeds {MAX_STDIN_BYTES} bytes")
        timeout = item.get("timeout_seconds", 5)
        if not isinstance(timeout, (int, float)) or timeout <= 0 or timeout > 20:
            findings.append(f"{case_id}: timeout_seconds must be in 0..20")
    return findings
