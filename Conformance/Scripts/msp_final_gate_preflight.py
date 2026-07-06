#!/usr/bin/env python3
"""Verify real-model pressure preflight evidence for the final release gate."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from check_real_model_pressure_preflight import (
    ROOT_DIR as PREFLIGHT_ROOT_DIR,
    cases as preflight_cases,
    runner_kind as preflight_runner_kind,
)
from msp_pressure_evidence import (
    REQUIRED_MODEL,
    load_json,
    require_empty_string_list,
    string_list,
)


REQUIRED_PREFLIGHT_RUNNER_KINDS = [
    "final-gate",
    "photosorter-suite",
    "playground-suite",
    "pressure-matrix",
]
PREFLIGHT_RUNNER_PATH_BY_KIND = {
    "final-gate": "Conformance/Scripts/run_final_exec_session_release_gate.sh",
    "photosorter-suite": "Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-pressure.sh",
    "playground-suite": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-real-model-pressure.sh",
    "pressure-matrix": "Conformance/Scripts/run_real_model_pressure_matrix.sh",
}
REQUIRED_PREFLIGHT_CASE_LABELS = [
    "final_gate_disable_photosorter_cpython",
    "final_gate_disable_photosorter_reset",
    "final_gate_disable_playground_reset",
    "final_gate_disable_python",
    "final_gate_disable_python_oracle",
    "final_gate_disable_shell_diagnostic",
    "final_gate_photosorter_skip_provider",
    "final_gate_playground_skip_provider",
    "final_gate_provider_expected",
    "final_gate_provider_nonce",
    "final_gate_provider_prompt",
    "final_gate_wrong_model",
    "matrix_disable_photosorter_cpython",
    "matrix_disable_photosorter_reset",
    "matrix_disable_playground_reset",
    "matrix_disable_python",
    "matrix_disable_python_oracle",
    "matrix_disable_shell_diagnostic",
    "matrix_duplicate_suite_list",
    "matrix_final_gate_active_requires_out_dir",
    "matrix_partial_suite_list",
    "matrix_photosorter_skip_provider",
    "matrix_playground_skip_provider",
    "matrix_provider_expected",
    "matrix_provider_nonce",
    "matrix_provider_prompt",
    "matrix_wrong_model",
    "photosorter_bad_prompt_contract",
    "photosorter_disable_cpython",
    "photosorter_disable_reset",
    "photosorter_inherited_disable_reset",
    "photosorter_provider_expected",
    "photosorter_provider_nonce",
    "photosorter_provider_prompt",
    "photosorter_skip_provider",
    "photosorter_wrong_model",
    "playground_bad_prompt_contract",
    "playground_disable_python",
    "playground_disable_python_oracle",
    "playground_disable_reset",
    "playground_disable_shell_diagnostic",
    "playground_inherited_disable_reset",
    "playground_provider_expected",
    "playground_provider_nonce",
    "playground_provider_prompt",
    "playground_skip_provider",
    "playground_wrong_model",
]


def expected_preflight_runner_kind(label: str) -> str | None:
    if label.startswith("final_gate_"):
        return "final-gate"
    if label.startswith("photosorter_"):
        return "photosorter-suite"
    if label.startswith("playground_"):
        return "playground-suite"
    if label.startswith("matrix_"):
        return "pressure-matrix"
    return None


def build_preflight_case_contracts() -> dict[str, dict[str, Any]]:
    contracts: dict[str, dict[str, Any]] = {}
    for case in preflight_cases():
        contracts[case.label] = {
            "runner_kind": preflight_runner_kind(case),
            "runner": str(case.runner.relative_to(PREFLIGHT_ROOT_DIR)),
            "override_keys": sorted(case.overrides),
            "expected_stderr": case.expected_stderr,
            "forbidden_stdout": list(case.forbidden_stdout),
            "forbidden_stderr": list(case.forbidden_stderr),
        }
    return contracts


PREFLIGHT_CASE_CONTRACTS = build_preflight_case_contracts()


def verify_real_model_pressure_preflight(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("real-model pressure preflight report is not an object")
        return {}
    if report.get("passed") is not True:
        failures.append("real-model pressure preflight report did not pass")
    require_empty_string_list(report.get("failures"), "real-model pressure preflight failures", failures)
    if report.get("required_model") != REQUIRED_MODEL:
        failures.append(f"real-model pressure preflight required_model is not {REQUIRED_MODEL}")
    case_count = report.get("case_count")
    if case_count != len(REQUIRED_PREFLIGHT_CASE_LABELS):
        failures.append("real-model pressure preflight case_count does not match required coverage")
    if report.get("passed_case_count") != case_count:
        failures.append("real-model pressure preflight passed_case_count does not match case_count")
    if report.get("failed_case_count") != 0:
        failures.append("real-model pressure preflight failed_case_count is not 0")
    case_labels = string_list(
        report.get("case_labels"),
        "real-model pressure preflight case_labels",
        failures,
    )
    if case_labels != REQUIRED_PREFLIGHT_CASE_LABELS:
        failures.append("real-model pressure preflight case_labels do not match required coverage")
    required_case_labels = string_list(
        report.get("required_case_labels"),
        "real-model pressure preflight required_case_labels",
        failures,
    )
    if required_case_labels != REQUIRED_PREFLIGHT_CASE_LABELS:
        failures.append("real-model pressure preflight required_case_labels do not match verifier contract")
    runner_kinds = string_list(
        report.get("runner_kinds"),
        "real-model pressure preflight runner_kinds",
        failures,
    )
    if runner_kinds != REQUIRED_PREFLIGHT_RUNNER_KINDS:
        failures.append("real-model pressure preflight runner_kinds do not cover all required entrypoints")
    if sorted(PREFLIGHT_CASE_CONTRACTS) != REQUIRED_PREFLIGHT_CASE_LABELS:
        failures.append("real-model pressure preflight verifier contract labels do not match required coverage")
    cases = report.get("cases")
    if not isinstance(cases, list) or len(cases) != case_count:
        failures.append("real-model pressure preflight cases do not match case_count")
        cases = []
    seen_kinds = set()
    seen_labels = set()
    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            failures.append(f"real-model pressure preflight case {index} is not an object")
            continue
        label = case.get("label")
        contract = None
        if not isinstance(label, str) or not label:
            failures.append(f"real-model pressure preflight case {index} label is missing")
        elif label in seen_labels:
            failures.append(f"real-model pressure preflight case label is duplicated: {label}")
        else:
            seen_labels.add(label)
            contract = PREFLIGHT_CASE_CONTRACTS.get(label)
            if contract is None:
                failures.append(f"real-model pressure preflight case {index} has no label contract: {label}")
        if case.get("passed") is not True:
            failures.append(f"real-model pressure preflight case {index} did not pass")
        if case.get("expected_exit_code") != 2 or case.get("exit_code") != 2:
            failures.append(f"real-model pressure preflight case {index} did not prove exit code 2")
        if case.get("stderr_matched") is not True:
            failures.append(f"real-model pressure preflight case {index} did not match expected stderr")
        if case.get("forbidden_stdout_absent") is not True:
            failures.append(f"real-model pressure preflight case {index} crossed a forbidden startup boundary")
        if case.get("forbidden_stderr_absent") is not True:
            failures.append(f"real-model pressure preflight case {index} crossed a forbidden stderr startup boundary")
        kind = case.get("runner_kind")
        if contract is not None:
            override_keys = string_list(
                case.get("override_keys"),
                f"real-model pressure preflight case {index} override_keys",
                failures,
            )
            if override_keys != contract["override_keys"]:
                failures.append(
                    f"real-model pressure preflight case {index} override_keys do not match label contract: "
                    f"{label} -> {contract['override_keys']}, got {override_keys}"
                )
            if case.get("expected_stderr") != contract["expected_stderr"]:
                failures.append(
                    f"real-model pressure preflight case {index} expected_stderr does not match label contract: "
                    f"{label}"
                )
            forbidden_stdout = string_list(
                case.get("forbidden_stdout"),
                f"real-model pressure preflight case {index} forbidden_stdout",
                failures,
            )
            if forbidden_stdout != contract["forbidden_stdout"]:
                failures.append(
                    f"real-model pressure preflight case {index} forbidden_stdout does not match label contract: "
                    f"{label} -> {contract['forbidden_stdout']}, got {forbidden_stdout}"
                )
            forbidden_stderr = string_list(
                case.get("forbidden_stderr"),
                f"real-model pressure preflight case {index} forbidden_stderr",
                failures,
            )
            if forbidden_stderr != contract["forbidden_stderr"]:
                failures.append(
                    f"real-model pressure preflight case {index} forbidden_stderr does not match label contract: "
                    f"{label} -> {contract['forbidden_stderr']}, got {forbidden_stderr}"
                )
        if isinstance(kind, str):
            seen_kinds.add(kind)
            if isinstance(label, str):
                expected_kind = expected_preflight_runner_kind(label)
                if expected_kind is None:
                    failures.append(
                        f"real-model pressure preflight case {index} label has no runner_kind contract: {label}"
                    )
                elif kind != expected_kind:
                    failures.append(
                        f"real-model pressure preflight case {index} runner_kind does not match label contract: "
                        f"{label} -> {expected_kind}, got {kind}"
                    )
            expected_runner = PREFLIGHT_RUNNER_PATH_BY_KIND.get(kind)
            runner = case.get("runner")
            if expected_runner is None:
                failures.append(f"real-model pressure preflight case {index} runner_kind is unknown: {kind}")
            elif runner != expected_runner:
                failures.append(
                    f"real-model pressure preflight case {index} runner path does not match runner_kind contract: "
                    f"{kind} -> {expected_runner}"
                )
        case_failures = case.get("failures")
        if not isinstance(case_failures, list) or case_failures:
            failures.append(f"real-model pressure preflight case {index} failures are missing or non-empty")
    if sorted(seen_kinds) != REQUIRED_PREFLIGHT_RUNNER_KINDS:
        failures.append("real-model pressure preflight cases do not include every required runner kind")
    if sorted(seen_labels) != REQUIRED_PREFLIGHT_CASE_LABELS:
        failures.append("real-model pressure preflight cases do not include every required case label")
    return report
