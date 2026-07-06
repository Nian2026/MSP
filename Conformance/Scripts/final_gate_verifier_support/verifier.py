from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from msp_final_gate_preflight import verify_real_model_pressure_preflight
from msp_pressure_evidence import (
    REQUIRED_PRESSURE_SUITES,
    load_json,
    prefixed_failures,
    require_empty_string_list,
    string_list,
    summarize_suite,
    verify_pressure_matrix_report,
)

from .artifacts import (
    require_artifact_under_report_root,
    require_canonical_artifact_path,
    require_file,
    verify_report_out_dir,
)
from .contract import (
    EXPECTED_COMPLETION_SCOPE,
    EXPECTED_EVIDENCE_RELATIVE_PATHS,
    EXPECTED_MISSING_FINAL_GATE_CLASSES,
    REQUIRED_EVIDENCE_KEYS,
    REQUIRED_STEPS,
)
from .evidence_basic import (
    verify_dynamic_embedded_cpython_swift_tests,
    verify_exec_session_stress,
    verify_open_source_release_dry_run,
    verify_readex_boundary,
)
from .evidence_oracles import (
    linux_character_oracle_alignment_summary,
    verify_core100_noninteractive,
    verify_debian_linux_pty,
    verify_debian_noninteractive,
    verify_linux_character_oracle_alignment,
    verify_live_noninteractive_linux_vps,
)
from .evidence_test_suites import (
    verify_focused_test_suites_ledger,
    verify_full_agentbridge_parity_matrix,
    verify_full_swift_test_suite,
)
from .swift_logs import verify_step_log

def verify(args: argparse.Namespace) -> dict[str, Any]:
    failures: list[str] = []
    report = load_json(args.report)
    if not isinstance(report, dict):
        return {"passed": False, "failures": ["final gate report is not an object"], "report": str(args.report)}
    report_root = args.report.resolve().parent

    if report.get("passed") is not True:
        failures.append("final gate report passed flag is not true")
    if report.get("gate") != "msp-final-exec-session-release-gate":
        failures.append("final gate report gate name is wrong")
    if report.get("completion_scope") != EXPECTED_COMPLETION_SCOPE:
        failures.append("final gate report completion_scope is not exec-session-release-gate")
    if report.get("not_final_msp_open_source_release_gate") is not True:
        failures.append("final gate report does not mark itself as a non-final MSP open-source release gate")
    if string_list(
        report.get("missing_final_gate_classes"),
        "missing_final_gate_classes",
        failures,
    ) != EXPECTED_MISSING_FINAL_GATE_CLASSES:
        failures.append("missing_final_gate_classes does not match final MSP gate blockers")
    if report.get("required_model") != args.required_model:
        failures.append(f"final gate required_model is not {args.required_model}")
    if report.get("model") != args.required_model:
        failures.append(f"final gate model is not {args.required_model}")
    if report.get("model_matches_required") is not True:
        failures.append("final gate model_matches_required is not true")
    require_empty_string_list(report.get("model_failures"), "final gate model_failures", failures)
    repository_root_raw = report.get("repository_root")
    repository_root: Path | None = None
    if not isinstance(repository_root_raw, str) or not repository_root_raw:
        failures.append("final gate repository_root is missing or not a string")
    else:
        repository_root = Path(repository_root_raw).expanduser().resolve()
    verify_report_out_dir(report, report_root, failures)

    steps = string_list(report.get("steps"), "steps", failures)
    if steps != REQUIRED_STEPS:
        failures.append("final gate steps do not match required ordered steps")

    step_logs = report.get("step_logs")
    if not isinstance(step_logs, dict):
        failures.append("step_logs is missing or not an object")
        step_logs = {}
    elif sorted(step_logs) != sorted(REQUIRED_STEPS):
        failures.append("step_logs keys do not match required steps")
    for step in REQUIRED_STEPS:
        path = require_file(step_logs.get(step), f"step_logs.{step}", failures)
        if path is not None:
            require_artifact_under_report_root(path, f"step_logs.{step}", report_root, failures)
            require_canonical_artifact_path(
                path,
                report_root / f"{step}.log",
                f"step_logs.{step}",
                failures,
            )
            verify_step_log(step, path, failures)

    if string_list(report.get("required_pressure_suites"), "required_pressure_suites", failures) != REQUIRED_PRESSURE_SUITES:
        failures.append("required_pressure_suites does not match final gate contract")

    evidence = report.get("evidence_artifacts")
    if not isinstance(evidence, dict):
        failures.append("evidence_artifacts is missing or not an object")
        evidence = {}
    elif sorted(evidence) != sorted(REQUIRED_EVIDENCE_KEYS):
        failures.append("evidence_artifacts keys do not match required evidence")
    for key in REQUIRED_EVIDENCE_KEYS:
        if key not in evidence:
            failures.append(f"evidence_artifacts missing key: {key}")

    preflight_path = require_file(evidence.get("real_model_pressure_preflight_report"), "evidence_artifacts.real_model_pressure_preflight_report", failures)
    readex_boundary_path = require_file(evidence.get("readex_boundary_report"), "evidence_artifacts.readex_boundary_report", failures)
    exec_stress_path = require_file(evidence.get("exec_session_stress_report"), "evidence_artifacts.exec_session_stress_report", failures)
    release_dry_run_path = require_file(evidence.get("open_source_release_dry_run_report"), "evidence_artifacts.open_source_release_dry_run_report", failures)
    dynamic_cpython_path = require_file(evidence.get("dynamic_embedded_cpython_swift_tests_report"), "evidence_artifacts.dynamic_embedded_cpython_swift_tests_report", failures)
    focused_ledger_path = require_file(evidence.get("focused_test_suites_ledger_report"), "evidence_artifacts.focused_test_suites_ledger_report", failures)
    full_swift_path = require_file(evidence.get("full_swift_test_suite_report"), "evidence_artifacts.full_swift_test_suite_report", failures)
    full_agentbridge_path = require_file(evidence.get("full_agentbridge_parity_matrix_report"), "evidence_artifacts.full_agentbridge_parity_matrix_report", failures)
    core100_path = require_file(evidence.get("core100_noninteractive_oracle_report"), "evidence_artifacts.core100_noninteractive_oracle_report", failures)
    noninteractive_path = require_file(evidence.get("debian12_noninteractive_oracle_report"), "evidence_artifacts.debian12_noninteractive_oracle_report", failures)
    live_noninteractive_path = require_file(evidence.get("live_noninteractive_linux_vps_oracle_report"), "evidence_artifacts.live_noninteractive_linux_vps_oracle_report", failures)
    pty_path = require_file(evidence.get("debian12_linux_pty_oracle_report"), "evidence_artifacts.debian12_linux_pty_oracle_report", failures)
    matrix_path = require_file(evidence.get("real_model_pressure_matrix_report"), "evidence_artifacts.real_model_pressure_matrix_report", failures)
    require_artifact_under_report_root(preflight_path, "evidence_artifacts.real_model_pressure_preflight_report", report_root, failures)
    require_artifact_under_report_root(readex_boundary_path, "evidence_artifacts.readex_boundary_report", report_root, failures)
    require_artifact_under_report_root(exec_stress_path, "evidence_artifacts.exec_session_stress_report", report_root, failures)
    require_artifact_under_report_root(release_dry_run_path, "evidence_artifacts.open_source_release_dry_run_report", report_root, failures)
    require_artifact_under_report_root(dynamic_cpython_path, "evidence_artifacts.dynamic_embedded_cpython_swift_tests_report", report_root, failures)
    require_artifact_under_report_root(focused_ledger_path, "evidence_artifacts.focused_test_suites_ledger_report", report_root, failures)
    require_artifact_under_report_root(full_swift_path, "evidence_artifacts.full_swift_test_suite_report", report_root, failures)
    require_artifact_under_report_root(full_agentbridge_path, "evidence_artifacts.full_agentbridge_parity_matrix_report", report_root, failures)
    require_artifact_under_report_root(core100_path, "evidence_artifacts.core100_noninteractive_oracle_report", report_root, failures)
    require_artifact_under_report_root(noninteractive_path, "evidence_artifacts.debian12_noninteractive_oracle_report", report_root, failures)
    require_artifact_under_report_root(live_noninteractive_path, "evidence_artifacts.live_noninteractive_linux_vps_oracle_report", report_root, failures)
    require_artifact_under_report_root(pty_path, "evidence_artifacts.debian12_linux_pty_oracle_report", report_root, failures)
    require_artifact_under_report_root(matrix_path, "evidence_artifacts.real_model_pressure_matrix_report", report_root, failures)
    evidence_paths = {
        "real_model_pressure_preflight_report": preflight_path,
        "readex_boundary_report": readex_boundary_path,
        "exec_session_stress_report": exec_stress_path,
        "open_source_release_dry_run_report": release_dry_run_path,
        "dynamic_embedded_cpython_swift_tests_report": dynamic_cpython_path,
        "focused_test_suites_ledger_report": focused_ledger_path,
        "full_swift_test_suite_report": full_swift_path,
        "full_agentbridge_parity_matrix_report": full_agentbridge_path,
        "core100_noninteractive_oracle_report": core100_path,
        "debian12_noninteractive_oracle_report": noninteractive_path,
        "live_noninteractive_linux_vps_oracle_report": live_noninteractive_path,
        "debian12_linux_pty_oracle_report": pty_path,
        "real_model_pressure_matrix_report": matrix_path,
    }
    for key, relative_path in EXPECTED_EVIDENCE_RELATIVE_PATHS.items():
        require_canonical_artifact_path(
            evidence_paths.get(key),
            report_root / relative_path,
            f"evidence_artifacts.{key}",
            failures,
        )

    suite_paths_raw = evidence.get("real_model_pressure_suite_reports")
    suite_paths: dict[str, Path] = {}
    if not isinstance(suite_paths_raw, dict):
        failures.append("evidence_artifacts.real_model_pressure_suite_reports is missing or not an object")
    else:
        if sorted(suite_paths_raw) != sorted(REQUIRED_PRESSURE_SUITES):
            failures.append("real_model_pressure_suite_reports does not include exactly all required suites")
        for suite in REQUIRED_PRESSURE_SUITES:
            path = require_file(
                suite_paths_raw.get(suite),
                f"evidence_artifacts.real_model_pressure_suite_reports.{suite}",
                failures,
            )
            if path is not None:
                require_artifact_under_report_root(
                    path,
                    f"evidence_artifacts.real_model_pressure_suite_reports.{suite}",
                    report_root,
                    failures,
                )
                require_canonical_artifact_path(
                    path,
                    report_root / "real-model-pressure-matrix" / suite / "pressure-report.json",
                    f"evidence_artifacts.real_model_pressure_suite_reports.{suite}",
                    failures,
                )
                suite_paths[suite] = path

    nested_reports: dict[str, Any] = {}
    if preflight_path is not None:
        nested_reports["real_model_pressure_preflight_report"] = verify_real_model_pressure_preflight(preflight_path, failures)
    if readex_boundary_path is not None:
        nested_reports["readex_boundary_report"] = verify_readex_boundary(
            readex_boundary_path,
            failures,
            repository_root,
        )
    if exec_stress_path is not None:
        nested_reports["exec_session_stress_report"] = verify_exec_session_stress(exec_stress_path, failures)
    if release_dry_run_path is not None:
        nested_reports["open_source_release_dry_run_report"] = verify_open_source_release_dry_run(
            release_dry_run_path,
            failures,
        )
    if dynamic_cpython_path is not None:
        nested_reports["dynamic_embedded_cpython_swift_tests_report"] = verify_dynamic_embedded_cpython_swift_tests(dynamic_cpython_path, failures)
    if focused_ledger_path is not None:
        nested_reports["focused_test_suites_ledger_report"] = verify_focused_test_suites_ledger(
            focused_ledger_path,
            report_root,
            step_logs,
            evidence,
            failures,
        )
    if full_swift_path is not None:
        nested_reports["full_swift_test_suite_report"] = verify_full_swift_test_suite(full_swift_path, failures)
    if full_agentbridge_path is not None:
        nested_reports["full_agentbridge_parity_matrix_report"] = verify_full_agentbridge_parity_matrix(
            full_agentbridge_path,
            failures,
        )
    if core100_path is not None:
        nested_reports["core100_noninteractive_oracle_report"] = verify_core100_noninteractive(core100_path, failures)
    if noninteractive_path is not None:
        nested_reports["debian12_noninteractive_oracle_report"] = verify_debian_noninteractive(noninteractive_path, failures)
    if live_noninteractive_path is not None:
        nested_reports["live_noninteractive_linux_vps_oracle_report"] = verify_live_noninteractive_linux_vps(
            live_noninteractive_path,
            failures,
        )
    if pty_path is not None:
        nested_reports["debian12_linux_pty_oracle_report"] = verify_debian_linux_pty(pty_path, failures)
    if matrix_path is not None:
        matrix_report, matrix_failures = verify_pressure_matrix_report(matrix_path, suite_paths, args.required_model)
        nested_reports["real_model_pressure_matrix_report"] = matrix_report
        failures.extend(matrix_failures)
    suite_summaries: dict[str, Any] = {}
    for suite, path in suite_paths.items():
        summary = summarize_suite(suite, path, args.required_model)
        suite_summaries[suite] = summary
        failures.extend(prefixed_failures(f"{suite} pressure ", summary.get("failures", [])))
    linux_character_oracle_alignment = linux_character_oracle_alignment_summary(nested_reports)
    if report.get("linux_character_oracle_alignment") != linux_character_oracle_alignment:
        failures.append("final gate linux_character_oracle_alignment does not match oracle evidence")
    verify_linux_character_oracle_alignment(linux_character_oracle_alignment, failures)

    return {
        "passed": not failures,
        "failures": failures,
        "report": str(args.report),
        "required_model": args.required_model,
        "checked_steps": len(steps),
        "checked_step_logs": len(step_logs),
        "checked_pressure_suites": sorted(suite_paths),
        "nested_report_keys": sorted(nested_reports),
        "suite_report_keys": sorted(suite_summaries),
        "linux_character_oracle_alignment": linux_character_oracle_alignment,
    }
