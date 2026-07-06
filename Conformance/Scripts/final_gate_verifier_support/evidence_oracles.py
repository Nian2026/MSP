from __future__ import annotations

from pathlib import Path
from typing import Any

from msp_pressure_evidence import load_json, require_empty_string_list, string_list

from .artifacts import looks_linux

REQUIRED_CORE100_COMMAND_BUCKETS = [
    "pwd",
    "ls",
    "find",
    "xargs",
    "cat",
    "rm",
    "mv",
    "mkdir",
    "rmdir",
    "stat",
    "chmod",
    "ln",
    "touch",
    "mktemp",
    "printf",
    "grep",
    "awk",
    "sed",
    "sort",
    "head",
    "tail",
    "wc",
    "python3",
    "sh",
    "source",
    "test",
    "read",
    "umask",
    "dd",
    "od",
    "strings",
    "xxd",
]

REQUIRED_CORE100_CASE_IDS = [
    "stress-s0-pipeline-basic",
    "stress-s0-redirection-basic",
    "stress-s0-group-redirection",
    "stress-s1-many-redirections",
    "core100-source-cwd",
    "core100-source-fd",
    "core100-required-mktemp-tmpdir-relative",
    "core100-required-cat-large-file-short-consumer",
    "stress-s2-large-directory-find-head",
    "core100-required-find-exec-plus",
    "core100-required-xargs-batch",
    "stress-s2-xargs-batching-long-input",
    "core100-required-rm-recursive-relative",
    "core100-required-mv-target-dir",
    "core100-required-cat-missing",
    "core100-required-chmod-missing",
    "core100-dd-space-path",
    "core100-required-cat-binary-passthrough",
    "core100-required-sort-long-input-stress-count",
    "core100-required-grep-recursive-include-exclude",
]

REQUIRED_DEBIAN_NONINTERACTIVE_CASE_IDS = [
    "existing-coreutils-text-pipeline",
    "complex-dash-heredoc-functions-case",
    "complex-bash-process-substitution-arrays",
    "complex-dash-posix-ifs-glob-trap",
    "overlong-single-line-command",
    "python-subprocess-file-side-effects",
    "python-binary-stdout-stderr-bytes",
    "python-error-branch-permissions",
    "node-fs-child-process-side-effects",
    "stdin-binary-od-roundtrip",
    "permissions-umask-chmod-side-effects",
    "find-symlink-realpath-readlink",
    "existing-find-print0-xargs-weird-names",
    "find-print0-sortz-while-copy-unicode",
    "python-pathlib-stat-rglob-writeback",
    "binary-stdout-stderr-null-bytes",
]

REQUIRED_DEBIAN_PTY_CASE_IDS = [
    "pty_basic_split",
    "pty_stderr_exit",
    "pty_ctrl_d_eof",
    "pty_ctrl_c",
    "pty_quoted_pipe_payload",
    "pty_long_canonical_12000",
    "pty_stty_noecho",
    "pty_python_heredoc_exit",
    "pty_erase_delete",
    "pty_ctrl_u_kill_line",
    "pty_ctrl_w_erase_word",
    "pty_shell_pipeline_wc",
    "pty_shell_heredoc_cat",
    "pty_shell_redirection_order",
    "pty_stdin_loop_utf8",
    "pty_python_large_output_4k",
    "pty_live_grep_sed_pipeline",
    "pty_live_long_stdin_wc_12000",
    "pty_live_python_stdin_script_split",
    "pty_live_python_stdin_script_stderr_exit",
]

LINUX_CHARACTER_ORACLE_REPORT_KEYS = [
    "core100_noninteractive_oracle_report",
    "debian12_noninteractive_oracle_report",
    "live_noninteractive_linux_vps_oracle_report",
    "debian12_linux_pty_oracle_report",
]

LINUX_CHARACTER_ORACLE_SCOPE = [
    "stdout",
    "stderr",
    "exit code",
    "file tree",
    "cwd",
    "path errors",
    "permission errors",
    "Python traceback",
    "PTY bytes",
]


def linux_character_oracle_alignment_summary(reports: dict[str, Any]) -> dict[str, Any]:
    oracle_reports = {
        key: reports.get(key)
        for key in LINUX_CHARACTER_ORACLE_REPORT_KEYS
        if isinstance(reports.get(key), dict)
    }
    selected_counts = [value.get("selectedCaseCount") for value in oracle_reports.values()]
    passed_counts = [value.get("passedCaseCount") for value in oracle_reports.values()]
    failed_counts = [value.get("failedCaseCount") for value in oracle_reports.values()]
    compatibility_adjustments = []
    for key, value in oracle_reports.items():
        adjustments = value.get("compatibilityAdjustments")
        if isinstance(adjustments, list) and adjustments:
            compatibility_adjustments.append({"report": key, "adjustments": adjustments})

    all_counts_present = all(isinstance(value, int) for value in selected_counts + passed_counts + failed_counts)
    total_selected = sum(value for value in selected_counts if isinstance(value, int))
    total_passed = sum(value for value in passed_counts if isinstance(value, int))
    total_failed = sum(value for value in failed_counts if isinstance(value, int))
    return {
        "kind": "linux-character-level-oracle-alignment",
        "oracle_report_keys": LINUX_CHARACTER_ORACLE_REPORT_KEYS,
        "checked_report_keys": sorted(oracle_reports),
        "scope": LINUX_CHARACTER_ORACLE_SCOPE,
        "total_selected_case_count": total_selected,
        "total_passed_case_count": total_passed,
        "total_failed_case_count": total_failed,
        "all_counts_present": all_counts_present,
        "all_character_oracle_cases_passed": (
            sorted(oracle_reports) == sorted(LINUX_CHARACTER_ORACLE_REPORT_KEYS)
            and all_counts_present
            and total_selected == total_passed
            and total_failed == 0
        ),
        "compatibility_adjustments_empty": not compatibility_adjustments,
        "compatibility_adjustments": compatibility_adjustments,
    }


def verify_linux_character_oracle_alignment(summary: Any, failures: list[str]) -> None:
    if not isinstance(summary, dict):
        failures.append("final gate linux_character_oracle_alignment is not an object")
        return
    if summary.get("all_counts_present") is not True:
        failures.append("final gate linux_character_oracle_alignment did not prove all oracle counts")
    if summary.get("all_character_oracle_cases_passed") is not True:
        failures.append("final gate linux_character_oracle_alignment did not prove all character oracle cases passed")
    if summary.get("compatibility_adjustments_empty") is not True:
        failures.append("final gate linux_character_oracle_alignment did not prove empty compatibility adjustments")
    if summary.get("total_failed_case_count") != 0:
        failures.append("final gate linux_character_oracle_alignment total_failed_case_count is not 0")
    selected = summary.get("total_selected_case_count")
    passed = summary.get("total_passed_case_count")
    if not isinstance(selected, int) or not isinstance(passed, int) or selected != passed:
        failures.append("final gate linux_character_oracle_alignment selected and passed case counts do not match")


def verify_core100_noninteractive(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("Core100 noninteractive oracle report is not an object")
        return {}
    if report.get("failedCaseCount") != 0:
        failures.append("Core100 noninteractive oracle has failed cases")
    require_empty_string_list(report.get("failedCaseIDs"), "Core100 noninteractive failedCaseIDs", failures)
    if not isinstance(report.get("failures"), list) or report.get("failures"):
        failures.append("Core100 noninteractive failures is missing or non-empty")
    if report.get("selectedCaseCount") != 905 or report.get("passedCaseCount") != 905:
        failures.append("Core100 noninteractive oracle did not pass all 905 fixture cases")
    passed_case_ids = string_list(
        report.get("passedCaseIDs"),
        "Core100 noninteractive passedCaseIDs",
        failures,
    )
    if len(set(passed_case_ids)) != 905:
        failures.append("Core100 noninteractive passedCaseIDs does not contain 905 unique cases")
    for case_id in REQUIRED_CORE100_CASE_IDS:
        if case_id not in passed_case_ids:
            failures.append(f"Core100 noninteractive oracle missing required passed case id: {case_id}")
    selected_command_counts = report.get("selectedCommandCounts")
    if not isinstance(selected_command_counts, dict) or len(selected_command_counts) < 100:
        failures.append("Core100 noninteractive oracle covers fewer than 100 command buckets")
        selected_command_counts = {}
    for command in REQUIRED_CORE100_COMMAND_BUCKETS:
        count = selected_command_counts.get(command)
        if not isinstance(count, int) or count <= 0:
            failures.append(f"Core100 noninteractive oracle missing required command bucket: {command}")
    failed_layer_counts = report.get("failedLikelyLayerCounts")
    if not isinstance(failed_layer_counts, dict) or failed_layer_counts:
        failures.append("Core100 noninteractive failedLikelyLayerCounts is missing or non-empty")
    return report


def verify_debian_noninteractive(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("Debian noninteractive oracle report is not an object")
        return {}
    if report.get("failedCaseCount") != 0:
        failures.append("Debian noninteractive oracle has failed cases")
    require_empty_string_list(report.get("failedCaseIDs"), "Debian noninteractive failedCaseIDs", failures)
    if not isinstance(report.get("failures"), list) or report.get("failures"):
        failures.append("Debian noninteractive failures is missing or non-empty")
    if report.get("selectedCaseCount") != 50 or report.get("passedCaseCount") != 50:
        failures.append("Debian noninteractive oracle did not pass all 50 fixture cases")
    passed_case_ids = string_list(
        report.get("passedCaseIDs"),
        "Debian noninteractive passedCaseIDs",
        failures,
    )
    if len(set(passed_case_ids)) != 50:
        failures.append("Debian noninteractive passedCaseIDs does not contain 50 unique cases")
    for case_id in REQUIRED_DEBIAN_NONINTERACTIVE_CASE_IDS:
        if case_id not in passed_case_ids:
            failures.append(f"Debian noninteractive oracle missing required passed case id: {case_id}")
    return report


def verify_live_noninteractive_linux_vps(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("live noninteractive Linux VPS oracle report is not an object")
        return {}
    if report.get("gate") != "msp-live-noninteractive-linux-vps-oracle":
        failures.append("live noninteractive Linux VPS oracle gate is wrong")
    if report.get("artifactKind") != "msp-live-noninteractive-linux-vps-oracle":
        failures.append("live noninteractive Linux VPS oracle artifactKind is wrong")
    if report.get("passed") is not True:
        failures.append("live noninteractive Linux VPS oracle report did not pass")
    if report.get("liveRun") is not True:
        failures.append("live noninteractive Linux VPS oracle did not prove a live run")
    if report.get("runnerBackend") != "ssh-linux-vps":
        failures.append("live noninteractive Linux VPS oracle runnerBackend is not ssh-linux-vps")
    if not isinstance(report.get("runnerHost"), str) or not report.get("runnerHost"):
        failures.append("live noninteractive Linux VPS oracle runnerHost is missing")
    if not looks_linux({
        "runnerPlatform": "\n".join([
            str(report.get("runnerSystem") or ""),
            str(report.get("runnerPlatform") or ""),
            str(report.get("runnerOSRelease") or ""),
        ])
    }):
        failures.append("live noninteractive Linux VPS oracle runner is not proven Linux/Debian")
    os_release = str(report.get("runnerOSRelease") or "").lower()
    platform = str(report.get("runnerPlatform") or "").lower()
    debian12 = ("id=debian" in os_release or "debian" in platform or "debian" in os_release) and (
        'version_id="12"' in os_release or "version_id=12" in os_release or "bookworm" in os_release
    )
    if not debian12:
        failures.append("live noninteractive Linux VPS oracle runner is not proven Debian 12/bookworm")
    if report.get("failedCaseCount") != 0:
        failures.append("live noninteractive Linux VPS oracle has failed cases")
    require_empty_string_list(
        report.get("failedCaseIDs"),
        "live noninteractive Linux VPS failedCaseIDs",
        failures,
    )
    if not isinstance(report.get("failures"), list) or report.get("failures"):
        failures.append("live noninteractive Linux VPS failures is missing or non-empty")
    runner_failures = report.get("runnerFailures")
    if not isinstance(runner_failures, list) or runner_failures:
        failures.append("live noninteractive Linux VPS runnerFailures is missing or non-empty")
    if report.get("fixtureCaseCount") != 50:
        failures.append("live noninteractive Linux VPS oracle fixtureCaseCount is not 50")
    if report.get("selectedCaseCount") != 50 or report.get("passedCaseCount") != 50:
        failures.append("live noninteractive Linux VPS oracle did not pass all 50 fixture cases")
    passed_ids = string_list(
        report.get("passedCaseIDs"),
        "live noninteractive Linux VPS passedCaseIDs",
        failures,
    )
    if len(set(passed_ids)) != 50:
        failures.append("live noninteractive Linux VPS passedCaseIDs does not contain 50 unique cases")
    for case_id in REQUIRED_DEBIAN_NONINTERACTIVE_CASE_IDS:
        if case_id not in passed_ids:
            failures.append(f"live noninteractive Linux VPS oracle missing required passed case id: {case_id}")
    compatibility = report.get("compatibilityAdjustments")
    if not isinstance(compatibility, list) or compatibility:
        failures.append("live noninteractive Linux VPS compatibilityAdjustments is missing or non-empty")
    return report


def verify_debian_linux_pty(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("Debian Linux PTY oracle report is not an object")
        return {}
    if report.get("failedCaseCount") != 0:
        failures.append("Debian Linux PTY oracle has failed cases")
    require_empty_string_list(report.get("failedCaseIDs"), "Debian Linux PTY failedCaseIDs", failures)
    if not isinstance(report.get("failures"), list) or report.get("failures"):
        failures.append("Debian Linux PTY failures is missing or non-empty")
    if report.get("selectedCaseCount") != 157 or report.get("passedCaseCount") != 157:
        failures.append("Debian Linux PTY oracle did not pass all 157 fixture cases")
    passed_case_ids = string_list(
        report.get("passedCaseIDs"),
        "Debian Linux PTY passedCaseIDs",
        failures,
    )
    if len(set(passed_case_ids)) != 157:
        failures.append("Debian Linux PTY passedCaseIDs does not contain 157 unique cases")
    for case_id in REQUIRED_DEBIAN_PTY_CASE_IDS:
        if case_id not in passed_case_ids:
            failures.append(f"Debian Linux PTY oracle missing required passed case id: {case_id}")
    if not looks_linux(report):
        failures.append("Debian Linux PTY oracle runner is not proven Linux/Debian")
    compatibility = report.get("compatibilityAdjustments")
    if not isinstance(compatibility, list) or compatibility:
        failures.append("Debian Linux PTY oracle compatibilityAdjustments is missing or non-empty")
    return report
