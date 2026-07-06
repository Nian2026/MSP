"""Suite and matrix verification for MSP real-model pressure evidence."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from msp_pressure_contract import (
    EXEC_SESSION_CONTRACT_SUITES,
    REQUIRED_MODEL,
    REQUIRED_PROMPT_FILES,
    REQUIRED_PRESSURE_SUITES,
    REQUIRED_SENTINELS,
    required_pressure_turn_count,
)
from msp_pressure_event_log import (
    compare_report_to_event_log,
    exec_session_contract_summary,
    extract_json_object,
    field,
    find_forbidden_leaks,
    leak_kind_summary,
    load_events,
    model_request_summary,
    verify_pressure_event_log_report,
)
from msp_pressure_json_support import (
    load_json,
    require_empty_string_list,
    require_feedback_schema,
    string_list,
    write_json_report,
)
from msp_pressure_matrix_summary import (
    FEEDBACK_CORE_FIELDS,
    MODEL_RESPONSE_PROVENANCE_CORE_FIELDS,
    PROMPT_CONTRACT_CORE_FIELDS,
    PROMPT_DELIVERY_CORE_FIELDS,
    PROVIDER_SMOKE_CORE_FIELDS,
    compare_core_fields,
    validate_matrix_feedback,
    validate_matrix_model_request_built,
    validate_matrix_model_response_provenance,
    validate_matrix_prompt_contract,
    validate_matrix_prompt_delivery,
    validate_matrix_provider_smoke,
)
from msp_pressure_prompt_contract import expected_prompt_contract_for_suite, expected_prompt_delivery_for_suite
from msp_pressure_provider_smoke import (
    build_provider_smoke_evidence,
    provider_smoke_artifact_path,
    provider_smoke_prompt_text,
    provider_smoke_response_text,
    verify_provider_smoke,
)


def summarize_suite(name: str, report_path: Path, required_model: str = REQUIRED_MODEL) -> dict[str, Any]:
    failures: list[str] = []
    try:
        report = load_json(report_path)
    except ValueError as exc:
        return {"name": name, "report": str(report_path), "passed": False, "failures": [str(exc)]}
    if not isinstance(report, dict):
        return {"name": name, "report": str(report_path), "passed": False, "failures": ["suite report is not an object"]}

    if report.get("passed") is not True:
        failures.append("suite report passed flag is not true")
    reported_failures = report.get("failures")
    if not isinstance(reported_failures, list) or any(not isinstance(item, str) for item in reported_failures):
        failures.append("suite report failures is not a string array")
    elif reported_failures:
        failures.append("suite report contains failures: " + "; ".join(reported_failures))

    if report.get("required_model") != required_model:
        failures.append(f"suite report required_model is not {required_model}")
    if report.get("model") != required_model:
        failures.append(f"suite report model is not {required_model}")
    if report.get("model_matches_required") is not True:
        failures.append("suite report model_matches_required is not true")
    require_empty_string_list(report.get("model_failures"), "suite report model_failures", failures)

    required_turn_count = required_pressure_turn_count(name)
    model_request_built = report.get("model_request_built")
    if not isinstance(model_request_built, dict):
        failures.append("model_request_built is missing or not an object")
        model_request_built = {}
    count = model_request_built.get("count")
    expected_count = model_request_built.get("expected_count")
    if not isinstance(count, int) or count <= 0:
        failures.append("model_request_built.count must be positive")
    if not isinstance(expected_count, int) or expected_count <= 0:
        failures.append("model_request_built.expected_count must be positive")
    else:
        if expected_count != required_turn_count:
            failures.append(f"model_request_built.expected_count does not match required pressure turn count: {expected_count} != {required_turn_count}")
        if isinstance(count, int) and count < expected_count:
            failures.append(f"model_request_built.count is below expected_count: {count} < {expected_count}")
    if model_request_built.get("models") != [required_model]:
        failures.append(f"model_request_built.models is not exactly [{required_model}]")
    request_layers = model_request_built.get("request_layers")
    if not isinstance(request_layers, list) or len(request_layers) < required_turn_count:
        failures.append("model_request_built.request_layers does not cover required pressure turn count")
    elif isinstance(count, int) and len(request_layers) != count:
        failures.append("model_request_built.request_layers count does not match model_request_built.count")
    elif any(layer != "runtime_provider" for layer in request_layers):
        failures.append("model_request_built.request_layers are not all runtime_provider")
    if model_request_built.get("all_match_required") is not True:
        failures.append("model_request_built.all_match_required is not true")
    require_empty_string_list(model_request_built.get("failures"), "model_request_built.failures", failures)

    feedback = report.get("feedback")
    if not isinstance(feedback, dict):
        failures.append("feedback is missing or not an object")
        feedback = {}
    require_feedback_schema(feedback, "feedback", failures)
    if feedback.get("looks_like_regular_linux") is not True:
        failures.append("model feedback says the suite did not look like regular Linux")
    if feedback.get("can_distinguish_from_regular_linux") is not False:
        failures.append("model feedback says it can distinguish the suite from regular Linux")
    require_empty_string_list(feedback.get("suspicious_outputs"), "feedback.suspicious_outputs", failures)
    require_empty_string_list(feedback.get("leaked_internal_paths"), "feedback.leaked_internal_paths", failures)
    scanner_leaks = report.get("scanner_leaks")
    if not isinstance(scanner_leaks, list):
        failures.append("scanner_leaks is not an array")
        scanner_leaks = []
    elif scanner_leaks:
        failures.append("scanner found model-visible internal path leaks: " + leak_kind_summary(scanner_leaks))
    provider_smoke = verify_provider_smoke(report.get("provider_smoke"), failures, report_path.parent, required_model)
    model_response_provenance = validate_matrix_model_response_provenance(
        name,
        report.get("model_response_provenance"),
        failures,
        required_turn_count,
    )
    expected_prompt_contract: dict[str, Any] = {}
    try:
        expected_prompt_contract = expected_prompt_contract_for_suite(name)
    except ValueError as exc:
        failures.append(f"canonical prompt_contract is invalid: {exc}")
    prompt_contract = validate_matrix_prompt_contract(
        name,
        report.get("prompt_contract"),
        failures,
        REQUIRED_PROMPT_FILES.get(name, ""),
        str(expected_prompt_contract.get("sha256", "")),
        required_turn_count,
        REQUIRED_SENTINELS.get(name, []),
    )
    expected_prompt_delivery: dict[str, Any] = {}
    try:
        expected_prompt_delivery = expected_prompt_delivery_for_suite(name)
    except ValueError as exc:
        failures.append(f"canonical prompt_delivery is invalid: {exc}")
    prompt_delivery = validate_matrix_prompt_delivery(
        name,
        report.get("prompt_delivery"),
        failures,
        expected_prompt_delivery,
        required_turn_count,
    )

    exec_session_contract = report.get("exec_session_contract")
    if name in EXEC_SESSION_CONTRACT_SUITES:
        if not isinstance(exec_session_contract, dict):
            failures.append("exec_session_contract is missing or not an object")
            exec_session_contract = {}
        for key in [
            "bounded_yield_exec_count",
            "yielded_session_count",
            "running_envelope_count",
            "exited_envelope_count",
            "pty_exec_count",
            "poll_write_count",
            "input_write_count",
            "interrupt_write_count",
        ]:
            if not isinstance(exec_session_contract.get(key), int) or exec_session_contract.get(key) <= 0:
                failures.append(f"exec_session_contract.{key} must be positive")

    observed_sentinels = report.get("required_final_sentinels")
    if not isinstance(observed_sentinels, list) or any(not isinstance(item, str) for item in observed_sentinels):
        failures.append("required_final_sentinels is not a string array")
        observed_sentinels = []
    missing = [sentinel for sentinel in REQUIRED_SENTINELS.get(name, []) if sentinel not in observed_sentinels]
    if missing:
        failures.append("missing required sentinels: " + ", ".join(missing))

    event_summary = compare_report_to_event_log(name, report, report_path, failures, required_model)
    evidence_scanner_leaks = scanner_leaks
    event_scanner_leaks = event_summary.get("scanner_leaks") if isinstance(event_summary, dict) else None
    if isinstance(event_scanner_leaks, list) and event_scanner_leaks:
        evidence_scanner_leaks = event_scanner_leaks
    return {
        "name": name,
        "report": str(report_path),
        "passed": not failures,
        "failures": failures,
        "event_log": report.get("event_log"),
        "required_final_sentinels": observed_sentinels,
        "required_final_sentinel_answer_indices": report.get("required_final_sentinel_answer_indices"),
        "required_model": report.get("required_model"),
        "model": report.get("model"),
        "model_matches_required": report.get("model_matches_required"),
        "model_failures": report.get("model_failures"),
        "model_request_built": model_request_built,
        "final_answer_count": report.get("final_answer_count"),
        "tool_started_count": report.get("tool_started_count"),
        "tool_completed_count": report.get("tool_completed_count"),
        "feedback": feedback,
        "scanner_leaks": evidence_scanner_leaks,
        "model_response_provenance": model_response_provenance,
        "prompt_contract": prompt_contract,
        "prompt_delivery": prompt_delivery,
        "provider_smoke": provider_smoke,
        "exec_session_contract": exec_session_contract,
    }


def prefixed_failures(prefix: str, failures: list[str]) -> list[str]:
    return [prefix + failure for failure in failures]


def verify_pressure_matrix_report(
    matrix_path: Path,
    suite_paths: dict[str, Path],
    required_model: str = REQUIRED_MODEL,
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    report = load_json(matrix_path)
    if not isinstance(report, dict):
        return {}, ["pressure matrix report is not an object"]
    if report.get("matrix_passed") is not True:
        failures.append("pressure matrix did not pass")
    if report.get("required_model") != required_model:
        failures.append(f"pressure matrix required_model is not {required_model}")
    if report.get("model") != required_model:
        failures.append(f"pressure matrix model is not {required_model}")
    if report.get("model_matches_required") is not True:
        failures.append("pressure matrix model_matches_required is not true")
    require_empty_string_list(report.get("model_failures"), "pressure matrix model_failures", failures)
    if report.get("all_required_suites_present") is not True:
        failures.append("pressure matrix did not include all required suites")
    require_empty_string_list(report.get("missing_suites"), "pressure matrix missing_suites", failures)
    if report.get("required_suites") != REQUIRED_PRESSURE_SUITES:
        failures.append("pressure matrix required_suites does not match final gate contract")
    if report.get("suite_count") != len(REQUIRED_PRESSURE_SUITES):
        failures.append(f"pressure matrix suite_count is not {len(REQUIRED_PRESSURE_SUITES)}")
    suites = report.get("suites")
    if not isinstance(suites, dict):
        failures.append("pressure matrix suites is missing or not an object")
        suites = {}
    elif sorted(suites) != sorted(REQUIRED_PRESSURE_SUITES):
        failures.append("pressure matrix suites keys do not match required pressure suites")
    for suite in REQUIRED_PRESSURE_SUITES:
        summary = suites.get(suite)
        if not isinstance(summary, dict):
            failures.append(f"pressure matrix missing suite summary: {suite}")
            continue
        if summary.get("name") != suite:
            failures.append(f"pressure matrix {suite} name does not match suite id")
        expected_suite_summary = summarize_suite(suite, suite_paths.get(suite, Path("")), required_model) if suite in suite_paths else None
        if isinstance(summary.get("report"), str) and suite in suite_paths:
            if Path(summary["report"]).resolve() != suite_paths[suite].resolve():
                failures.append(f"pressure matrix {suite} report path does not match final evidence")
        if summary.get("passed") is not True:
            failures.append(f"pressure matrix suite did not pass: {suite}")
        for failure in summary.get("failures", []) if isinstance(summary.get("failures"), list) else ["failures is not a string array"]:
            failures.append(f"pressure matrix {suite} {failure}")
        validate_matrix_model_request_built(
            suite,
            summary.get("model_request_built"),
            failures,
            required_model,
            required_pressure_turn_count(suite),
        )
        validate_matrix_model_response_provenance(
            suite,
            summary.get("model_response_provenance"),
            failures,
            required_pressure_turn_count(suite),
        )
        validate_matrix_provider_smoke(suite, summary.get("provider_smoke"), failures, required_model)
        validate_matrix_feedback(suite, summary.get("feedback"), failures)
        expected_prompt_contract: dict[str, Any] = {}
        try:
            expected_prompt_contract = expected_prompt_contract_for_suite(suite)
        except ValueError as exc:
            failures.append(f"pressure matrix {suite} canonical prompt_contract is invalid: {exc}")
        validate_matrix_prompt_contract(
            suite,
            summary.get("prompt_contract"),
            failures,
            REQUIRED_PROMPT_FILES.get(suite, ""),
            str(expected_prompt_contract.get("sha256", "")),
            required_pressure_turn_count(suite),
            REQUIRED_SENTINELS.get(suite, []),
        )
        expected_prompt_delivery: dict[str, Any] = {}
        try:
            expected_prompt_delivery = expected_prompt_delivery_for_suite(suite)
        except ValueError as exc:
            failures.append(f"pressure matrix {suite} canonical prompt_delivery is invalid: {exc}")
        validate_matrix_prompt_delivery(
            suite,
            summary.get("prompt_delivery"),
            failures,
            expected_prompt_delivery,
            required_pressure_turn_count(suite),
        )
        if expected_suite_summary is not None:
            for key in ["required_model", "model", "model_matches_required", "model_failures", "passed", "failures"]:
                if summary.get(key) != expected_suite_summary.get(key):
                    failures.append(f"pressure matrix {suite} {key} does not match suite report evidence")
            for key in [
                "event_log",
                "final_answer_count",
                "tool_started_count",
                "tool_completed_count",
                "required_final_sentinels",
                "required_final_sentinel_answer_indices",
                "exec_session_contract",
                "model_response_provenance",
                "prompt_contract",
                "prompt_delivery",
            ]:
                if summary.get(key) != expected_suite_summary.get(key):
                    failures.append(f"pressure matrix {suite} {key} does not match suite report evidence")
            compare_core_fields(
                suite,
                "model_request_built",
                summary.get("model_request_built"),
                expected_suite_summary.get("model_request_built"),
                ["count", "expected_count", "request_layers", "models", "all_match_required", "failures"],
                failures,
            )
            compare_core_fields(
                suite,
                "provider_smoke",
                summary.get("provider_smoke"),
                expected_suite_summary.get("provider_smoke"),
                PROVIDER_SMOKE_CORE_FIELDS,
                failures,
            )
            compare_core_fields(
                suite,
                "model_response_provenance",
                summary.get("model_response_provenance"),
                expected_suite_summary.get("model_response_provenance"),
                MODEL_RESPONSE_PROVENANCE_CORE_FIELDS,
                failures,
            )
            compare_core_fields(
                suite,
                "prompt_contract",
                summary.get("prompt_contract"),
                expected_suite_summary.get("prompt_contract"),
                PROMPT_CONTRACT_CORE_FIELDS,
                failures,
            )
            compare_core_fields(
                suite,
                "prompt_delivery",
                summary.get("prompt_delivery"),
                expected_suite_summary.get("prompt_delivery"),
                PROMPT_DELIVERY_CORE_FIELDS,
                failures,
            )
            compare_core_fields(
                suite,
                "feedback",
                summary.get("feedback"),
                expected_suite_summary.get("feedback"),
                FEEDBACK_CORE_FIELDS,
                failures,
            )
            if summary.get("scanner_leaks") != expected_suite_summary.get("scanner_leaks"):
                failures.append(f"pressure matrix {suite} scanner_leaks does not match suite report evidence")
    return report, failures
