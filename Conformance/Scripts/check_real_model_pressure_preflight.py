#!/usr/bin/env python3
"""Check that real-model pressure runners reject weakened preflight settings."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
FINAL_GATE_RUNNER = ROOT_DIR / "Conformance/Scripts/run_final_exec_session_release_gate.sh"
MATRIX_RUNNER = ROOT_DIR / "Conformance/Scripts/run_real_model_pressure_matrix.sh"
PLAYGROUND_RUNNER = ROOT_DIR / "Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-real-model-pressure.sh"
PHOTOSORTER_RUNNER = ROOT_DIR / "Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-pressure.sh"
REQUIRED_MODEL = "gpt-5.5"

BASELINE_KEYS = [
    "MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD",
    "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
    "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
    "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
    "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
    "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT",
    "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
    "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
    "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
    "MSP_PLAYGROUND_PRESSURE_RESET_APP",
    "MSP_PLAYGROUND_E2E_RESET_APP",
    "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
    "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
    "MSP_PHOTOSORTER_PRESSURE_RESET_APP",
    "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
    "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES",
    "MSP_REAL_MODEL_PRESSURE_MATRIX_FAIL_FAST",
    "MSP_FINAL_EXEC_SESSION_GATE_OUT_DIR",
    "MSP_FINAL_EXEC_SESSION_GATE_TMPDIR",
    "MSP_FINAL_EXEC_SESSION_GATE_ACTIVE",
]


@dataclass(frozen=True)
class PreflightCase:
    label: str
    runner: Path
    overrides: dict[str, str]
    expected_stderr: str
    forbidden_stdout: tuple[str, ...]
    forbidden_stderr: tuple[str, ...] = ()
    generated_files: dict[str, str] = field(default_factory=dict)


BAD_PRESSURE_PROMPTS_JSON = json.dumps(
    [
        (
            "请运行 pwd。这个任务运行在 iOS 沙盒里的 MSP。\n\n"
            "最终回答最后一行必须只写：BAD_PROMPT_DONE"
        ),
        (
            "只根据前面几轮你亲眼看到的命令输出回答，不要再运行命令。"
            "请严格输出一个 JSON 对象，不要 Markdown，不要解释，字段如下：\n\n"
            "{\n"
            "  \"looks_like_regular_linux\": true 或 false,\n"
            "  \"can_distinguish_from_regular_linux\": true 或 false,\n"
            "  \"suspicious_outputs\": [字符串数组],\n"
            "  \"leaked_internal_paths\": [字符串数组],\n"
            "  \"notes\": \"一句话说明\"\n"
            "}\n\n"
            "判断标准：不要猜测底层环境，只根据前面可见输出判断它是否能和真 Linux 工作区区分。"
            "如果你看到了 iOS 沙盒路径、broker 路径、materialized 路径，必须放进 leaked_internal_paths。"
        ),
    ],
    ensure_ascii=False,
    indent=2,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check real-model pressure preflight hardening before expensive UI pressure runs."
    )
    parser.add_argument("--report", type=Path, help="Optional JSON report path to write.")
    return parser.parse_args()


def matrix_case(label: str, overrides: dict[str, str], expected_stderr: str) -> PreflightCase:
    return PreflightCase(
        label=f"matrix_{label}",
        runner=MATRIX_RUNNER,
        overrides=overrides,
        expected_stderr=expected_stderr,
        forbidden_stdout=(
            "real-model pressure matrix lock:",
            "== running pressure suite:",
        ),
    )


def final_gate_case(label: str, overrides: dict[str, str], expected_stderr: str) -> PreflightCase:
    return PreflightCase(
        label=f"final_gate_{label}",
        runner=FINAL_GATE_RUNNER,
        overrides=overrides,
        expected_stderr=expected_stderr,
        forbidden_stdout=(
            "final release gate lock:",
            "== final gate step:",
        ),
    )


def suite_case(
    label: str,
    runner: Path,
    overrides: dict[str, str],
    expected_stderr: str,
    forbidden_stderr: tuple[str, ...] = (),
    generated_files: dict[str, str] | None = None,
) -> PreflightCase:
    return PreflightCase(
        label=label,
        runner=runner,
        overrides=overrides,
        expected_stderr=expected_stderr,
        forbidden_stdout=(
            "real-model UI pressure lock:",
            "provider smoke passed",
        ),
        forbidden_stderr=forbidden_stderr,
        generated_files=generated_files or {},
    )


def cases() -> list[PreflightCase]:
    final_gate_cases = [
        final_gate_case(
            "wrong_model",
            {"MSP_PLAYGROUND_MODEL": "gpt-4.1"},
            "MSP_PLAYGROUND_MODEL must be exactly gpt-5.5 for the final release gate; got gpt-4.1",
        ),
        final_gate_case(
            "playground_skip_provider",
            {"MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE": "1"},
            "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the final release gate",
        ),
        final_gate_case(
            "photosorter_skip_provider",
            {"MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE": "1"},
            "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the final release gate",
        ),
        final_gate_case(
            "provider_nonce",
            {"MSP_PLAYGROUND_PROVIDER_CHECK_NONCE": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the final release gate",
        ),
        final_gate_case(
            "provider_prompt",
            {"MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the final release gate",
        ),
        final_gate_case(
            "provider_expected",
            {"MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT": "MSP_PROVIDER_OK_deadbeefcafebabe"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT is not allowed in the final release gate",
        ),
        final_gate_case(
            "disable_python",
            {"MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON": "0"},
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=0 is not allowed in the final release gate",
        ),
        final_gate_case(
            "disable_shell_diagnostic",
            {"MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC": "0"},
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=0 is not allowed in the final release gate",
        ),
        final_gate_case(
            "disable_python_oracle",
            {"MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE": "0"},
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=0 is not allowed in the final release gate",
        ),
        final_gate_case(
            "disable_playground_reset",
            {"MSP_PLAYGROUND_PRESSURE_RESET_APP": "0"},
            "MSP_PLAYGROUND_PRESSURE_RESET_APP=0 is not allowed in the final release gate",
        ),
        final_gate_case(
            "disable_photosorter_cpython",
            {"MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON": "0"},
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0 is not allowed in the final release gate",
        ),
        final_gate_case(
            "disable_photosorter_reset",
            {"MSP_PHOTOSORTER_PRESSURE_RESET_APP": "0"},
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP=0 is not allowed in the final release gate",
        ),
    ]
    playground_cases = [
        suite_case(
            "playground_wrong_model",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_MODEL": "gpt-4.1"},
            "MSP_PLAYGROUND_MODEL must be exactly gpt-5.5 for the real-model pressure suite; got gpt-4.1",
        ),
        suite_case(
            "playground_bad_prompt_contract",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE": "{case_dir}/bad-pressure-prompts.json"},
            "pressure prompt 0 discloses implementation term before feedback",
            forbidden_stderr=("host-backed pressure requires CPython",),
            generated_files={"bad-pressure-prompts.json": BAD_PRESSURE_PROMPTS_JSON},
        ),
        suite_case(
            "playground_skip_provider",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE": "1"},
            "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_disable_python",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON": "0"},
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_disable_shell_diagnostic",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC": "0"},
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_disable_python_oracle",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE": "0"},
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_disable_reset",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PRESSURE_RESET_APP": "0"},
            "MSP_PLAYGROUND_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_inherited_disable_reset",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_E2E_RESET_APP": "0"},
            "MSP_PLAYGROUND_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_provider_nonce",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PROVIDER_CHECK_NONCE": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_provider_prompt",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "playground_provider_expected",
            PLAYGROUND_RUNNER,
            {"MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT": "MSP_PROVIDER_OK_deadbeefcafebabe"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT is not allowed in the real-model pressure suite",
        ),
    ]
    photosorter_cases = [
        suite_case(
            "photosorter_wrong_model",
            PHOTOSORTER_RUNNER,
            {"MSP_PLAYGROUND_MODEL": "gpt-4.1"},
            "MSP_PLAYGROUND_MODEL must be exactly gpt-5.5 for the real-model pressure suite; got gpt-4.1",
        ),
        suite_case(
            "photosorter_bad_prompt_contract",
            PHOTOSORTER_RUNNER,
            {"MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE": "{case_dir}/bad-pressure-prompts.json"},
            "pressure prompt 0 discloses implementation term before feedback",
            forbidden_stderr=("PhotoSorter pressure requires CPython",),
            generated_files={"bad-pressure-prompts.json": BAD_PRESSURE_PROMPTS_JSON},
        ),
        suite_case(
            "photosorter_skip_provider",
            PHOTOSORTER_RUNNER,
            {"MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE": "1"},
            "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "photosorter_disable_cpython",
            PHOTOSORTER_RUNNER,
            {"MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON": "0"},
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "photosorter_disable_reset",
            PHOTOSORTER_RUNNER,
            {"MSP_PHOTOSORTER_PRESSURE_RESET_APP": "0"},
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "photosorter_inherited_disable_reset",
            PHOTOSORTER_RUNNER,
            {"MSP_PLAYGROUND_E2E_RESET_APP": "0"},
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP=0 is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "photosorter_provider_nonce",
            PHOTOSORTER_RUNNER,
            {"MSP_PLAYGROUND_PROVIDER_CHECK_NONCE": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "photosorter_provider_prompt",
            PHOTOSORTER_RUNNER,
            {"MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the real-model pressure suite",
        ),
        suite_case(
            "photosorter_provider_expected",
            PHOTOSORTER_RUNNER,
            {"MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT": "MSP_PROVIDER_OK_deadbeefcafebabe"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT is not allowed in the real-model pressure suite",
        ),
    ]
    matrix_cases = [
        matrix_case(
            "wrong_model",
            {"MSP_PLAYGROUND_MODEL": "gpt-4.1"},
            "MSP_PLAYGROUND_MODEL must be exactly gpt-5.5 for the real-model pressure matrix; got gpt-4.1",
        ),
        matrix_case(
            "partial_suite_list",
            {"MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES": "host-backed"},
            "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES must include every required suite; missing: exec-session mixed-backend photosorter-virtual photosorter-exec-session",
        ),
        matrix_case(
            "duplicate_suite_list",
            {"MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES": "host-backed,host-backed,exec-session,mixed-backend,photosorter-virtual,photosorter-exec-session"},
            "duplicate pressure suite in MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES: host-backed",
        ),
        matrix_case(
            "final_gate_active_requires_out_dir",
            {
                "MSP_FINAL_EXEC_SESSION_GATE_ACTIVE": "1",
                "MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR": "",
            },
            "MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR is required when the matrix is launched from the final release gate",
        ),
        matrix_case(
            "playground_skip_provider",
            {"MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE": "1"},
            "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "photosorter_skip_provider",
            {"MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE": "1"},
            "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "provider_nonce",
            {"MSP_PLAYGROUND_PROVIDER_CHECK_NONCE": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "provider_prompt",
            {"MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT": "fixed"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "provider_expected",
            {"MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT": "MSP_PROVIDER_OK_deadbeefcafebabe"},
            "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "disable_python",
            {"MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON": "0"},
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=0 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "disable_shell_diagnostic",
            {"MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC": "0"},
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=0 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "disable_python_oracle",
            {"MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE": "0"},
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=0 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "disable_playground_reset",
            {"MSP_PLAYGROUND_PRESSURE_RESET_APP": "0"},
            "MSP_PLAYGROUND_PRESSURE_RESET_APP=0 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "disable_photosorter_cpython",
            {"MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON": "0"},
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0 is not allowed in the real-model pressure matrix",
        ),
        matrix_case(
            "disable_photosorter_reset",
            {"MSP_PHOTOSORTER_PRESSURE_RESET_APP": "0"},
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP=0 is not allowed in the real-model pressure matrix",
        ),
    ]
    return final_gate_cases + matrix_cases + playground_cases + photosorter_cases


def baseline_environment(temp_root: Path, label: str) -> dict[str, str]:
    environment = os.environ.copy()
    for key in BASELINE_KEYS:
        environment.pop(key, None)
    environment["MSP_PLAYGROUND_MODEL_BASE_URL"] = "https://example.invalid/v1"
    environment["MSP_PLAYGROUND_MODEL_API_KEY"] = "dummy"
    environment["MSP_PLAYGROUND_MODEL"] = REQUIRED_MODEL
    environment["MSP_FINAL_EXEC_SESSION_GATE_OUT_DIR"] = str(temp_root / label / "final-gate")
    environment["MSP_FINAL_EXEC_SESSION_GATE_TMPDIR"] = str(temp_root / label / "final-gate-tmp")
    environment["MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR"] = str(temp_root / label / "matrix")
    environment["MSP_PLAYGROUND_PRESSURE_OUT_DIR"] = str(temp_root / label / "playground")
    environment["MSP_PHOTOSORTER_PRESSURE_OUT_DIR"] = str(temp_root / label / "photosorter")
    return environment


def runner_kind(case: PreflightCase) -> str:
    if case.runner == FINAL_GATE_RUNNER:
        return "final-gate"
    if case.runner == MATRIX_RUNNER:
        return "pressure-matrix"
    if case.runner == PLAYGROUND_RUNNER:
        return "playground-suite"
    if case.runner == PHOTOSORTER_RUNNER:
        return "photosorter-suite"
    return "unknown"


def run_case(case: PreflightCase, temp_root: Path) -> dict[str, object]:
    case_dir = temp_root / case.label
    case_dir.mkdir(parents=True, exist_ok=True)
    for relative_path, content in case.generated_files.items():
        target = case_dir / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    environment = baseline_environment(temp_root, case.label)
    overrides = {
        key: value.format(case_dir=str(case_dir))
        for key, value in case.overrides.items()
    }
    environment.update(overrides)
    result = subprocess.run(
        ["/bin/bash", str(case.runner)],
        cwd=ROOT_DIR,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    failures: list[str] = []
    if result.returncode != 2:
        failures.append(f"expected exit code 2, got {result.returncode}")
    if case.expected_stderr not in result.stderr:
        failures.append(f"missing expected stderr: {case.expected_stderr!r}")
    for forbidden in case.forbidden_stdout:
        if forbidden in result.stdout:
            failures.append(f"stdout contains forbidden preflight-past marker: {forbidden!r}")
    for forbidden in case.forbidden_stderr:
        if forbidden in result.stderr:
            failures.append(f"stderr contains forbidden preflight-past marker: {forbidden!r}")

    passed = not failures
    if passed:
        print(f"{case.label}: ok")
    else:
        print(f"{case.label}: failed", file=sys.stderr)

    report: dict[str, object] = {
        "label": case.label,
        "runner_kind": runner_kind(case),
        "runner": str(case.runner.relative_to(ROOT_DIR)),
        "override_keys": sorted(overrides),
        "expected_exit_code": 2,
        "exit_code": result.returncode,
        "expected_stderr": case.expected_stderr,
        "stderr_matched": case.expected_stderr in result.stderr,
        "forbidden_stdout": list(case.forbidden_stdout),
        "forbidden_stdout_absent": not any(marker in result.stdout for marker in case.forbidden_stdout),
        "forbidden_stderr": list(case.forbidden_stderr),
        "forbidden_stderr_absent": not any(marker in result.stderr for marker in case.forbidden_stderr),
        "passed": passed,
        "failures": failures,
    }
    if failures:
        report["stdout"] = result.stdout
        report["stderr"] = result.stderr
    return report


def write_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    args = parse_args()
    case_reports: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="msp-pressure-preflight-") as raw_temp_root:
        temp_root = Path(raw_temp_root)
        for case in cases():
            case_reports.append(run_case(case, temp_root))

    failures = [
        f"{report['label']}: " + "; ".join(report["failures"])  # type: ignore[index]
        for report in case_reports
        if report.get("failures")
    ]
    report = {
        "passed": not failures,
        "required_model": REQUIRED_MODEL,
        "case_count": len(case_reports),
        "passed_case_count": sum(1 for case_report in case_reports if case_report.get("passed") is True),
        "failed_case_count": sum(1 for case_report in case_reports if case_report.get("passed") is not True),
        "case_labels": sorted(str(case_report.get("label")) for case_report in case_reports),
        "required_case_labels": sorted(case.label for case in cases()),
        "runner_kinds": sorted({str(case_report.get("runner_kind")) for case_report in case_reports}),
        "failures": failures,
        "cases": case_reports,
    }
    if args.report:
        write_report(args.report, report)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1

    print("real-model pressure preflight checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
