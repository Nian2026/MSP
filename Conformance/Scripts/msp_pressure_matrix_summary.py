"""Pressure matrix summary validation helpers."""

from __future__ import annotations

import re
from typing import Any

from msp_pressure_json_support import require_empty_string_list, require_feedback_schema


PLACEHOLDER_PROVIDER_OUTPUTS = {
    "MSP_PROVIDER_OK_deadbeefcafebabe",
    "MSP_PROVIDER_OK_0000000000000000",
    "MSP_PROVIDER_OK_1111111111111111",
    "MSP_PROVIDER_OK_2222222222222222",
}
PLACEHOLDER_PROVIDER_RESPONSE_IDS = {"resp_synthetic", "resp_mock", "resp_placeholder"}
PROVIDER_SMOKE_CORE_FIELDS = [
    "checked",
    "request",
    "response",
    "request_model",
    "request_model_matches_required",
    "expected_output",
    "actual_output",
    "request_artifact_model",
    "request_artifact_expected_output",
    "response_artifact_id",
    "response_artifact_object",
    "response_artifact_actual_output",
]
PROMPT_CONTRACT_CORE_FIELDS = [
    "passed",
    "failures",
    "path",
    "sha256",
    "prompt_count",
    "required_final_sentinels",
]
PROMPT_DELIVERY_CORE_FIELDS = [
    "passed",
    "failures",
    "path",
    "hash_algorithm",
    "prompt_count",
    "prompt_sha256s",
    "auto_submit_sequence_loaded_count",
    "auto_submit_count",
    "auto_submit_indices",
    "model_request_count",
    "model_request_layers",
    "model_request_last_user_input_sha256s",
    "model_request_prompt_match_indices",
    "final_answer_request_last_user_input_sha256s",
]
MODEL_RESPONSE_PROVENANCE_CORE_FIELDS = [
    "passed",
    "failures",
    "model_response_completed_count",
    "model_response_final_answer_count",
    "final_answer_count",
    "completed_response_ids",
    "final_answer_response_ids",
    "final_answer_sources",
    "final_answer_completed",
    "completed_model_request_layers",
    "completed_model_request_refs",
    "final_answer_model_request_layers",
    "final_answer_model_request_refs",
    "final_answer_request_last_user_input_sha256s",
    "final_answer_text_sha256s",
]
FEEDBACK_CORE_FIELDS = [
    "looks_like_regular_linux",
    "can_distinguish_from_regular_linux",
    "suspicious_outputs",
    "leaked_internal_paths",
    "notes",
]
def validate_matrix_model_request_built(
    suite: str,
    model_request_built: Any,
    failures: list[str],
    required_model: str,
    required_turn_count: int,
) -> dict[str, Any]:
    prefix = f"pressure matrix {suite} model_request_built"
    if not isinstance(model_request_built, dict):
        failures.append(f"{prefix} is missing or not an object")
        return {}
    count = model_request_built.get("count")
    expected_count = model_request_built.get("expected_count")
    if not isinstance(count, int) or count <= 0:
        failures.append(f"{prefix}.count must be positive")
    if not isinstance(expected_count, int) or expected_count <= 0:
        failures.append(f"{prefix}.expected_count must be positive")
    else:
        if expected_count != required_turn_count:
            failures.append(
                f"{prefix}.expected_count does not match required pressure turn count: "
                f"{expected_count} != {required_turn_count}"
            )
        if isinstance(count, int) and count < expected_count:
            failures.append(f"{prefix}.count is below expected_count: {count} < {expected_count}")
    if model_request_built.get("models") != [required_model]:
        failures.append(f"{prefix}.models is not exactly [{required_model}]")
    request_layers = model_request_built.get("request_layers")
    if not isinstance(request_layers, list) or len(request_layers) < required_turn_count:
        failures.append(f"{prefix}.request_layers does not cover required pressure turn count")
    elif isinstance(count, int) and len(request_layers) != count:
        failures.append(f"{prefix}.request_layers count does not match model_request_built.count")
    elif any(layer != "runtime_provider" for layer in request_layers):
        failures.append(f"{prefix}.request_layers are not all runtime_provider")
    if model_request_built.get("all_match_required") is not True:
        failures.append(f"{prefix}.all_match_required is not true")
    require_empty_string_list(model_request_built.get("failures"), f"{prefix}.failures", failures)
    return model_request_built


def validate_matrix_model_response_provenance(
    suite: str,
    model_response_provenance: Any,
    failures: list[str],
    required_turn_count: int,
) -> dict[str, Any]:
    prefix = f"pressure matrix {suite} model_response_provenance"
    if not isinstance(model_response_provenance, dict):
        failures.append(f"{prefix} is missing or not an object")
        return {}
    if model_response_provenance.get("passed") is not True:
        failures.append(f"{prefix}.passed is not true")
    require_empty_string_list(model_response_provenance.get("failures"), f"{prefix}.failures", failures)
    completed_count = model_response_provenance.get("model_response_completed_count")
    if not isinstance(completed_count, int) or completed_count < required_turn_count:
        failures.append(f"{prefix}.model_response_completed_count is below required pressure turn count")
    final_provenance_count = model_response_provenance.get("model_response_final_answer_count")
    if final_provenance_count != required_turn_count:
        failures.append(f"{prefix}.model_response_final_answer_count does not match required pressure turn count")
    if model_response_provenance.get("final_answer_count") != required_turn_count:
        failures.append(f"{prefix}.final_answer_count does not match required pressure turn count")
    for key in [
        "completed_response_ids",
        "final_answer_response_ids",
        "final_answer_sources",
        "completed_model_request_layers",
        "completed_model_request_refs",
        "final_answer_model_request_layers",
        "final_answer_model_request_refs",
        "final_answer_request_last_user_input_sha256s",
        "final_answer_text_sha256s",
    ]:
        value = model_response_provenance.get(key)
        if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
            failures.append(f"{prefix}.{key} is not a non-empty string array")
    completed_ids = model_response_provenance.get("completed_response_ids")
    final_ids = model_response_provenance.get("final_answer_response_ids")
    if isinstance(final_ids, list):
        if len(final_ids) != required_turn_count:
            failures.append(f"{prefix}.final_answer_response_ids does not match required pressure turn count")
        if len(set(final_ids)) != len(final_ids):
            failures.append(f"{prefix}.final_answer_response_ids are not unique")
        if isinstance(completed_ids, list):
            missing = [response_id for response_id in final_ids if response_id not in completed_ids]
            if missing:
                failures.append(f"{prefix}.final_answer_response_ids include ids not completed by provider stream")
    completed_refs = model_response_provenance.get("completed_model_request_refs")
    final_refs = model_response_provenance.get("final_answer_model_request_refs")
    if isinstance(final_refs, list):
        if len(final_refs) != required_turn_count:
            failures.append(f"{prefix}.final_answer_model_request_refs does not match required pressure turn count")
        if isinstance(completed_refs, list):
            missing_refs = [ref for ref in final_refs if ref not in completed_refs]
            if missing_refs:
                failures.append(f"{prefix}.final_answer_model_request_refs include refs not completed by provider stream")
    final_hashes = model_response_provenance.get("final_answer_request_last_user_input_sha256s")
    if isinstance(final_hashes, list) and len(final_hashes) != required_turn_count:
        failures.append(f"{prefix}.final_answer_request_last_user_input_sha256s does not match required pressure turn count")
    final_text_hashes = model_response_provenance.get("final_answer_text_sha256s")
    if isinstance(final_text_hashes, list) and len(final_text_hashes) != required_turn_count:
        failures.append(f"{prefix}.final_answer_text_sha256s does not match required pressure turn count")
    if model_response_provenance.get("final_answer_sources") != ["provider_stream_final_answer"] * required_turn_count:
        failures.append(f"{prefix}.final_answer_sources are not all provider_stream_final_answer")
    if model_response_provenance.get("final_answer_completed") != [True] * required_turn_count:
        failures.append(f"{prefix}.final_answer_completed are not all true")
    completed_layers = model_response_provenance.get("completed_model_request_layers")
    if isinstance(completed_layers, list) and any(layer != "runtime_provider" for layer in completed_layers):
        failures.append(f"{prefix}.completed_model_request_layers are not all runtime_provider")
    final_layers = model_response_provenance.get("final_answer_model_request_layers")
    if final_layers != ["runtime_provider"] * required_turn_count:
        failures.append(f"{prefix}.final_answer_model_request_layers are not all runtime_provider")
    return model_response_provenance


def validate_matrix_feedback(suite: str, feedback: Any, failures: list[str]) -> dict[str, Any]:
    prefix = f"pressure matrix {suite}"
    if not isinstance(feedback, dict):
        failures.append(f"{prefix} feedback is missing or not an object")
        return {}
    require_feedback_schema(feedback, f"{prefix} feedback", failures)
    if feedback.get("looks_like_regular_linux") is not True:
        failures.append(f"{prefix} model feedback does not say it looks like regular Linux")
    if feedback.get("can_distinguish_from_regular_linux") is not False:
        failures.append(f"{prefix} model feedback says it can distinguish regular Linux")
    require_empty_string_list(feedback.get("suspicious_outputs"), f"{prefix} feedback.suspicious_outputs", failures)
    require_empty_string_list(feedback.get("leaked_internal_paths"), f"{prefix} feedback.leaked_internal_paths", failures)
    return feedback


def validate_matrix_provider_smoke(
    suite: str,
    provider_smoke: Any,
    failures: list[str],
    required_model: str,
) -> dict[str, Any]:
    prefix = f"pressure matrix {suite} provider_smoke"
    if not isinstance(provider_smoke, dict):
        failures.append(f"{prefix} is missing or not an object")
        return {}
    if provider_smoke.get("checked") is not True:
        failures.append(f"{prefix}.checked is not true")
    if provider_smoke.get("request_model") != required_model:
        failures.append(f"{prefix}.request_model is not {required_model}")
    if provider_smoke.get("request_model_matches_required") is not True:
        failures.append(f"{prefix}.request_model_matches_required is not true")
    for key in ["request", "response"]:
        if not isinstance(provider_smoke.get(key), str) or not provider_smoke.get(key):
            failures.append(f"{prefix}.{key} is missing or not a path string")
    expected = provider_smoke.get("expected_output")
    actual = provider_smoke.get("actual_output")
    if not isinstance(expected, str) or not re.fullmatch(r"MSP_PROVIDER_OK_[0-9a-f]{16}", expected):
        failures.append(f"{prefix}.expected_output is not a dynamic MSP_PROVIDER_OK nonce")
    elif expected in PLACEHOLDER_PROVIDER_OUTPUTS:
        failures.append(f"{prefix}.expected_output uses a fixed placeholder nonce")
    if not isinstance(actual, str) or not actual:
        failures.append(f"{prefix}.actual_output is missing or not a string")
    elif isinstance(expected, str) and actual != expected:
        failures.append(f"{prefix} actual output does not match expected output")
    if provider_smoke.get("request_artifact_model") != required_model:
        failures.append(f"{prefix}.request_artifact_model is not {required_model}")
    if provider_smoke.get("request_artifact_expected_output") != expected:
        failures.append(f"{prefix}.request_artifact_expected_output does not match expected_output")
    response_id = provider_smoke.get("response_artifact_id")
    if not isinstance(response_id, str) or not response_id:
        failures.append(f"{prefix}.response_artifact_id is missing or not a string")
    elif response_id in PLACEHOLDER_PROVIDER_RESPONSE_IDS:
        failures.append(f"{prefix}.response_artifact_id uses a fixed placeholder")
    if provider_smoke.get("response_artifact_object") != "response":
        failures.append(f"{prefix}.response_artifact_object is not response")
    if provider_smoke.get("response_artifact_actual_output") != actual:
        failures.append(f"{prefix}.response_artifact_actual_output does not match actual_output")
    return provider_smoke


def validate_matrix_prompt_contract(
    suite: str,
    prompt_contract: Any,
    failures: list[str],
    required_path: str,
    required_sha256: str,
    required_prompt_count: int,
    required_sentinels: list[str],
) -> dict[str, Any]:
    prefix = f"pressure matrix {suite} prompt_contract"
    if not isinstance(prompt_contract, dict):
        failures.append(f"{prefix} is missing or not an object")
        return {}
    if prompt_contract.get("passed") is not True:
        failures.append(f"{prefix}.passed is not true")
    require_empty_string_list(prompt_contract.get("failures"), f"{prefix}.failures", failures)
    if prompt_contract.get("path") != required_path:
        failures.append(f"{prefix}.path does not match canonical prompt file")
    if prompt_contract.get("sha256") != required_sha256:
        failures.append(f"{prefix}.sha256 does not match canonical prompt file")
    if prompt_contract.get("prompt_count") != required_prompt_count:
        failures.append(f"{prefix}.prompt_count does not match required pressure turn count")
    if prompt_contract.get("required_final_sentinels") != required_sentinels:
        failures.append(f"{prefix}.required_final_sentinels does not match final gate contract")
    return prompt_contract


def validate_matrix_prompt_delivery(
    suite: str,
    prompt_delivery: Any,
    failures: list[str],
    expected_delivery: dict[str, Any],
    required_prompt_count: int,
) -> dict[str, Any]:
    prefix = f"pressure matrix {suite} prompt_delivery"
    if not isinstance(prompt_delivery, dict):
        failures.append(f"{prefix} is missing or not an object")
        return {}
    if prompt_delivery.get("passed") is not True:
        failures.append(f"{prefix}.passed is not true")
    require_empty_string_list(prompt_delivery.get("failures"), f"{prefix}.failures", failures)
    if prompt_delivery.get("path") != expected_delivery.get("path"):
        failures.append(f"{prefix}.path does not match canonical prompt file")
    if prompt_delivery.get("hash_algorithm") != "sha256-utf8":
        failures.append(f"{prefix}.hash_algorithm is not sha256-utf8")
    if prompt_delivery.get("prompt_count") != required_prompt_count:
        failures.append(f"{prefix}.prompt_count does not match required pressure turn count")
    if prompt_delivery.get("prompt_sha256s") != expected_delivery.get("prompt_sha256s"):
        failures.append(f"{prefix}.prompt_sha256s does not match canonical prompt file")
    if prompt_delivery.get("auto_submit_sequence_loaded_count") != 1:
        failures.append(f"{prefix}.auto_submit_sequence_loaded_count is not 1")
    if prompt_delivery.get("auto_submit_count") != required_prompt_count:
        failures.append(f"{prefix}.auto_submit_count does not match required pressure turn count")
    if prompt_delivery.get("auto_submit_indices") != list(range(1, required_prompt_count + 1)):
        failures.append(f"{prefix}.auto_submit_indices does not match required prompt order")
    model_request_count = prompt_delivery.get("model_request_count")
    if not isinstance(model_request_count, int) or model_request_count < required_prompt_count:
        failures.append(f"{prefix}.model_request_count is below required pressure turn count")
        model_request_count = 0
    request_layers = prompt_delivery.get("model_request_layers")
    if not isinstance(request_layers, list) or len(request_layers) < required_prompt_count:
        failures.append(f"{prefix}.model_request_layers does not cover required pressure turn count")
    elif any(layer != "runtime_provider" for layer in request_layers):
        failures.append(f"{prefix}.model_request_layers are not all runtime_provider")
    request_hashes = prompt_delivery.get("model_request_last_user_input_sha256s")
    if not isinstance(request_hashes, list) or any(not isinstance(item, str) for item in request_hashes):
        failures.append(f"{prefix}.model_request_last_user_input_sha256s is not a string array")
        request_hashes = []
    expected_hashes = expected_delivery.get("prompt_sha256s")
    final_answer_hashes = prompt_delivery.get("final_answer_request_last_user_input_sha256s")
    if not isinstance(final_answer_hashes, list) or any(not isinstance(item, str) for item in final_answer_hashes):
        failures.append(f"{prefix}.final_answer_request_last_user_input_sha256s is not a string array")
        final_answer_hashes = []
    if len(final_answer_hashes) != required_prompt_count:
        failures.append(f"{prefix}.final_answer_request_last_user_input_sha256s does not match required pressure turn count")
    elif isinstance(expected_hashes, list) and final_answer_hashes != expected_hashes:
        failures.append(f"{prefix}.final_answer_request_last_user_input_sha256s do not match canonical prompt order")
    match_indices = prompt_delivery.get("model_request_prompt_match_indices")
    if not isinstance(match_indices, list) or any(not isinstance(item, int) for item in match_indices):
        failures.append(f"{prefix}.model_request_prompt_match_indices is not an integer array")
        match_indices = []
    if isinstance(expected_hashes, list) and len(match_indices) != len(expected_hashes):
        failures.append(f"{prefix}.model_request_prompt_match_indices does not cover every prompt")
    if match_indices != sorted(match_indices):
        failures.append(f"{prefix}.model_request_prompt_match_indices is not ordered")
    for prompt_index, request_index in enumerate(match_indices):
        if not isinstance(expected_hashes, list) or prompt_index >= len(expected_hashes):
            continue
        if request_index < 0 or request_index >= len(request_hashes):
            failures.append(f"{prefix}.model_request_prompt_match_indices contains an out-of-range request index")
            continue
        if request_hashes[request_index] != expected_hashes[prompt_index]:
            failures.append(f"{prefix}.model_request_last_user_input_sha256s do not match canonical prompt order")
    return prompt_delivery


def compare_core_fields(
    suite: str,
    section: str,
    summary_value: Any,
    expected_value: Any,
    fields: list[str],
    failures: list[str],
) -> None:
    if not isinstance(summary_value, dict) or not isinstance(expected_value, dict):
        if summary_value != expected_value:
            failures.append(f"pressure matrix {suite} {section} does not match suite report evidence")
        return
    for key in fields:
        if summary_value.get(key) != expected_value.get(key):
            failures.append(f"pressure matrix {suite} {section}.{key} does not match suite report evidence")
