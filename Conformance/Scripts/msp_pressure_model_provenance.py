"""Model response provenance checks for MSP pressure event logs."""

from __future__ import annotations

import hashlib
from typing import Any

from msp_pressure_event_fields import field


PLACEHOLDER_MODEL_RESPONSE_IDS = {
    "resp_synthetic",
    "resp_mock",
    "resp_placeholder",
    "session_synthetic",
}
REQUIRED_FINAL_ANSWER_SOURCE = "provider_stream_final_answer"
RUNTIME_PROVIDER_REQUEST_LAYER = "runtime_provider"
TEXT_HASH_ALGORITHM = "sha256-utf8"


def sha256_utf8(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def is_sha256_hex(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def validate_text_hash_metadata(
    event: dict[str, Any],
    source: str,
    failures: list[str],
) -> None:
    if field(event, "text_hash_algorithm") != TEXT_HASH_ALGORITHM:
        failures.append(f"{source}.text_hash_algorithm is not {TEXT_HASH_ALGORITHM}")
    text_sha256 = field(event, "text_sha256")
    if not is_sha256_hex(text_sha256):
        failures.append(f"{source}.text_sha256 is not a sha256 hex digest")


def request_ref(event: dict[str, Any], prefix: str) -> str:
    run_id = field(event, f"{prefix}_run_id")
    sequence = field(event, f"{prefix}_sequence")
    if not run_id or not sequence:
        return ""
    return f"{run_id}:{sequence}"


def response_id_failure(response_id: str, source: str) -> str | None:
    if not response_id:
        return f"{source}.response_id is missing"
    if response_id in PLACEHOLDER_MODEL_RESPONSE_IDS:
        return f"{source}.response_id uses a fixed placeholder"
    return None


def compare_request_link(
    event: dict[str, Any],
    request_event: dict[str, Any],
    source: str,
    failures: list[str],
) -> None:
    comparisons = [
        ("model_request_layer", "request_layer"),
        ("model_request_model", "model"),
        ("request_user_input_hash_algorithm", "request_user_input_hash_algorithm"),
        ("request_user_input_sha256s", "request_user_input_sha256s"),
        ("request_last_user_input_sha256", "request_last_user_input_sha256"),
    ]
    for event_key, request_key in comparisons:
        expected = field(request_event, request_key)
        actual = field(event, event_key)
        if actual != expected:
            failures.append(f"{source}.{event_key} does not match linked model_request_built")


def model_response_provenance_summary(
    events: list[dict[str, Any]],
    expected_final_answers: int,
    failures: list[str],
    prefix: str = "",
) -> dict[str, Any]:
    local_failures: list[str] = []
    completed_response_ids: list[str] = []
    completed_response_id_set: set[str] = set()
    final_answer_response_ids: list[str] = []
    final_answer_sources: list[str] = []
    final_answer_completed_flags: list[bool] = []
    final_answer_provenance_indices: list[int] = []
    completed_model_request_layers: list[str] = []
    completed_model_request_refs: list[str] = []
    final_answer_model_request_layers: list[str] = []
    final_answer_model_request_refs: list[str] = []
    final_answer_request_last_user_input_sha256s: list[str] = []
    final_answer_text_sha256s: list[str] = []
    model_request_events_by_ref: dict[str, dict[str, Any]] = {}
    completed_events_by_response_id: dict[str, dict[str, Any]] = {}
    pending_final_answer_provenance: dict[str, Any] | None = None
    pending_final_answer_provenance_index: int | None = None

    for index, event in enumerate(events):
        name = event.get("event")
        if name == "model_request_built":
            ref = request_ref(event, "request")
            layer = field(event, "request_layer")
            if layer == RUNTIME_PROVIDER_REQUEST_LAYER and not ref:
                local_failures.append("model_request_built runtime_provider request ref is missing")
            if ref:
                if layer != RUNTIME_PROVIDER_REQUEST_LAYER:
                    local_failures.append(
                        f"model_request_built request ref {ref} is not {RUNTIME_PROVIDER_REQUEST_LAYER}"
                    )
                    continue
                if ref in model_request_events_by_ref:
                    local_failures.append(f"model_request_built duplicate request ref: {ref}")
                model_request_events_by_ref[ref] = event
            continue

        if name == "model_response_completed":
            source_index = len(completed_response_ids) + 1
            response_id = field(event, "response_id")
            failure = response_id_failure(response_id, f"model_response_completed[{source_index}]")
            if failure:
                local_failures.append(failure)
            if field(event, "response_completed").lower() != "true":
                local_failures.append(
                    f"model_response_completed[{source_index}].response_completed is not true"
                )
            if field(event, "source") != "responses_stream":
                local_failures.append(
                    f"model_response_completed[{source_index}].source is not responses_stream"
                )
            model_request_layer = field(event, "model_request_layer")
            if model_request_layer != RUNTIME_PROVIDER_REQUEST_LAYER:
                local_failures.append(
                    f"model_response_completed[{source_index}].model_request_layer is not {RUNTIME_PROVIDER_REQUEST_LAYER}"
                )
            model_request_ref = request_ref(event, "model_request")
            if not model_request_ref:
                local_failures.append(f"model_response_completed[{source_index}].model_request ref is missing")
            elif model_request_ref not in model_request_events_by_ref:
                local_failures.append(f"model_response_completed[{source_index}].model_request ref was not previously built")
            else:
                compare_request_link(
                    event,
                    model_request_events_by_ref[model_request_ref],
                    f"model_response_completed[{source_index}]",
                    local_failures,
                )
            completed_response_ids.append(response_id)
            completed_model_request_refs.append(model_request_ref)
            if response_id:
                completed_response_id_set.add(response_id)
                if response_id in completed_events_by_response_id:
                    local_failures.append(f"model_response_completed[{source_index}].response_id is duplicated")
                completed_events_by_response_id[response_id] = event
            completed_model_request_layers.append(model_request_layer)
            continue

        if name == "model_final_answer_provenance":
            source_index = len(final_answer_provenance_indices) + 1
            response_id = field(event, "response_id")
            failure = response_id_failure(response_id, f"model_final_answer_provenance[{source_index}]")
            if failure:
                local_failures.append(failure)
            validate_text_hash_metadata(
                event,
                f"model_final_answer_provenance[{source_index}]",
                local_failures,
            )
            if field(event, "response_completed").lower() != "true":
                local_failures.append(
                    f"model_final_answer_provenance[{source_index}].response_completed is not true"
                )
            if field(event, "source") != REQUIRED_FINAL_ANSWER_SOURCE:
                local_failures.append(
                    "model_final_answer_provenance"
                    f"[{source_index}].source is not {REQUIRED_FINAL_ANSWER_SOURCE}"
                )
            model_request_layer = field(event, "model_request_layer")
            if model_request_layer != RUNTIME_PROVIDER_REQUEST_LAYER:
                local_failures.append(
                    "model_final_answer_provenance"
                    f"[{source_index}].model_request_layer is not {RUNTIME_PROVIDER_REQUEST_LAYER}"
                )
            if response_id and response_id not in completed_response_id_set:
                local_failures.append(
                    "model_final_answer_provenance"
                    f"[{source_index}].response_id was not previously completed"
                )
            model_request_ref = request_ref(event, "model_request")
            if not model_request_ref:
                local_failures.append(f"model_final_answer_provenance[{source_index}].model_request ref is missing")
            elif model_request_ref not in model_request_events_by_ref:
                local_failures.append(f"model_final_answer_provenance[{source_index}].model_request ref was not previously built")
            else:
                compare_request_link(
                    event,
                    model_request_events_by_ref[model_request_ref],
                    f"model_final_answer_provenance[{source_index}]",
                    local_failures,
                )
            completed_event = completed_events_by_response_id.get(response_id)
            if completed_event is not None:
                for key in [
                    "model_request_layer",
                    "model_request_run_id",
                    "model_request_sequence",
                    "model_request_model",
                    "request_user_input_hash_algorithm",
                    "request_user_input_sha256s",
                    "request_last_user_input_sha256",
                ]:
                    if field(event, key) != field(completed_event, key):
                        local_failures.append(
                            f"model_final_answer_provenance[{source_index}].{key} does not match completed response"
                        )
            pending_final_answer_provenance = event
            pending_final_answer_provenance_index = index
            final_answer_provenance_indices.append(index)
            continue

        if name != "final_answer":
            continue

        answer_number = len(final_answer_response_ids) + 1
        response_id = field(event, "response_id")
        source = field(event, "source")
        response_completed = field(event, "response_completed").lower() == "true"
        model_request_layer = field(event, "model_request_layer")
        model_request_ref = request_ref(event, "model_request")
        final_answer_response_ids.append(response_id)
        final_answer_sources.append(source)
        final_answer_completed_flags.append(response_completed)
        final_answer_model_request_layers.append(model_request_layer)
        final_answer_model_request_refs.append(model_request_ref)
        final_answer_request_last_user_input_sha256s.append(field(event, "request_last_user_input_sha256"))
        final_answer_text_sha256s.append(field(event, "text_sha256"))

        failure = response_id_failure(response_id, f"final_answer[{answer_number}]")
        if failure:
            local_failures.append(failure)
        validate_text_hash_metadata(event, f"final_answer[{answer_number}]", local_failures)
        actual_text_sha256 = sha256_utf8(field(event, "text"))
        if field(event, "text_sha256") != actual_text_sha256:
            local_failures.append(f"final_answer[{answer_number}].text_sha256 does not match text")
        if not response_completed:
            local_failures.append(f"final_answer[{answer_number}].response_completed is not true")
        if source != REQUIRED_FINAL_ANSWER_SOURCE:
            local_failures.append(
                f"final_answer[{answer_number}].source is not {REQUIRED_FINAL_ANSWER_SOURCE}"
            )
        if model_request_layer != RUNTIME_PROVIDER_REQUEST_LAYER:
            local_failures.append(
                f"final_answer[{answer_number}].model_request_layer is not {RUNTIME_PROVIDER_REQUEST_LAYER}"
            )
        if response_id and response_id not in completed_response_id_set:
            local_failures.append(f"final_answer[{answer_number}].response_id was not previously completed")
        if not model_request_ref:
            local_failures.append(f"final_answer[{answer_number}].model_request ref is missing")
        elif model_request_ref not in model_request_events_by_ref:
            local_failures.append(f"final_answer[{answer_number}].model_request ref was not previously built")
        else:
            compare_request_link(
                event,
                model_request_events_by_ref[model_request_ref],
                f"final_answer[{answer_number}]",
                local_failures,
            )
        if field(event, "provenance_event") != "model_final_answer_provenance":
            local_failures.append(f"final_answer[{answer_number}].provenance_event is not model_final_answer_provenance")
        if pending_final_answer_provenance is None:
            local_failures.append(f"final_answer[{answer_number}] has no preceding model_final_answer_provenance event")
        else:
            if field(pending_final_answer_provenance, "response_id") != response_id:
                local_failures.append(f"final_answer[{answer_number}].response_id does not match provenance event")
            if field(pending_final_answer_provenance, "source") != source:
                local_failures.append(f"final_answer[{answer_number}].source does not match provenance event")
            if field(pending_final_answer_provenance, "response_completed").lower() != field(event, "response_completed").lower():
                local_failures.append(f"final_answer[{answer_number}].response_completed does not match provenance event")
            if field(pending_final_answer_provenance, "text_length") != field(event, "text_length"):
                local_failures.append(f"final_answer[{answer_number}].text_length does not match provenance event")
            if field(event, "provenance_text_length") != field(pending_final_answer_provenance, "text_length"):
                local_failures.append(
                    f"final_answer[{answer_number}].provenance_text_length does not match provenance event"
                )
            if field(event, "provenance_text_hash_algorithm") != field(
                pending_final_answer_provenance,
                "text_hash_algorithm",
            ):
                local_failures.append(
                    f"final_answer[{answer_number}].provenance_text_hash_algorithm does not match provenance event"
                )
            if field(event, "provenance_text_sha256") != field(pending_final_answer_provenance, "text_sha256"):
                local_failures.append(
                    f"final_answer[{answer_number}].provenance_text_sha256 does not match provenance event"
                )
            if field(event, "text_hash_algorithm") != field(pending_final_answer_provenance, "text_hash_algorithm"):
                local_failures.append(
                    f"final_answer[{answer_number}].text_hash_algorithm does not match provenance event"
                )
            if field(event, "text_sha256") != field(pending_final_answer_provenance, "text_sha256"):
                local_failures.append(f"final_answer[{answer_number}].text_sha256 does not match provenance event")
            for key in [
                "model_request_layer",
                "model_request_run_id",
                "model_request_sequence",
                "model_request_model",
                "request_user_input_hash_algorithm",
                "request_user_input_sha256s",
                "request_last_user_input_sha256",
            ]:
                if field(pending_final_answer_provenance, key) != field(event, key):
                    local_failures.append(f"final_answer[{answer_number}].{key} does not match provenance event")
            if pending_final_answer_provenance_index is not None and pending_final_answer_provenance_index > index:
                local_failures.append(f"final_answer[{answer_number}] provenance event appears after final answer")
        pending_final_answer_provenance = None
        pending_final_answer_provenance_index = None

    if len(final_answer_response_ids) != expected_final_answers:
        local_failures.append(
            "model_response_provenance final_answer count does not match expected pressure turn count: "
            f"{len(final_answer_response_ids)} != {expected_final_answers}"
        )
    if len(final_answer_provenance_indices) != len(final_answer_response_ids):
        local_failures.append(
            "model_response_provenance model_final_answer_provenance count does not match final_answer count: "
            f"{len(final_answer_provenance_indices)} != {len(final_answer_response_ids)}"
        )
    if len(completed_response_ids) < expected_final_answers:
        local_failures.append(
            "model_response_provenance model_response_completed count is below expected pressure turn count: "
            f"{len(completed_response_ids)} < {expected_final_answers}"
        )
    nonempty_final_response_ids = [value for value in final_answer_response_ids if value]
    if len(set(nonempty_final_response_ids)) != len(nonempty_final_response_ids):
        local_failures.append("model_response_provenance final_answer response_id values are not unique")
    if pending_final_answer_provenance is not None:
        local_failures.append("model_response_provenance has an unconsumed model_final_answer_provenance event")

    evidence = {
        "passed": not local_failures,
        "failures": local_failures,
        "model_response_completed_count": len(completed_response_ids),
        "model_response_final_answer_count": len(final_answer_provenance_indices),
        "final_answer_count": len(final_answer_response_ids),
        "completed_response_ids": completed_response_ids,
        "final_answer_response_ids": final_answer_response_ids,
        "final_answer_sources": final_answer_sources,
        "final_answer_completed": final_answer_completed_flags,
        "completed_model_request_layers": completed_model_request_layers,
        "completed_model_request_refs": completed_model_request_refs,
        "final_answer_model_request_layers": final_answer_model_request_layers,
        "final_answer_model_request_refs": final_answer_model_request_refs,
        "final_answer_request_last_user_input_sha256s": final_answer_request_last_user_input_sha256s,
        "final_answer_text_sha256s": final_answer_text_sha256s,
    }
    if local_failures:
        failures.extend(f"{prefix}{failure}" for failure in local_failures)
    return evidence
