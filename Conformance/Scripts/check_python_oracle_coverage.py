#!/usr/bin/env python3
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ORACLE_ROOT = ROOT / "Conformance" / "ReferenceOutputs" / "MSPV1Debian12Oracle"
COVERAGE_PATH = ROOT / "Conformance" / "Fixtures" / "MSPV1PythonRuntimeCoverage.json"


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def python_related(case):
    text = json.dumps(case, ensure_ascii=False).lower()
    return "python3" in text or "python" in text


def case_id_set(cases):
    return {case["id"] for case in cases}


def pty_runtime_gate(coverage):
    gate = coverage.get("current_pty_runtime_gate")
    if isinstance(gate, dict):
        return gate
    legacy = coverage.get("blocked_until_pty_runtime")
    if isinstance(legacy, dict):
        return legacy
    raise KeyError("coverage.current_pty_runtime_gate is missing")


def main():
    coverage = load_json(COVERAGE_PATH)
    noninteractive = load_json(ORACLE_ROOT / "noninteractive-cases.json")["cases"]
    pty = load_json(ORACLE_ROOT / "pty-cases.json")["cases"]

    gate = coverage["current_ios_embedded_cpython_gate"]
    selector = gate["selector"]
    include_commands = set(selector.get("include_commands", []))
    exclude_commands = set(selector.get("exclude_commands", []))
    selected = [
        case
        for case in noninteractive
        if include_commands.issubset(set(case.get("commands", [])))
        and exclude_commands.isdisjoint(set(case.get("commands", [])))
    ]
    selected_ids = [case["id"] for case in selected]
    expected_selected_ids = gate["expected_case_ids"]

    noninteractive_python_ids = {
        case["id"]
        for case in noninteractive
        if python_related(case)
    }
    node_blocked_ids = set(coverage["blocked_until_node_runtime"]["case_ids"])
    pty_python_ids = {
        case["id"]
        for case in pty
        if python_related(case)
    }
    pty_runtime_gate_ids = set(pty_runtime_gate(coverage)["case_ids"])
    accounted_noninteractive = set(expected_selected_ids) | node_blocked_ids

    failures = []
    if selected_ids != expected_selected_ids:
        failures.append(
            "current_ios_embedded_cpython_gate mismatch: "
            f"expected {expected_selected_ids}, actual {selected_ids}"
        )
    if accounted_noninteractive != noninteractive_python_ids:
        failures.append(
            "noninteractive Python coverage is not fully accounted: "
            f"expected/accounted={sorted(accounted_noninteractive)}, "
            f"actual={sorted(noninteractive_python_ids)}"
        )
    if pty_runtime_gate_ids != pty_python_ids:
        failures.append(
            "PTY Python coverage is not fully accounted: "
            f"expected/accounted={sorted(pty_runtime_gate_ids)}, "
            f"actual={sorted(pty_python_ids)}"
        )

    summary = {
        "noninteractive_python_case_count": len(noninteractive_python_ids),
        "ios_embedded_cpython_gate_case_count": len(expected_selected_ids),
        "node_blocked_case_count": len(node_blocked_ids),
        "pty_python_case_count": len(pty_python_ids),
        "pty_runtime_gate_case_count": len(pty_runtime_gate_ids),
        "pty_runtime_gate_status": "executable-by-debian12-pty-oracle",
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
