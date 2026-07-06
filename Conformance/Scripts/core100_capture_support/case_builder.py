from __future__ import annotations

import base64
import os
from pathlib import Path
from typing import Any

from .config import DEFAULT_KNOWN_HOSTS


def b64(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.b64encode(data).decode("ascii")


def default_known_hosts_path() -> Path | None:
    configured = os.environ.get("MSP_VPS_KNOWN_HOSTS")
    if configured:
        return Path(configured)
    if DEFAULT_KNOWN_HOSTS.exists():
        return DEFAULT_KNOWN_HOSTS
    return None


def default_identity_file_path() -> Path | None:
    configured = os.environ.get("MSP_VPS_IDENTITY_FILE")
    if configured:
        return Path(configured)
    return None


def ssh_config_path_value(path: Path) -> str:
    value = str(path)
    value = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{value}"'


def file_item(path: str, content: bytes | str = "", mode: str = "0644") -> dict[str, Any]:
    return {"path": path, "content_b64": b64(content), "mode": mode}


def case(
    case_id: str,
    command_line: str,
    commands: list[str],
    *,
    primary_command: str | None = None,
    title: str | None = None,
    shell: str = "bash",
    category: str = "core100-command-options",
    directories: list[str] | None = None,
    files: list[dict[str, Any]] | None = None,
    stdin: bytes | str = b"",
    compare_fields: list[str] | None = None,
    timeout_seconds: float = 5.0,
) -> dict[str, Any]:
    return {
        "id": case_id,
        "title": title or case_id.replace("-", " "),
        "category": category,
        "case_type": "noninteractive",
        "shell": {
            "dialect": shell,
            "argv": ["/bin/sh"] if shell == "sh" else ["/bin/bash", "--noprofile", "--norc"],
        },
        "primary_command": primary_command,
        "commands": commands,
        "command_line": command_line,
        "standard_input_b64": b64(stdin if isinstance(stdin, bytes) else stdin.encode("utf-8")),
        "fixture": {
            "kind": "isolated-temp-tree",
            "directories": directories or [],
            "files": files or [],
        },
        "compare_fields": compare_fields or ["stdout", "stderr", "exit_code", "file_tree", "permissions", "side_effects"],
        "timeout_seconds": timeout_seconds,
    }
