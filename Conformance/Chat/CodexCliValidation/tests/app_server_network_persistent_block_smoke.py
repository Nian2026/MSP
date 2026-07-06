#!/usr/bin/env python3
"""Run app-server managed-network persistent block parity smoke.

This source-backed validation covers a narrow Codex app-server slice:

    first turn triggers managed-network approval
    client replies with ApplyNetworkPolicyAmendment { Deny }
    rule is persisted to execpolicy and saved-rule context is recorded
    second same-host turn is denied without another approval request

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06 approval or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
from typing import Any

import app_server_network_persistent_allow_smoke as allow_smoke
from app_server_durable_turn_smoke import (
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    VALIDATION_DIR,
    ensure_binary,
    utc_now_iso,
    write_json,
)
from app_server_network_approval_smoke import (
    APP_SERVER_BIN,
    NETWORK_HOST,
    ensure_app_server_binary,
)


USER_TEXT_1 = "Run the first app-server network persistent block command."
USER_TEXT_2 = "Run the second app-server network persistent block command."
FINAL_TEXT_1 = "App-server network persistent block first answer."
FINAL_TEXT_2 = "App-server network persistent block second answer."
CALL_ID_1 = "call-app-network-persistent-block-1"
CALL_ID_2 = "call-app-network-persistent-block-2"
NETWORK_RULE_SAVED_TEXT = (
    f"Denied network rule saved in execpolicy (denylist): {NETWORK_HOST}"
)

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/app-server/README.md",
        "lines": "1449-1457",
        "finding": "Command approval responses include applyNetworkPolicyAmendment, and the payload accepts a network_policy_amendment for allow or deny.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
        "lines": "623-742",
        "finding": "A Deny NetworkPolicyAmendment persists the rule, records saved-rule context, caches a session deny, and returns a denied network decision.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/context/network_rule_saved.rs",
        "lines": "33-41",
        "finding": "The saved-rule context text for deny is 'Denied network rule saved in execpolicy (denylist): <host>'.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/app-server-protocol/schema/typescript/v2/NetworkPolicyRuleAction.ts",
        "lines": "5",
        "finding": "The app-server v2 schema exposes NetworkPolicyRuleAction as 'allow' or 'deny'.",
    },
]


def install_block_overrides() -> None:
    allow_smoke.USER_TEXT_1 = USER_TEXT_1
    allow_smoke.USER_TEXT_2 = USER_TEXT_2
    allow_smoke.FINAL_TEXT_1 = FINAL_TEXT_1
    allow_smoke.FINAL_TEXT_2 = FINAL_TEXT_2
    allow_smoke.CALL_ID_1 = CALL_ID_1
    allow_smoke.CALL_ID_2 = CALL_ID_2
    allow_smoke.CLIENT_USER_PREFIX = "client-user-network-persistent-block"
    allow_smoke.NETWORK_RULE_SAVED_TEXT = NETWORK_RULE_SAVED_TEXT
    allow_smoke.SOURCE_FINDINGS = SOURCE_FINDINGS
    allow_smoke.choose_allow_amendment = choose_deny_amendment
    allow_smoke.summarize_execpolicy_network_rules = summarize_execpolicy_network_rules


def choose_deny_amendment(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params") or {}
    for amendment in params.get("proposedNetworkPolicyAmendments") or []:
        if amendment.get("action") == "deny":
            return amendment
    context = params.get("networkApprovalContext") or {}
    return {"host": context.get("host") or NETWORK_HOST, "action": "deny"}


def summarize_execpolicy_network_rules(codex_home: pathlib.Path) -> dict[str, Any]:
    rule_files = sorted(codex_home.rglob("*.rules"))
    rules = []
    for path in rule_files:
        text = path.read_text(errors="replace")
        rules.append(
            {
                "path": str(path),
                "contains_network_host": NETWORK_HOST in text,
                "contains_allow": "allow" in text.lower(),
                "contains_deny": "deny" in text.lower(),
                "contains_expected_protocol": (
                    'protocol="http"' in text or "https_connect" in text
                ),
                "text_tail": text[-1200:],
            }
        )
    return {
        "rule_file_count": len(rule_files),
        "rules": rules,
        "has_persistent_allow_rule": any(
            rule["contains_network_host"]
            and rule["contains_allow"]
            and rule["contains_expected_protocol"]
            for rule in rules
        ),
        "has_persistent_deny_rule": any(
            rule["contains_network_host"]
            and rule["contains_deny"]
            and rule["contains_expected_protocol"]
            for rule in rules
        ),
    }


def scenario_ok(result: dict[str, Any]) -> bool:
    request = result["normalized_first_approval_request"]
    mock = result["mock_server_summary"]
    visible = result["normalized_thread_read_visible"]
    rules = result["execpolicy_network_rules"]
    if "result" not in result["first_turn_start_response"]:
        return False
    if "result" not in result["second_turn_start_response"]:
        return False
    if "result" not in result["thread_read_response"]:
        return False
    if not request["thread_id_matches"]:
        return False
    if request["network_host"] != NETWORK_HOST:
        return False
    if request["network_protocol"] != "http":
        return False
    if request["proposed_actions"] != ["allow", "deny"]:
        return False
    if "applyNetworkPolicyAmendment" not in request["available_decision_kinds"]:
        return False
    if result["allow_amendment_sent"].get("action") != "deny":
        return False
    if result["allow_amendment_sent"].get("host") != NETWORK_HOST:
        return False
    if result["approval_request_count"] != 1:
        return False
    if not result["second_turn_completed_without_network_approval"]:
        return False
    if not rules["has_persistent_deny_rule"]:
        return False
    if not (
        mock["response_request_count"] == 4
        and mock["contains_first_call_output"]
        and mock["contains_second_call_output"]
        and mock["contains_first_final_text"]
        and mock["contains_saved_rule_context"]
    ):
        return False
    if not (
        visible["contains_first_user_text"]
        and visible["contains_second_user_text"]
        and visible["contains_first_final_text"]
        and visible["contains_second_final_text"]
    ):
        return False
    if result["tree"] == "chat-backend":
        chat_summary = result["chat_persistent_allow_summary"]
        return (
            chat_summary["has_two_command_timeline_pairs"]
            and chat_summary["has_source_transport_for_both_calls"]
            and chat_summary["has_saved_rule_source_transport"]
            and chat_summary["has_saved_rule_timeline_context"]
        )
    original_summary = result["original_persistent_allow_summary"]
    return (
        original_summary["has_two_network_calls"]
        and original_summary["has_saved_rule_context"]
    )


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# App-Server Network Persistent Block Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow app-server managed-network persistent block smoke.",
        "It drives the real app-server stdio path in both vendored trees,",
        "responds to the first network approval with",
        "`applyNetworkPolicyAmendment(deny)`, then verifies the next same-host",
        "turn is denied without another network approval request.",
        "",
        "It does not prove the real TUI persistent block shortcut, non-default",
        "deny amendment UI, arbitrary crash recovery, or final Codex",
        "user-indistinguishability.",
        "",
        "## Result",
        "",
        f"- all scenarios ok: `{summary['all_scenarios_ok']}`",
        f"- normalized first approval request equal: `{summary['normalized_first_approval_request_equal']}`",
        f"- normalized live sequence equal: `{summary['normalized_live_sequence_equal']}`",
        f"- normalized thread/read visible equal: `{summary['normalized_thread_read_visible_equal']}`",
        f"- mock summaries equal: `{summary['mock_summaries_equal']}`",
        f"- original execpolicy persistent deny rule: `{summary['original_execpolicy_has_persistent_deny_rule']}`",
        f"- `.chat` execpolicy persistent deny rule: `{summary['chat_backend_execpolicy_has_persistent_deny_rule']}`",
        f"- original saved-rule context persisted: `{summary['original_has_saved_rule_context_persisted']}`",
        f"- `.chat` saved-rule context in source transport/timeline: `{summary['chat_backend_has_saved_rule_source_transport']}` / `{summary['chat_backend_has_saved_rule_timeline_context']}`",
        f"- second same-host turn avoided another network approval on both backends: `{summary['second_turn_avoided_network_approval_on_both']}`",
        "",
        "## Source Basis",
        "",
    ]
    for finding in SOURCE_FINDINGS:
        lines.append(
            f"- `{finding['file']}:{finding['lines']}`: {finding['finding']}"
        )
    lines.extend(
        [
            "",
            "## Evidence",
            "",
            "- `summary.json`",
            "- `original/network-persistent-block-response.json`",
            "- `chat-backend/network-persistent-block-response.json`",
            "",
        ]
    )
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    install_block_overrides()
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-network-persistent-block-smoke-"
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
        "original_cli": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat_backend_cli": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
        "original_app_server": ensure_app_server_binary(
            ORIGINAL_CODEX_RS,
            args.build_if_missing,
        ),
        "chat_backend_app_server": ensure_app_server_binary(
            CHAT_BACKEND_CODEX_RS,
            args.build_if_missing,
        ),
    }

    run_root = output_dir / "run"
    original = allow_smoke.run_scenario(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat = allow_smoke.run_scenario(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_rules = original["execpolicy_network_rules"]
    chat_rules = chat["execpolicy_network_rules"]
    original_persistent = original["original_persistent_allow_summary"]
    chat_persistent = chat["chat_persistent_allow_summary"]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-network-persistent-block-smoke",
        "matrix_slice": ["T06-network-persistent-block", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": allow_smoke.GATE_FILES_READ,
        "source_files_read": allow_smoke.SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "binary_checks": binary_checks,
        "original_ok": scenario_ok(original),
        "chat_backend_ok": scenario_ok(chat),
        "normalized_first_approval_request_equal": (
            original["normalized_first_approval_request"]
            == chat["normalized_first_approval_request"]
        ),
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat["normalized_live_sequence"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"]
            == chat["normalized_thread_read_visible"]
        ),
        "mock_summaries_equal": (
            original["mock_server_summary"] == chat["mock_server_summary"]
        ),
        "original_execpolicy_has_persistent_deny_rule": original_rules[
            "has_persistent_deny_rule"
        ],
        "chat_backend_execpolicy_has_persistent_deny_rule": chat_rules[
            "has_persistent_deny_rule"
        ],
        "original_has_saved_rule_context_persisted": original_persistent[
            "has_saved_rule_context"
        ],
        "chat_backend_has_saved_rule_source_transport": chat_persistent[
            "has_saved_rule_source_transport"
        ],
        "chat_backend_has_saved_rule_timeline_context": chat_persistent[
            "has_saved_rule_timeline_context"
        ],
        "second_turn_avoided_network_approval_on_both": (
            original["second_turn_completed_without_network_approval"]
            and chat["second_turn_completed_without_network_approval"]
        ),
        "original": original,
        "chat_backend": chat,
    }
    summary["all_scenarios_ok"] = bool(
        summary["original_ok"]
        and summary["chat_backend_ok"]
        and summary["normalized_first_approval_request_equal"]
        and summary["normalized_live_sequence_equal"]
        and summary["normalized_thread_read_visible_equal"]
        and summary["mock_summaries_equal"]
        and summary["original_execpolicy_has_persistent_deny_rule"]
        and summary["chat_backend_execpolicy_has_persistent_deny_rule"]
        and summary["original_has_saved_rule_context_persisted"]
        and summary["chat_backend_has_saved_rule_source_transport"]
        and summary["chat_backend_has_saved_rule_timeline_context"]
        and summary["second_turn_avoided_network_approval_on_both"]
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original" / "network-persistent-block-response.json", original)
    write_json(output_dir / "chat-backend" / "network-persistent-block-response.json", chat)
    write_report(output_dir, summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
