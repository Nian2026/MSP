#!/usr/bin/env python3
"""Validate real-model pressure prompts before expensive UI runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

from msp_pressure_contract import REQUIRED_PROMPT_FILES, REQUIRED_SENTINELS
from msp_pressure_json_support import EXPECTED_FEEDBACK_FIELDS


SENTINEL_RE = re.compile(r"最终回答最后一行必须只写[:：]\s*([A-Z0-9_]+)")

FORBIDDEN_EXECUTION_DISCLOSURES = [
    ("iOS", re.compile(r"\biOS\b", re.IGNORECASE)),
    ("sandbox", re.compile(r"\bsandbox\b", re.IGNORECASE)),
    ("沙盒", re.compile(r"沙盒")),
    ("MSP", re.compile(r"\bMSP\b")),
    ("ModelShellProxy", re.compile(r"\bModelShellProxy\b")),
    ("broker", re.compile(r"\bbroker\b", re.IGNORECASE)),
    ("materialized", re.compile(r"\bmateriali[sz]ed\b", re.IGNORECASE)),
    ("launcher", re.compile(r"\blauncher\b", re.IGNORECASE)),
    ("runtime", re.compile(r"\bruntime\b", re.IGNORECASE)),
    ("CoreSimulator", re.compile(r"\bCoreSimulator\b", re.IGNORECASE)),
    ("app container", re.compile(r"\bapp container\b", re.IGNORECASE)),
    ("Containers/Data/Application", re.compile(r"Containers/Data/Application", re.IGNORECASE)),
    ("PhotoKit", re.compile(r"\bPhotoKit\b", re.IGNORECASE)),
    ("PHAsset", re.compile(r"\bPHAsset\b")),
    ("localIdentifier", re.compile(r"\blocalIdentifier\b")),
    ("virtual", re.compile(r"\bvirtual\b", re.IGNORECASE)),
    ("虚拟", re.compile(r"虚拟")),
    ("虚拟后端", re.compile(r"虚拟后端")),
    ("真实底层路径", re.compile(r"真实底层路径")),
    ("真实宿主目录", re.compile(r"真实宿主目录")),
    ("底层实现", re.compile(r"底层实现")),
    ("内部运行时路径", re.compile(r"内部运行时路径")),
]

FINAL_PROMPT_REQUIRED_PHRASES = [
    "不要再运行命令",
    "只根据前面",
    "不要猜测底层环境",
    "真 Linux 工作区",
    "iOS 沙盒路径",
    "broker 路径",
    "materialized 路径",
    "suspicious_outputs",
    "leaked_internal_paths",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and normalize a real-model pressure prompt JSON array."
    )
    parser.add_argument("prompts", type=Path, help="Prompt JSON array to validate.")
    return parser.parse_args()


def load_prompts(path: Path) -> list[str]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"pressure prompts file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"pressure prompts file is not valid JSON: {path}: {exc}") from exc
    if not isinstance(raw, list) or not raw:
        raise ValueError("pressure prompts must be a non-empty JSON array")
    if any(not isinstance(item, str) or not item.strip() for item in raw):
        raise ValueError("pressure prompts must be non-empty strings")
    return list(raw)


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def display_path(path: Path, root_dir: Path | None = None) -> str:
    resolved = path.resolve()
    if root_dir is None:
        root_dir = repository_root()
    try:
        return resolved.relative_to(root_dir.resolve()).as_posix()
    except ValueError:
        return str(resolved)


def prompt_file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prompt_text_sha256s(prompts: list[str]) -> list[str]:
    return [hashlib.sha256(prompt.encode("utf-8")).hexdigest() for prompt in prompts]


def execution_disclosure_failures(prompt: str, index: int) -> list[str]:
    failures: list[str] = []
    for label, pattern in FORBIDDEN_EXECUTION_DISCLOSURES:
        if pattern.search(prompt):
            failures.append(f"pressure prompt {index} discloses implementation term before feedback: {label}")
    for field in EXPECTED_FEEDBACK_FIELDS:
        if field in prompt:
            failures.append(f"pressure prompt {index} asks for feedback field before final prompt: {field}")
    return failures


def validate_prompts(prompts: list[str]) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    if len(prompts) < 2:
        failures.append("pressure prompts must include at least one task prompt and one final feedback prompt")
        return [], failures

    task_prompts = prompts[:-1]
    final_prompt = prompts[-1]
    sentinels: list[str] = []
    seen_sentinels: set[str] = set()
    for index, prompt in enumerate(task_prompts):
        matches = SENTINEL_RE.findall(prompt)
        if len(matches) != 1:
            failures.append(f"pressure prompt {index} must contain exactly one final sentinel instruction")
        elif matches[0] in seen_sentinels:
            failures.append(f"pressure prompt {index} repeats final sentinel: {matches[0]}")
        elif not matches[0].endswith("_DONE"):
            failures.append(f"pressure prompt {index} sentinel must end with _DONE: {matches[0]}")
        else:
            sentinels.append(matches[0])
            seen_sentinels.add(matches[0])
        failures.extend(execution_disclosure_failures(prompt, index))

    if SENTINEL_RE.search(final_prompt):
        failures.append("pressure final feedback prompt must not include a task completion sentinel")
    for field in EXPECTED_FEEDBACK_FIELDS:
        if field not in final_prompt:
            failures.append(f"pressure final feedback prompt missing feedback field: {field}")
    for phrase in FINAL_PROMPT_REQUIRED_PHRASES:
        if phrase not in final_prompt:
            failures.append(f"pressure final feedback prompt missing required phrase: {phrase}")
    return sentinels, failures


def emit_runner_payload(prompts: list[str], sentinels: list[str]) -> None:
    print(json.dumps(prompts, ensure_ascii=False, separators=(",", ":")))
    print(len(prompts))
    print(json.dumps(sentinels, ensure_ascii=True, separators=(",", ":")))


def prompt_contract_evidence(path: Path, root_dir: Path | None = None) -> dict[str, Any]:
    prompts = load_prompts(path)
    sentinels, failures = validate_prompts(prompts)
    if failures:
        raise ValueError("\n".join(failures))
    return {
        "passed": True,
        "failures": [],
        "path": display_path(path, root_dir),
        "sha256": prompt_file_sha256(path),
        "prompt_count": len(prompts),
        "required_final_sentinels": sentinels,
    }


def prompt_delivery_contract(path: Path, root_dir: Path | None = None) -> dict[str, Any]:
    prompts = load_prompts(path)
    return {
        "path": display_path(path, root_dir),
        "hash_algorithm": "sha256-utf8",
        "prompt_count": len(prompts),
        "prompt_sha256s": prompt_text_sha256s(prompts),
    }


def prompt_contract_error(path: Path, message: str, root_dir: Path | None = None) -> dict[str, Any]:
    return {
        "passed": False,
        "failures": [message],
        "path": display_path(path, root_dir),
    }


def expected_prompt_contract_for_suite(suite: str) -> dict[str, Any]:
    relative_path = REQUIRED_PROMPT_FILES.get(suite)
    if relative_path is None:
        raise ValueError(f"unknown pressure suite prompt contract: {suite}")
    evidence = prompt_contract_evidence(repository_root() / relative_path, repository_root())
    required_sentinels = REQUIRED_SENTINELS.get(suite, [])
    if evidence["required_final_sentinels"] != required_sentinels:
        raise ValueError(
            "canonical pressure prompts do not match suite sentinels: "
            f"{suite}: {evidence['required_final_sentinels']} != {required_sentinels}"
        )
    return evidence


def expected_prompt_delivery_for_suite(suite: str) -> dict[str, Any]:
    relative_path = REQUIRED_PROMPT_FILES.get(suite)
    if relative_path is None:
        raise ValueError(f"unknown pressure suite prompt delivery contract: {suite}")
    return prompt_delivery_contract(repository_root() / relative_path, repository_root())


def main() -> int:
    args = parse_args()
    try:
        prompts = load_prompts(args.prompts)
        sentinels, failures = validate_prompts(prompts)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 2
    emit_runner_payload(prompts, sentinels)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
