#!/usr/bin/env python3
"""Run real CLI/TUI freeform apply_patch cancel parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a freeform apply_patch custom tool call
    press the TUI shortcut for the negative file-change decision
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
from app_server_durable_turn_smoke import summarize_chat_packages  # noqa: E402
from app_server_durable_turn_smoke import summarize_original_storage  # noqa: E402
from app_server_durable_turn_smoke import utc_now_iso  # noqa: E402
from app_server_durable_turn_smoke import write_json  # noqa: E402
from app_server_file_change_approval_smoke import ADD_README_PATCH  # noqa: E402
from app_server_freeform_apply_patch_smoke import (  # noqa: E402
    PATCH_CALL_ID,
    FreeformApplyPatchResponsesServer,
    ev_apply_patch_custom_tool_call,
    summarize_freeform_chat_timeline,
    summarize_freeform_original_rollouts,
    write_freeform_models_cache,
)
from cli_command_approval_smoke import durable_line_counts  # noqa: E402
from cli_exec_resume_smoke import normalize_exec_events  # noqa: E402
from cli_exec_resume_smoke import response_request_bodies  # noqa: E402
from cli_exec_resume_smoke import run_cli_command  # noqa: E402
from cli_file_change_approval_smoke import serialized_contains  # noqa: E402
import cli_file_change_approval_cancel_smoke as cancel_tui  # noqa: E402


USER_TEXT = "Apply the freeform apply_patch cancel parity smoke patch."
FOLLOWUP_USER_TEXT = "CLI freeform apply_patch follow-up after canceled patch."
FOLLOWUP_ASSISTANT_TEXT = "CLI freeform apply_patch cancel follow-up answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_file_change_approval_cancel_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/protocol/src/openai_models.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/protocol/src/models.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/handlers/apply_patch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/tool_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class CliFreeformApplyPatchCancelResponsesServer:
    def __init__(self) -> None:
        self._server = FreeformApplyPatchResponsesServer()
        self._server.responses = [
            ev_apply_patch_custom_tool_call(
                "resp-cli-freeform-apply-patch-cancel",
                PATCH_CALL_ID,
                ADD_README_PATCH,
            ),
            ev_final_message(
                "resp-cli-freeform-apply-patch-cancel-followup",
                "msg-cli-freeform-apply-patch-cancel-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]

    def __enter__(self) -> "CliFreeformApplyPatchCancelResponsesServer":
        self._server.__enter__()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self._server.__exit__(exc_type, exc, tb)

    @property
    def url(self) -> str:
        return self._server.url

    @property
    def requests(self) -> list[dict[str, Any]]:
        return self._server.requests


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "first_body_advertises_apply_patch": serialized_contains(first_body, "apply_patch"),
        "second_body_contains_followup_user_text": body_contains(second_body, FOLLOWUP_USER_TEXT),
        "second_body_contains_original_user_text": body_contains(second_body, USER_TEXT),
        "second_body_contains_interrupted_marker": serialized_contains(
            second_body,
            "Conversation interrupted",
        ),
        "second_body_contains_patch_call_id": serialized_contains(second_body, PATCH_CALL_ID),
        "second_body_contains_custom_tool_call": serialized_contains(
            second_body,
            "custom_tool_call",
        ),
        "second_body_contains_custom_tool_output": serialized_contains(
            second_body,
            "custom_tool_call_output",
        ),
    }


def cancel_resume_context_shape_preserved(mock_summary: dict[str, Any]) -> bool:
    return (
        mock_summary["second_body_contains_original_user_text"]
        and mock_summary["second_body_contains_followup_user_text"]
        and mock_summary["second_body_contains_patch_call_id"]
        and mock_summary["second_body_contains_custom_tool_call"]
        and mock_summary["second_body_contains_custom_tool_output"]
    )


def original_has_freeform_cancel_call_with_output(result: dict[str, Any]) -> bool:
    rollouts = result["original_freeform_rollout_summary"].get("rollouts") or []
    return any(
        "apply_patch" in rollout.get("custom_tool_call_names", [])
        and PATCH_CALL_ID in rollout.get("custom_tool_call_output_call_ids", [])
        and rollout.get("contains_patch_call_id")
        and rollout.get("contains_patch_text")
        for rollout in rollouts
    )


def chat_backend_has_freeform_cancel_timeline(result: dict[str, Any]) -> bool:
    packages = result["chat_freeform_timeline_summary"].get("packages") or []
    return any(
        package.get("timeline_tool_call_count", 0) >= 1
        and package.get("timeline_tool_output_count", 0) >= 1
        and package.get("timeline_command_call_count") == 0
        and package.get("timeline_command_output_count") == 0
        and package.get("journal_custom_apply_patch_call_count", 0) >= 1
        and package.get("journal_custom_tool_call_output_count", 0) >= 1
        and package.get("journal_has_patch_call_id")
        and package.get("journal_has_patch_text")
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

    with CliFreeformApplyPatchCancelResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        write_freeform_models_cache(codex_home)
        prior_cancel_turn = cancel_tui.CANCEL_TURN
        cancel_tui.CANCEL_TURN = SimpleNamespace(
            user_text=USER_TEXT,
            final_text=FOLLOWUP_ASSISTANT_TEXT,
        )
        try:
            file_change_tui = cancel_tui.run_cli_file_change_cancel_tui(
                codex_bin,
                workspace,
                codex_home,
                config_overrides,
                mock_server,
                cancel_bytes=b"\x1b",
            )
        finally:
            cancel_tui.CANCEL_TURN = prior_cancel_turn
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
        result["chat_freeform_timeline_summary"] = summarize_freeform_chat_timeline(
            chat_root,
        )
    else:
        result["original_freeform_rollout_summary"] = summarize_freeform_original_rollouts(
            codex_home,
        )
    return result


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Freeform Apply Patch Cancel Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow real CLI/TUI freeform `apply_patch` negative-path",
        "smoke. It drives a provider `custom_tool_call` named `apply_patch`,",
        "chooses the visible negative patch approval option, verifies the",
        "workspace file is not written, and then resumes the thread through",
        "`codex exec --json`.",
        "",
        "It proves the cancel slice only. It does not prove freeform",
        "AcceptForSession cache behavior, network approval, additional-permission",
        "approval, crash recovery, or final user-indistinguishability.",
        "",
        "## Result",
        "",
        f"- passed: `{summary['passed']}`",
        f"- original TUI reached file-change approval: `{summary['original_tui_reached_file_change_approval']}`",
        f"- `.chat` TUI reached file-change approval: `{summary['chat_backend_tui_reached_file_change_approval']}`",
        f"- workspace remained unmodified on both backends: `{summary['workspace_remained_unmodified']}`",
        f"- normalized follow-up CLI output equal: `{summary['normalized_followup_exec_equal']}`",
        f"- mock request summaries equal: `{summary['mock_request_summaries_equal']}`",
        f"- cancel follow-up context shape preserved: `{summary['followup_context_preserved_after_freeform_cancel']}`",
        f"- durable line counts equal: `{summary['final_durable_line_counts_equal']}`",
        f"- `.chat` package keeps freeform abort output as neutral tool output: `{summary['chat_backend_has_freeform_cancel_timeline']}`",
        "",
        "## Evidence",
        "",
        "- `summary.json`",
        "- `original/cli-freeform-apply-patch-cancel-response.json`",
        "- `chat-backend/cli-freeform-apply-patch-cancel-response.json`",
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
            "cli-freeform-apply-patch-cancel-smoke-"
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
        "scope": "cli-freeform-apply-patch-cancel-smoke",
        "matrix_slice": [
            "T04-adjacent",
            "T05-adjacent",
            "T06-freeform-negative-adjacent",
            "R01-adjacent",
        ],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_reached_file_change_approval": original_result["file_change_tui"][
            "file_change_approval_prompt_visible"
        ],
        "chat_backend_tui_reached_file_change_approval": chat_result["file_change_tui"][
            "file_change_approval_prompt_visible"
        ],
        "original_tui_sent_file_change_cancel": original_result["file_change_tui"][
            "sent_file_change_cancel"
        ],
        "chat_backend_tui_sent_file_change_cancel": chat_result["file_change_tui"][
            "sent_file_change_cancel"
        ],
        "original_tui_final_visible": original_result["file_change_tui"][
            "final_answer_visible"
        ],
        "chat_backend_tui_final_visible": chat_result["file_change_tui"][
            "final_answer_visible"
        ],
        "original_tui_no_output_visible": original_result["file_change_tui"][
            "no_output_visible"
        ],
        "chat_backend_tui_no_output_visible": chat_result["file_change_tui"][
            "no_output_visible"
        ],
        "original_tui_interrupted_visible": original_result["file_change_tui"][
            "interrupted_visible"
        ],
        "chat_backend_tui_interrupted_visible": chat_result["file_change_tui"][
            "interrupted_visible"
        ],
        "tui_response_request_counts_equal_after_freeform_cancel": (
            original_result["file_change_tui"]["response_request_count_after_tui"]
            == chat_result["file_change_tui"]["response_request_count_after_tui"]
            == 1
        ),
        "workspace_remained_unmodified": (
            original_result["readme_after_tui"] is None
            and chat_result["readme_after_tui"] is None
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "followup_context_preserved_after_freeform_cancel": (
            cancel_resume_context_shape_preserved(original_mock)
            and cancel_resume_context_shape_preserved(chat_mock)
        ),
        "mock_cancel_resume_context_shape_equal": (
            original_mock["second_body_contains_original_user_text"]
            == chat_mock["second_body_contains_original_user_text"]
            and original_mock["second_body_contains_followup_user_text"]
            == chat_mock["second_body_contains_followup_user_text"]
            and original_mock["second_body_contains_interrupted_marker"]
            == chat_mock["second_body_contains_interrupted_marker"]
            and original_mock["second_body_contains_patch_call_id"]
            == chat_mock["second_body_contains_patch_call_id"]
            and original_mock["second_body_contains_custom_tool_call"]
            == chat_mock["second_body_contains_custom_tool_call"]
            and original_mock["second_body_contains_custom_tool_output"]
            == chat_mock["second_body_contains_custom_tool_output"]
        ),
        "mock_context_has_custom_tool_output_after_cancel": (
            original_mock["second_body_contains_custom_tool_output"]
            and chat_mock["second_body_contains_custom_tool_output"]
        ),
        "original_has_freeform_cancel_call_with_output": (
            original_has_freeform_cancel_call_with_output(original_result)
        ),
        "chat_backend_has_freeform_cancel_timeline": (
            chat_backend_has_freeform_cancel_timeline(chat_result)
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
            "chat_freeform_timeline_summary": chat_result["chat_freeform_timeline_summary"],
        },
        "not_yet_proven": [
            "CLI/TUI freeform apply_patch AcceptForSession cache behavior",
            "network approval through CLI/TUI",
            "additional-permission approval through CLI/TUI",
            "approval process-kill or crash recovery",
            "complete T06 data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_file_change_approval"],
            summary["chat_backend_tui_reached_file_change_approval"],
            summary["original_tui_sent_file_change_cancel"],
            summary["chat_backend_tui_sent_file_change_cancel"],
            not summary["original_tui_final_visible"],
            not summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_freeform_cancel"],
            summary["workspace_remained_unmodified"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["followup_context_preserved_after_freeform_cancel"],
            summary["mock_cancel_resume_context_shape_equal"],
            summary["mock_context_has_custom_tool_output_after_cancel"],
            summary["original_has_freeform_cancel_call_with_output"],
            summary["chat_backend_has_freeform_cancel_timeline"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI freeform apply_patch negative "
        "path: both backends receive a provider custom_tool_call named "
        "apply_patch, show the same visible file-change approval path, cancel it "
        "through the TUI shortcut, leave the workspace unmodified, avoid a final "
        "assistant answer for the canceled turn, preserve the same follow-up "
        "resume context shape with the original freeform abort "
        "custom_tool_call_output, map that output as neutral tool_output rather "
        "than command_output, retain the freeform source transport, and keep "
        "durable line counts equal. It is not full freeform apply_patch parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/cli-freeform-apply-patch-cancel-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/cli-freeform-apply-patch-cancel-response.json",
        chat_result,
    )
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
