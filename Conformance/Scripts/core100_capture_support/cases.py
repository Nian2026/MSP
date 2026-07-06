from __future__ import annotations

from typing import Any

from .case_builder import case, file_item
from .case_catalog_data_text import add_data_text_cases
from .case_catalog_required_a import add_required_a_cases
from .case_catalog_required_b import add_required_b_cases
from .case_catalog_required_c import add_required_c_cases
from .case_catalog_shell_builtins import add_shell_builtin_cases
from .case_catalog_stress import add_stress_cases
from .case_catalog_system_encoding import add_system_encoding_cases


def generated_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []

    def add(command_name: str, rows: list[tuple[str, str, dict[str, Any] | None]]) -> None:
        for slug, command_line, kwargs in rows:
            options = dict(kwargs or {})
            commands = options.pop("commands", [command_name])
            case_prefix = options.pop("case_prefix", command_name)
            primary_command = options.pop("primary_command", command_name)
            cases.append(case(f"core100-{case_prefix}-{slug}", command_line, commands, primary_command=primary_command, **options))

    def add_required(command_name: str, rows: list[tuple[str, str, dict[str, Any] | None]]) -> None:
        safe_prefix = {
            ":": "colon",
            "[": "bracket",
            "[[": "double-bracket",
        }.get(command_name, command_name)
        for slug, command_line, kwargs in rows:
            options = dict(kwargs or {})
            commands = options.pop("commands", [command_name])
            primary_command = options.pop("primary_command", command_name)
            cases.append(case(f"core100-required-{safe_prefix}-{slug}", command_line, commands, primary_command=primary_command, **options))

    shell_file = file_item("script.env", "VAR_FROM_SOURCE=sourced\ncd sub\n")
    source_file = file_item("source.sh", "VALUE=from_source\nmark() { printf 'mark:%s\\n' \"$1\"; }\n")

    for add_cases in (
        add_required_a_cases,
        add_required_b_cases,
        add_required_c_cases,
        add_shell_builtin_cases,
        add_data_text_cases,
        add_system_encoding_cases,
    ):
        add_cases(add, add_required, file_item, shell_file, source_file)
    add_stress_cases(cases, case)

    return cases
