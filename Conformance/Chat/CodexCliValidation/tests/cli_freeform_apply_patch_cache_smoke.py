#!/usr/bin/env python3
"""Run real CLI/TUI freeform apply_patch session-cache parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a freeform apply_patch custom tool call
    press the TUI shortcut for "yes, and do not ask again for these files"
    type a second prompt that changes the same file through freeform apply_patch
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06 approval or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from types import SimpleNamespace
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_command_approval_smoke import ev_final_message  # noqa: E402
from app_server_command_approval_smoke import write_approval_config  # noqa: E402
from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS  # noqa: E402
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS  # noqa: E402
from app_server_durable_turn_smoke import ensure_binary  # noqa: E402
from app_server_durable_turn_smoke import read_json_lines  # noqa: E402
from app_server_durable_turn_smoke import summarize_chat_packages  # noqa: E402
from app_server_durable_turn_smoke import summarize_original_storage  # noqa: E402
from app_server_durable_turn_smoke import utc_now_iso  # noqa: E402
from app_server_durable_turn_smoke import write_json  # noqa: E402
from app_server_file_change_approval_smoke import ADD_README_PATCH  # noqa: E402
from app_server_file_change_approval_smoke import UPDATE_README_PATCH  # noqa: E402
from app_server_freeform_apply_patch_smoke import (  # noqa: E402
    FreeformApplyPatchResponsesServer,
    ev_apply_patch_custom_tool_call,
    write_freeform_models_cache,
)
from cli_command_approval_smoke import durable_line_counts  # noqa: E402
from cli_exec_resume_smoke import normalize_exec_events  # noqa: E402
from cli_exec_resume_smoke import response_request_bodies  # noqa: E402
from cli_exec_resume_smoke import run_cli_command  # noqa: E402
from cli_file_change_approval_smoke import serialized_contains  # noqa: E402
import cli_file_change_approval_cache_smoke as file_cache_tui  # noqa: E402


PATCH_CALL_ID_1 = "freeform-patch-cache-call-1"
PATCH_CALL_ID_2 = "freeform-patch-cache-call-2"
USER_TEXT_1 = "Apply the first freeform AcceptForSession patch."
USER_TEXT_2 = "Apply the second freeform AcceptForSession patch without another prompt."
FINAL_TEXT_1 = "Freeform apply_patch AcceptForSession patch 1 complete."
FINAL_TEXT_2 = "Freeform apply_patch AcceptForSession patch 2 complete."
FOLLOWUP_USER_TEXT = "CLI freeform apply_patch cache follow-up after session approval."
FOLLOWUP_ASSISTANT_TEXT = "CLI freeform apply_patch cache follow-up answer from mock model."
EXPECTED_README_CONTENTS = "updated line\n"

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Spec/Chat/CorePackage.md",
    "Spec/Chat/TimelineEvents.md",
    "Spec/Chat/CommandTimeline.md",
    "Spec/Chat/Projections.md",
    "Spec/Chat/ContextAndJournal.md",
    "Spec/Chat/Conformance.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/CODEX_BACKEND_MAPPING.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_freeform_apply_patch_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_freeform_apply_patch_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_freeform_apply_patch_cancel_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_file_change_approval_cache_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_file_change_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/handlers/apply_patch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class CliFreeformApplyPatchCacheResponsesServer(FreeformApplyPatchResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_apply_patch_custom_tool_call(
                "resp-cli-freeform-apply-patch-cache-1",
                PATCH_CALL_ID_1,
                ADD_README_PATCH,
            ),
            ev_final_message(
                "resp-cli-freeform-apply-patch-cache-final-1",
                "msg-cli-freeform-apply-patch-cache-final-1",
                FINAL_TEXT_1,
            ),
            ev_apply_patch_custom_tool_call(
                "resp-cli-freeform-apply-patch-cache-2",
                PATCH_CALL_ID_2,
                UPDATE_README_PATCH,
            ),
            ev_final_message(
                "resp-cli-freeform-apply-patch-cache-final-2",
                "msg-cli-freeform-apply-patch-cache-final-2",
                FINAL_TEXT_2,
            ),
            ev_final_message(
                "resp-cli-freeform-apply-patch-cache-followup",
                "msg-cli-freeform-apply-patch-cache-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    fourth_body = bodies[3] if len(bodies) > 3 else {}
    fifth_body = bodies[4] if len(bodies) > 4 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_first_user_text": body_contains(first_body, USER_TEXT_1),
        "first_body_advertises_apply_patch": serialized_contains(first_body, "apply_patch"),
        "second_body_contains_first_custom_tool_output": (
            serialized_contains(second_body, PATCH_CALL_ID_1)
            and serialized_contains(second_body, "custom_tool_call_output")
        ),
        "second_body_contains_first_patch_applied": (
            serialized_contains(second_body, "Patch applied")
            or serialized_contains(second_body, "new line")
        ),
        "third_body_contains_second_user_text": body_contains(third_body, USER_TEXT_2),
        "third_body_contains_first_final_text": body_contains(third_body, FINAL_TEXT_1),
        "third_body_contains_first_patch_output": (
            serialized_contains(third_body, PATCH_CALL_ID_1)
            and serialized_contains(third_body, "custom_tool_call_output")
        ),
        "fourth_body_contains_second_custom_tool_output": (
            serialized_contains(fourth_body, PATCH_CALL_ID_2)
            and serialized_contains(fourth_body, "custom_tool_call_output")
        ),
        "fourth_body_contains_second_patch_applied": (
            serialized_contains(fourth_body, "Patch applied")
            or serialized_contains(fourth_body, "updated line")
        ),
        "fifth_body_contains_first_user_text": body_contains(fifth_body, USER_TEXT_1),
        "fifth_body_contains_second_user_text": body_contains(fifth_body, USER_TEXT_2),
        "fifth_body_contains_first_final_text": body_contains(fifth_body, FINAL_TEXT_1),
        "fifth_body_contains_second_final_text": body_contains(fifth_body, FINAL_TEXT_2),
        "fifth_body_contains_followup_user_text": body_contains(fifth_body, FOLLOWUP_USER_TEXT),
        "fifth_body_contains_first_patch_output": (
            serialized_contains(fifth_body, PATCH_CALL_ID_1)
            and serialized_contains(fifth_body, "custom_tool_call_output")
        ),
        "fifth_body_contains_second_patch_output": (
            serialized_contains(fifth_body, PATCH_CALL_ID_2)
            and serialized_contains(fifth_body, "custom_tool_call_output")
        ),
    }


def summarize_freeform_cache_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    call_ids = [PATCH_CALL_ID_1, PATCH_CALL_ID_2]
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = [
            (((line.get("source_transport") or {}).get("payload") or {}).get("payload") or {})
            for line in journal_lines
        ]
        serialized_journal = json.dumps(journal_payloads, ensure_ascii=False)
        packages.append(
            {
                "package": str(package),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_tool_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "tool_call"
                ),
                "timeline_tool_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "tool_output"
                ),
                "timeline_command_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_call"
                ),
                "timeline_command_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_output"
                ),
                "journal_line_count": len(journal_lines),
                "journal_custom_apply_patch_call_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "custom_tool_call"
                    and payload.get("name") == "apply_patch"
                ),
                "journal_custom_tool_call_output_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "custom_tool_call_output"
                ),
                "journal_has_all_patch_call_ids": all(
                    call_id in serialized_journal for call_id in call_ids
                ),
                "journal_has_add_patch_text": "*** Add File: README.md" in serialized_journal,
                "journal_has_update_patch_text": "*** Update File: README.md" in serialized_journal,
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_freeform_cache_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
        serialized = json.dumps(lines, ensure_ascii=False)
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "payload_types": [item.get("type") for item in lines],
                "response_item_types": [
                    ((item.get("payload") or {}).get("type"))
                    for item in lines
                    if item.get("type") == "response_item"
                ],
                "custom_tool_call_names": [
                    ((item.get("payload") or {}).get("name"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "custom_tool_call"
                ],
                "custom_tool_call_output_call_ids": [
                    ((item.get("payload") or {}).get("call_id"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type")
                    == "custom_tool_call_output"
                ],
                "contains_all_patch_call_ids": (
                    PATCH_CALL_ID_1 in serialized and PATCH_CALL_ID_2 in serialized
                ),
                "contains_add_patch_text": "*** Add File: README.md" in serialized,
                "contains_update_patch_text": "*** Update File: README.md" in serialized,
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def original_has_freeform_cache_persisted(result: dict[str, Any]) -> bool:
    rollouts = result["original_freeform_cache_rollout_summary"].get("rollouts") or []
    call_ids = [PATCH_CALL_ID_1, PATCH_CALL_ID_2]
    return any(
        rollout.get("custom_tool_call_names", []).count("apply_patch") >= 2
        and all(call_id in rollout.get("custom_tool_call_output_call_ids", []) for call_id in call_ids)
        and rollout.get("contains_all_patch_call_ids")
        and rollout.get("contains_add_patch_text")
        and rollout.get("contains_update_patch_text")
        for rollout in rollouts
    )


def chat_backend_has_freeform_cache_timeline(result: dict[str, Any]) -> bool:
    packages = result["chat_freeform_cache_timeline_summary"].get("packages") or []
    return any(
        package.get("timeline_tool_call_count", 0) >= 2
        and package.get("timeline_tool_output_count", 0) >= 2
        and package.get("timeline_command_call_count") == 0
        and package.get("timeline_command_output_count") == 0
        and package.get("journal_custom_apply_patch_call_count", 0) >= 2
        and package.get("journal_custom_tool_call_output_count", 0) >= 2
        and package.get("journal_has_all_patch_call_ids")
        and package.get("journal_has_add_patch_text")
        and package.get("journal_has_update_patch_text")
        for package in packages
    )


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    readme_path = workspace / "README.md"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with CliFreeformApplyPatchCacheResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        write_freeform_models_cache(codex_home)
        prior_first_turn = file_cache_tui.FIRST_TURN
        prior_second_turn = file_cache_tui.SECOND_TURN
        file_cache_tui.FIRST_TURN = SimpleNamespace(
            user_text=USER_TEXT_1,
            final_text=FINAL_TEXT_1,
        )
        file_cache_tui.SECOND_TURN = SimpleNamespace(
            user_text=USER_TEXT_2,
            final_text=FINAL_TEXT_2,
        )
        try:
            file_change_tui = file_cache_tui.run_cli_file_change_cache_tui(
                codex_bin,
                workspace,
                codex_home,
                config_overrides,
                mock_server,
            )
        finally:
            file_cache_tui.FIRST_TURN = prior_first_turn
            file_cache_tui.SECOND_TURN = prior_second_turn
        readme_after_tui = readme_path.read_text() if readme_path.exists() else None
        after_tui_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        followup_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_last=True,
        )
        final_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

    result: dict[str, Any] = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "file_change_tui": file_change_tui,
        "readme_after_tui": readme_after_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["chat_freeform_cache_timeline_summary"] = (
            summarize_freeform_cache_chat_timeline(chat_root)
        )
    else:
        result["original_freeform_cache_rollout_summary"] = (
            summarize_freeform_cache_original_rollouts(codex_home)
        )
    return result


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Freeform Apply Patch Cache Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow real CLI/TUI freeform `apply_patch` session-cache",
        "smoke. It drives two provider `custom_tool_call` items named",
        "`apply_patch`, accepts the first visible edit approval prompt with the",
        "session-cache shortcut, expects the second same-file edit to complete",
        "without another prompt, and then resumes the thread through",
        "`codex exec --json`.",
        "",
        "It proves the freeform AcceptForSession cache slice only. It does not",
        "prove network approval, additional-permission approval, crash recovery,",
        "or final user-indistinguishability.",
        "",
        "## Result",
        "",
        f"- passed: `{summary['passed']}`",
        f"- original TUI reached first file-change approval: `{summary['original_tui_reached_first_file_change_approval']}`",
        f"- `.chat` TUI reached first file-change approval: `{summary['chat_backend_tui_reached_first_file_change_approval']}`",
        f"- original saw unexpected second approval: `{summary['original_tui_unexpected_second_approval_visible']}`",
        f"- `.chat` saw unexpected second approval: `{summary['chat_backend_tui_unexpected_second_approval_visible']}`",
        f"- second freeform patch completed without second approval input: `{summary['second_patch_completed_without_second_approval_input']}`",
        f"- workspace patch contents equal: `{summary['workspace_patch_contents_equal']}`",
        f"- normalized follow-up CLI output equal: `{summary['normalized_followup_exec_equal']}`",
        f"- mock request summaries equal: `{summary['mock_request_summaries_equal']}`",
        f"- durable line counts equal: `{summary['final_durable_line_counts_equal']}`",
        f"- `.chat` package has two freeform tool/source-transport pairs: `{summary['chat_backend_has_freeform_cache_timeline']}`",
        "",
        "## Evidence",
        "",
        "- `summary.json`",
        "- `original/cli-freeform-apply-patch-cache-response.json`",
        "- `chat-backend/cli-freeform-apply-patch-cache-response.json`",
        "",
    ]
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-freeform-apply-patch-cache-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

    run_root = output_dir / "run"
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_lines = original_result["final_line_counts"]
    chat_lines = chat_result["final_line_counts"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-freeform-apply-patch-cache-smoke",
        "matrix_slice": [
            "T04-adjacent",
            "T05-adjacent",
            "T06-freeform-cache-adjacent",
            "R01-adjacent",
        ],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_reached_first_file_change_approval": original_result["file_change_tui"][
            "first_approval_prompt_visible"
        ],
        "chat_backend_tui_reached_first_file_change_approval": chat_result["file_change_tui"][
            "first_approval_prompt_visible"
        ],
        "original_tui_sent_file_change_session_accept": original_result["file_change_tui"][
            "sent_file_change_session_accept"
        ],
        "chat_backend_tui_sent_file_change_session_accept": chat_result["file_change_tui"][
            "sent_file_change_session_accept"
        ],
        "original_tui_first_final_visible": original_result["file_change_tui"][
            "first_final_visible"
        ],
        "chat_backend_tui_first_final_visible": chat_result["file_change_tui"][
            "first_final_visible"
        ],
        "original_tui_second_final_visible": original_result["file_change_tui"][
            "second_final_visible"
        ],
        "chat_backend_tui_second_final_visible": chat_result["file_change_tui"][
            "second_final_visible"
        ],
        "original_tui_unexpected_second_approval_visible": original_result["file_change_tui"][
            "unexpected_second_approval_prompt_visible"
        ],
        "chat_backend_tui_unexpected_second_approval_visible": chat_result["file_change_tui"][
            "unexpected_second_approval_prompt_visible"
        ],
        "tui_response_request_counts_equal_after_cache": (
            original_result["file_change_tui"]["response_request_count_after_tui"]
            == chat_result["file_change_tui"]["response_request_count_after_tui"]
            == 4
        ),
        "second_patch_completed_without_second_approval_input": (
            original_result["file_change_tui"]["sent_file_change_session_accept"]
            and chat_result["file_change_tui"]["sent_file_change_session_accept"]
            and not original_result["file_change_tui"][
                "unexpected_second_approval_prompt_visible"
            ]
            and not chat_result["file_change_tui"][
                "unexpected_second_approval_prompt_visible"
            ]
            and original_result["file_change_tui"]["second_final_visible"]
            and chat_result["file_change_tui"]["second_final_visible"]
        ),
        "workspace_patch_contents_equal": (
            original_result["readme_after_tui"]
            == chat_result["readme_after_tui"]
            == EXPECTED_README_CONTENTS
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "mock_freeform_outputs_round_trip": (
            original_mock["second_body_contains_first_custom_tool_output"]
            and chat_mock["second_body_contains_first_custom_tool_output"]
            and original_mock["second_body_contains_first_patch_applied"]
            and chat_mock["second_body_contains_first_patch_applied"]
            and original_mock["fourth_body_contains_second_custom_tool_output"]
            and chat_mock["fourth_body_contains_second_custom_tool_output"]
            and original_mock["fourth_body_contains_second_patch_applied"]
            and chat_mock["fourth_body_contains_second_patch_applied"]
        ),
        "followup_context_preserved_after_freeform_cache": (
            original_mock["fifth_body_contains_first_user_text"]
            and chat_mock["fifth_body_contains_first_user_text"]
            and original_mock["fifth_body_contains_second_user_text"]
            and chat_mock["fifth_body_contains_second_user_text"]
            and original_mock["fifth_body_contains_first_final_text"]
            and chat_mock["fifth_body_contains_first_final_text"]
            and original_mock["fifth_body_contains_second_final_text"]
            and chat_mock["fifth_body_contains_second_final_text"]
            and original_mock["fifth_body_contains_first_patch_output"]
            and chat_mock["fifth_body_contains_first_patch_output"]
            and original_mock["fifth_body_contains_second_patch_output"]
            and chat_mock["fifth_body_contains_second_patch_output"]
            and original_mock["fifth_body_contains_followup_user_text"]
            and chat_mock["fifth_body_contains_followup_user_text"]
        ),
        "original_has_freeform_cache_persisted": (
            original_has_freeform_cache_persisted(original_result)
        ),
        "chat_backend_has_freeform_cache_timeline": (
            chat_backend_has_freeform_cache_timeline(chat_result)
        ),
        "original_final_line_counts": original_lines,
        "chat_backend_final_line_counts": chat_lines,
        "final_durable_line_counts_equal": original_lines == chat_lines and bool(original_lines),
        "original": {
            "file_change_tui": original_result["file_change_tui"],
            "readme_after_tui": original_result["readme_after_tui"],
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "final_line_counts": original_lines,
        },
        "chat_backend": {
            "file_change_tui": chat_result["file_change_tui"],
            "readme_after_tui": chat_result["readme_after_tui"],
            "followup_exec": {
                "command": chat_followup["command"],
                "exit_code": chat_followup["exit_code"],
                "normalized_events": normalize_exec_events(chat_followup["events"]),
                "stderr_tail": chat_followup["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "final_line_counts": chat_lines,
            "chat_freeform_cache_timeline_summary": chat_result[
                "chat_freeform_cache_timeline_summary"
            ],
        },
        "not_yet_proven": [
            "network approval through CLI/TUI",
            "additional-permission approval through CLI/TUI",
            "approval process-kill or crash recovery",
            "complete T06 data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_first_file_change_approval"],
            summary["chat_backend_tui_reached_first_file_change_approval"],
            summary["original_tui_sent_file_change_session_accept"],
            summary["chat_backend_tui_sent_file_change_session_accept"],
            summary["original_tui_first_final_visible"],
            summary["chat_backend_tui_first_final_visible"],
            summary["original_tui_second_final_visible"],
            summary["chat_backend_tui_second_final_visible"],
            not summary["original_tui_unexpected_second_approval_visible"],
            not summary["chat_backend_tui_unexpected_second_approval_visible"],
            summary["tui_response_request_counts_equal_after_cache"],
            summary["second_patch_completed_without_second_approval_input"],
            summary["workspace_patch_contents_equal"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_freeform_outputs_round_trip"],
            summary["followup_context_preserved_after_freeform_cache"],
            summary["original_has_freeform_cache_persisted"],
            summary["chat_backend_has_freeform_cache_timeline"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI freeform apply_patch "
        "AcceptForSession slice: both backends receive two provider "
        "custom_tool_call items named apply_patch, show the first visible "
        "file-change approval path, accept future edits for the session through "
        "the TUI shortcut, run a second same-file freeform patch without "
        "additional approval input, apply the same workspace contents, preserve "
        "both custom_tool_call_output items in follow-up resume context, retain "
        "freeform source transport, map `.chat` canonical timeline as two "
        "tool_call/tool_output pairs rather than command_call/command_output, "
        "and keep durable original rollout line counts equal to `.chat` journal "
        "line counts. It is not full freeform apply_patch or approval parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/cli-freeform-apply-patch-cache-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/cli-freeform-apply-patch-cache-response.json",
        chat_result,
    )
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
