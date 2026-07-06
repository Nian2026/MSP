#!/usr/bin/env python3
"""Build-check original and `.chat` Codex CLI source snapshots.

This source-backed evidence runner verifies that both source snapshots can provide a
`codex` CLI binary, using the shared durable build helper. It records
machine-readable build and basic user-visible CLI metadata evidence without
claiming full runtime parity.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    utc_now_iso,
    write_json,
)


GATE_FILES = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
]


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_cli(command: list[str], cwd: pathlib.Path) -> dict[str, Any]:
    started_at = time.time()
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return {
        "command": command,
        "cwd": str(cwd),
        "exit_code": completed.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def summarize_binary(path: pathlib.Path) -> dict[str, Any]:
    return {
        "path": str(path),
        "exists": path.exists(),
        "is_symlink": path.is_symlink(),
        "resolved_path": str(path.resolve()) if path.exists() else None,
        "size_bytes": path.stat().st_size if path.exists() else None,
        "sha256": sha256_file(path) if path.exists() else None,
    }


def build_tree(name: str, codex_rs: pathlib.Path, build_if_missing: bool) -> dict[str, Any]:
    binary_check = ensure_binary(codex_rs, build_if_missing)
    binary = pathlib.Path(binary_check["artifact"])
    version = run_cli([str(binary), "--version"], codex_rs)
    help_result = run_cli([str(binary), "--help"], codex_rs)
    return {
        "name": name,
        "codex_rs": str(codex_rs),
        "binary_check": binary_check,
        "binary": summarize_binary(binary),
        "external_binary": summarize_binary(pathlib.Path(binary_check["external_artifact"])),
        "version": version,
        "help": {
            "command": help_result["command"],
            "cwd": help_result["cwd"],
            "exit_code": help_result["exit_code"],
            "duration_seconds": help_result["duration_seconds"],
            "stdout_sha256": hashlib.sha256(help_result["stdout"].encode()).hexdigest(),
            "stderr": help_result["stderr"],
        },
    }


def write_report(summary: dict[str, Any], path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    original = summary["trees"]["original"]
    chat_backend = summary["trees"]["chat-backend"]
    lines = [
        f"# Codex CLI Source Snapshot Build Evidence - {summary['generated_at']}",
        "",
        "This is retained validation evidence for the `.chat` Codex backend adaptation.",
        "It documents build evidence and does not define the public `.chat` spec or prove full runtime parity.",
        "",
        "## Gate Files Read",
        "",
    ]
    lines.extend(f"- `{gate}`" for gate in summary["gate_files_read"])
    lines.extend(
        [
            "",
            "## Scope",
            "",
            "The runner checked both source snapshots:",
            "",
            "```text",
            "source-snapshots/openai-codex-original/codex-rs",
            "source-snapshots/openai-codex-chat-backend/codex-rs",
            "```",
            "",
            "Cargo build output is kept outside the source snapshots and exposed",
            "through the script-expected `target/debug/codex` entry points. Build",
            "outputs are cache, not source evidence.",
            "",
            "## Result",
            "",
            f"- status: `{summary['status']}`",
            f"- original binary exists: `{original['binary']['exists']}`",
            f"- `.chat` backend binary exists: `{chat_backend['binary']['exists']}`",
            f"- version output equal: `{summary['version_stdout_equal']}`",
            f"- help output hash equal: `{summary['help_stdout_sha256_equal']}`",
            "",
            "## Original",
            "",
            f"- snapshot entry: `{original['binary']['path']}`",
            f"- resolved artifact: `{original['binary']['resolved_path']}`",
            f"- artifact size: `{original['binary']['size_bytes']}`",
            f"- artifact sha256: `{original['binary']['sha256']}`",
            f"- cargo target dir: `{original['binary_check']['cargo_target_dir']}`",
            f"- `codex --version` exit code: `{original['version']['exit_code']}`",
            f"- `codex --version` stdout: `{original['version']['stdout'].strip()}`",
            "",
            "## `.chat` Backend",
            "",
            f"- snapshot entry: `{chat_backend['binary']['path']}`",
            f"- resolved artifact: `{chat_backend['binary']['resolved_path']}`",
            f"- artifact size: `{chat_backend['binary']['size_bytes']}`",
            f"- artifact sha256: `{chat_backend['binary']['sha256']}`",
            f"- cargo target dir: `{chat_backend['binary_check']['cargo_target_dir']}`",
            f"- `codex --version` exit code: `{chat_backend['version']['exit_code']}`",
            f"- `codex --version` stdout: `{chat_backend['version']['stdout'].strip()}`",
            "",
            "## Boundary",
            "",
            "This runner did not read or modify PhotoSorter, Xcode projects, MLX",
            "vendor paths, or any app package graph.",
            "",
            "## Limits",
            "",
        ]
    )
    lines.extend(f"- {item}" for item in summary["not_yet_proven"])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-build-source-snapshots-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument("--cargo-target-root", type=pathlib.Path)
    parser.add_argument("--report-output", type=pathlib.Path)
    args = parser.parse_args()

    if args.cargo_target_root:
        os.environ["CODEX_CHAT_VALIDATION_CARGO_TARGET_ROOT"] = str(
            args.cargo_target_root.expanduser().resolve()
        )

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    original = build_tree("original", ORIGINAL_CODEX_RS, args.build_if_missing)
    chat_backend = build_tree("chat-backend", CHAT_BACKEND_CODEX_RS, args.build_if_missing)

    version_stdout_equal = original["version"]["stdout"] == chat_backend["version"]["stdout"]
    help_stdout_sha256_equal = (
        original["help"]["stdout_sha256"] == chat_backend["help"]["stdout_sha256"]
    )
    version_exit_ok = original["version"]["exit_code"] == 0 and chat_backend["version"]["exit_code"] == 0
    help_exit_ok = original["help"]["exit_code"] == 0 and chat_backend["help"]["exit_code"] == 0
    binaries_exist = original["binary"]["exists"] and chat_backend["binary"]["exists"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-build-source-snapshots",
        "gate_files_read": GATE_FILES,
        "validation_dir": str(VALIDATION_DIR),
        "status": (
            "pass"
            if binaries_exist
            and version_exit_ok
            and help_exit_ok
            and version_stdout_equal
            and help_stdout_sha256_equal
            else "fail"
        ),
        "version_stdout_equal": version_stdout_equal,
        "help_stdout_sha256_equal": help_stdout_sha256_equal,
        "trees": {
            "original": original,
            "chat-backend": chat_backend,
        },
        "not_yet_proven": [
            "normal CLI session parity",
            "app-server runtime parity",
            "command/tool execution parity",
            "resume/running rejoin/fork/rollback/compaction parity",
            "list/search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "summary.json", summary)
    write_report(summary, output_dir / "report.md")
    if args.report_output:
        write_report(summary, args.report_output.resolve())
    return 0 if summary["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
