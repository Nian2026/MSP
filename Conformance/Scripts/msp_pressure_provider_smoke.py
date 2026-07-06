"""Provider-smoke evidence verification for MSP pressure gates."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from msp_pressure_contract import REQUIRED_MODEL
from msp_pressure_json_support import load_json
from msp_pressure_matrix_summary import PLACEHOLDER_PROVIDER_OUTPUTS, PLACEHOLDER_PROVIDER_RESPONSE_IDS


EXPECTED_PROVIDER_SMOKE_RELATIVE_PATHS = {
    "request": Path("provider-smoke/provider-smoke-request.redacted.json"),
    "response": Path("provider-smoke/provider-smoke-response.json"),
}


def provider_smoke_artifact_path(value: str, base_dir: Path) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return base_dir / path


def provider_smoke_artifact_is_under_base_dir(path: Path, base_dir: Path) -> bool:
    try:
        path.resolve().relative_to(base_dir.resolve())
    except ValueError:
        return False
    return True


def provider_smoke_artifact_matches_canonical_path(path: Path, key: str, base_dir: Path) -> bool:
    expected = EXPECTED_PROVIDER_SMOKE_RELATIVE_PATHS.get(key)
    if expected is None:
        return False
    return path.resolve() == (base_dir / expected).resolve()


def provider_smoke_prompt_text(request: dict[str, Any]) -> str:
    texts = []
    for item in request.get("input", []) or []:
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []) or []:
            if isinstance(content, dict) and isinstance(content.get("text"), str):
                texts.append(content["text"])
    return "\n".join(texts).strip()


def provider_smoke_response_text(response: dict[str, Any]) -> str:
    output_text = response.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text.strip()
    texts = []
    for item in response.get("output", []) or []:
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []) or []:
            if not isinstance(content, dict):
                continue
            if content.get("type") in {"output_text", "text"} and isinstance(content.get("text"), str):
                texts.append(content["text"])
    return "\n".join(texts).strip()


def verify_response_artifact_identity(
    response: dict[str, Any],
    failures: list[str],
    prefix: str,
) -> None:
    response_id = response.get("id")
    response_object = response.get("object")
    if not isinstance(response_id, str) or not response_id:
        failures.append(f"{prefix} response artifact id is missing or not a string")
    elif response_id in PLACEHOLDER_PROVIDER_RESPONSE_IDS:
        failures.append(f"{prefix} response artifact id uses a fixed placeholder")
    if response_object != "response":
        failures.append(f"{prefix} response artifact object is not response")


def verify_provider_smoke(
    provider_smoke: Any,
    failures: list[str],
    base_dir: Path,
    required_model: str = REQUIRED_MODEL,
) -> dict[str, Any]:
    if not isinstance(provider_smoke, dict):
        failures.append("provider_smoke is missing or not an object")
        return {}
    provider_smoke = dict(provider_smoke)
    if provider_smoke.get("checked") is not True:
        failures.append("provider_smoke.checked is not true")
    if provider_smoke.get("request_model") != required_model:
        failures.append(f"provider_smoke.request_model is not {required_model}")
    if provider_smoke.get("request_model_matches_required") is not True:
        failures.append("provider_smoke.request_model_matches_required is not true")

    artifact_paths: dict[str, Path] = {}
    for key in ["request", "response"]:
        value = provider_smoke.get(key)
        if not isinstance(value, str) or not value:
            failures.append(f"provider_smoke.{key} is missing or not a path string")
            continue
        artifact_path = provider_smoke_artifact_path(value, base_dir)
        if not provider_smoke_artifact_is_under_base_dir(artifact_path, base_dir):
            failures.append(f"provider_smoke.{key} artifact is outside suite report directory: {value}")
            continue
        if not provider_smoke_artifact_matches_canonical_path(artifact_path, key, base_dir):
            expected = base_dir / EXPECTED_PROVIDER_SMOKE_RELATIVE_PATHS[key]
            failures.append(
                f"provider_smoke.{key} artifact does not match canonical suite path: "
                f"expected {expected}, got {artifact_path}"
            )
            continue
        if not artifact_path.is_file():
            failures.append(f"provider_smoke.{key} artifact does not exist: {artifact_path}")
            continue
        artifact_paths[key] = artifact_path

    request_expected_output = None
    request_path = artifact_paths.get("request")
    if request_path is not None:
        try:
            request = load_json(request_path)
        except ValueError as exc:
            failures.append(f"provider_smoke.request artifact is invalid: {exc}")
            request = None
        if not isinstance(request, dict):
            failures.append("provider_smoke.request artifact is not an object")
        else:
            request_model = request.get("model")
            reported_request_artifact_model = provider_smoke.get("request_artifact_model")
            provider_smoke["request_artifact_model"] = request_model
            if request_model != required_model:
                failures.append(f"provider_smoke request artifact model is not {required_model}: {request_model}")
            if request_model != provider_smoke.get("request_model"):
                failures.append("provider_smoke request artifact model does not match report request_model")
            if reported_request_artifact_model != request_model:
                failures.append("provider_smoke.request_artifact_model does not match request artifact model")
            prompt_text = provider_smoke_prompt_text(request)
            expected_match = re.search(r"\bMSP_PROVIDER_OK_[0-9a-f]{16}\b", prompt_text)
            if not expected_match:
                failures.append("provider_smoke request artifact does not contain a dynamic MSP_PROVIDER_OK nonce")
            else:
                request_expected_output = expected_match.group(0)
                reported_request_artifact_expected_output = provider_smoke.get("request_artifact_expected_output")
                provider_smoke["request_artifact_expected_output"] = request_expected_output
                if provider_smoke.get("expected_output") != request_expected_output:
                    failures.append("provider_smoke.expected_output does not match request artifact nonce")
                if reported_request_artifact_expected_output != request_expected_output:
                    failures.append("provider_smoke.request_artifact_expected_output does not match request artifact nonce")

    response_path = artifact_paths.get("response")
    if response_path is not None:
        try:
            response = load_json(response_path)
        except ValueError as exc:
            failures.append(f"provider_smoke.response artifact is invalid: {exc}")
            response = None
        if not isinstance(response, dict):
            failures.append("provider_smoke.response artifact is not an object")
        elif response.get("error") is not None:
            failures.append("provider_smoke response artifact contains an error object")
        else:
            verify_response_artifact_identity(response, failures, "provider_smoke")
            response_id = response.get("id")
            response_object = response.get("object")
            reported_response_artifact_id = provider_smoke.get("response_artifact_id")
            reported_response_artifact_object = provider_smoke.get("response_artifact_object")
            provider_smoke["response_artifact_id"] = response_id
            provider_smoke["response_artifact_object"] = response_object
            if reported_response_artifact_id != response_id:
                failures.append("provider_smoke.response_artifact_id does not match response artifact id")
            if reported_response_artifact_object != response_object:
                failures.append("provider_smoke.response_artifact_object does not match response artifact object")
            response_output = provider_smoke_response_text(response)
            reported_response_artifact_actual_output = provider_smoke.get("response_artifact_actual_output")
            provider_smoke["response_artifact_actual_output"] = response_output
            if provider_smoke.get("actual_output") != response_output:
                failures.append("provider_smoke.actual_output does not match response artifact text")
            if reported_response_artifact_actual_output != response_output:
                failures.append("provider_smoke.response_artifact_actual_output does not match response artifact text")

    expected = provider_smoke.get("expected_output")
    actual = provider_smoke.get("actual_output")
    if not isinstance(expected, str) or not re.fullmatch(r"MSP_PROVIDER_OK_[0-9a-f]{16}", expected):
        failures.append("provider_smoke.expected_output is not a dynamic MSP_PROVIDER_OK nonce")
    elif expected in PLACEHOLDER_PROVIDER_OUTPUTS:
        failures.append("provider_smoke.expected_output uses a fixed placeholder nonce")
    elif request_expected_output is not None and expected != request_expected_output:
        failures.append("provider_smoke.expected_output does not match request artifact nonce")
    if not isinstance(actual, str) or not actual:
        failures.append("provider_smoke.actual_output is missing or not a string")
    elif isinstance(expected, str) and actual != expected:
        failures.append("provider_smoke actual output does not match expected output")
    return provider_smoke


def build_provider_smoke_evidence(
    request_path: Path | None,
    response_path: Path | None,
    require_provider_smoke: bool,
    failures: list[str],
    required_model: str = REQUIRED_MODEL,
) -> dict[str, Any]:
    initial_failure_count = len(failures)
    provider_smoke: dict[str, Any] = {
        "checked": False,
        "request": str(request_path) if request_path else None,
        "response": str(response_path) if response_path else None,
        "request_model": None,
        "request_model_matches_required": False,
        "expected_output": None,
        "actual_output": None,
        "request_artifact_model": None,
        "request_artifact_expected_output": None,
        "response_artifact_id": None,
        "response_artifact_object": None,
        "response_artifact_actual_output": None,
    }
    if not request_path and not response_path:
        if require_provider_smoke:
            failures.append("provider smoke evidence is missing")
        return provider_smoke

    if not request_path or not response_path:
        failures.append("provider smoke evidence must include both request and response paths")
        return provider_smoke

    if not request_path.is_file():
        failures.append(f"provider smoke request is missing: {request_path}")
        return provider_smoke
    if not response_path.is_file():
        failures.append(f"provider smoke response is missing: {response_path}")
        return provider_smoke

    try:
        request = load_json(request_path)
    except ValueError as exc:
        failures.append(f"provider smoke request is invalid JSON: {exc}")
        return provider_smoke
    try:
        response = load_json(response_path)
    except ValueError as exc:
        failures.append(f"provider smoke response is invalid JSON: {exc}")
        return provider_smoke

    if not isinstance(request, dict):
        failures.append("provider smoke request is not a JSON object")
        return provider_smoke
    if not isinstance(response, dict):
        failures.append("provider smoke response is not a JSON object")
        return provider_smoke
    if response.get("error") is not None:
        failures.append("provider smoke response contains an error object")
        return provider_smoke
    verify_response_artifact_identity(response, failures, "provider smoke")
    provider_smoke["response_artifact_id"] = response.get("id")
    provider_smoke["response_artifact_object"] = response.get("object")
    request_model = request.get("model")
    if not isinstance(request_model, str) or not request_model:
        failures.append("provider smoke request model is missing or not a string")
    else:
        provider_smoke["request_model"] = request_model
        provider_smoke["request_artifact_model"] = request_model
        provider_smoke["request_model_matches_required"] = request_model == required_model
        if request_model != required_model:
            failures.append(f"provider smoke request model is not {required_model}: {request_model}")

    if "input" not in request:
        failures.append("provider smoke request is missing input")
        return provider_smoke

    prompt_text = provider_smoke_prompt_text(request)
    expected_match = re.search(r"\bMSP_PROVIDER_OK_[0-9a-f]{16}\b", prompt_text)
    if not expected_match:
        failures.append("provider smoke request does not contain a dynamic MSP_PROVIDER_OK nonce")
        return provider_smoke
    expected_output = expected_match.group(0)
    if expected_output in PLACEHOLDER_PROVIDER_OUTPUTS:
        failures.append("provider smoke request uses a fixed placeholder nonce")
        return provider_smoke
    actual_output = provider_smoke_response_text(response)
    provider_smoke["expected_output"] = expected_output
    provider_smoke["request_artifact_expected_output"] = expected_output
    provider_smoke["actual_output"] = actual_output
    provider_smoke["response_artifact_actual_output"] = actual_output
    if actual_output != expected_output:
        failures.append("provider smoke response text did not match the dynamic expected output")
        return provider_smoke

    provider_smoke["checked"] = provider_smoke["request_model_matches_required"] and len(failures) == initial_failure_count
    return provider_smoke
