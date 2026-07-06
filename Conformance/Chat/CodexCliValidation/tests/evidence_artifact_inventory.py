#!/usr/bin/env python3
"""Audit referenced Codex `.chat` validation evidence artifacts.

The public validation package is only useful as evidence if the
machine-readable artifacts it cites are actually present. By default this script
scans the bounded public evidence index, extracts referenced
`results/.../summary.json`, `results/.../report.md`,
`phase-results/.../summary.json`, and `phase-results/.../report.md` paths, and
checks whether the files exist.

Use --scan-all-docs for local diagnostics over historical Markdown notes.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import re
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = VALIDATION_DIR.parents[2]
PUBLIC_EVIDENCE_DOC = VALIDATION_DIR / "PUBLIC_EVIDENCE.md"
RESULT_REF_RE = re.compile(
    r"(?<![\w./-])((?:results|phase-results)/[A-Za-z0-9._/\-]+/(?:summary\.json|report\.md))"
)
STALE_UPSTREAM_RE = re.compile(r"upstream/openai-codex-(?:original|chat-backend)")
RAW_PUBLIC_IDENTITY_MARKERS = (
    ("installationId", "installationId"),
    ('"serverName"', "serverName"),
    ("userAgent", "userAgent"),
    ("remoteControl/status/changed", "remoteControlStatus"),
    ("Codex Desktop/", "codexDesktopUserAgent"),
)


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()


def rel(path: pathlib.Path) -> str:
    try:
        return path.relative_to(VALIDATION_DIR).as_posix()
    except ValueError:
        return display_path(path)


def display_path(path: pathlib.Path) -> str:
    resolved = path.resolve()
    try:
        return f"<repo-root>/{resolved.relative_to(REPO_ROOT).as_posix()}"
    except ValueError:
        return "<validation-results-root>" if resolved == validation_results_root() else resolved.as_posix()


def iter_markdown_docs(
    selected_docs: list[pathlib.Path] | None = None,
    *,
    scan_all_docs: bool = False,
) -> list[pathlib.Path]:
    if selected_docs is not None:
        docs = []
        for doc in selected_docs:
            resolved = doc if doc.is_absolute() else VALIDATION_DIR / doc
            docs.append(resolved.resolve())
    elif scan_all_docs:
        docs = list(VALIDATION_DIR.glob("*.md"))
        docs.extend(VALIDATION_DIR.glob("reports/*.md"))
    else:
        docs = [PUBLIC_EVIDENCE_DOC]
    return sorted(
        path
        for path in docs
        if path.is_file()
        and not (
            path.parent == VALIDATION_DIR / "reports"
            and path.name.startswith("evidence-artifact-inventory-")
        )
    )


def extract_result_refs(path: pathlib.Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return {ref for ref in RESULT_REF_RE.findall(text) if "..." not in ref}


def extract_stale_upstream_refs(path: pathlib.Path) -> int:
    text = path.read_text(encoding="utf-8", errors="replace")
    return len(STALE_UPSTREAM_RE.findall(text))


def result_ref_exists(ref: str, assumed_existing_refs: set[str]) -> bool:
    if ref in assumed_existing_refs:
        return True
    if (VALIDATION_DIR / ref).is_file():
        return True
    results_prefix = "results/"
    if ref.startswith(results_prefix):
        return (validation_results_root() / ref.removeprefix(results_prefix)).is_file()
    phase_results_prefix = "phase-results/"
    if ref.startswith(phase_results_prefix):
        return (VALIDATION_DIR / ref).is_file()
    return False


def phase_result_files() -> list[str]:
    phase_results_dir = VALIDATION_DIR / "phase-results"
    if not phase_results_dir.is_dir():
        return []
    return sorted(
        path.relative_to(VALIDATION_DIR).as_posix()
        for path in phase_results_dir.rglob("*")
        if path.is_file()
    )


def raw_identity_findings(paths: list[str]) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    for ref in paths:
        path = VALIDATION_DIR / ref
        try:
            contents = path.read_bytes()
        except OSError:
            continue
        if b"\0" in contents[:4096]:
            continue
        text = contents.decode("utf-8", errors="ignore")
        for marker, label in RAW_PUBLIC_IDENTITY_MARKERS:
            if marker in text:
                findings.append({"path": ref, "marker": label})
    return findings


def build_summary(
    assumed_existing_refs: set[str] | None = None,
    selected_docs: list[pathlib.Path] | None = None,
    scan_all_docs: bool = False,
) -> dict[str, Any]:
    assumed_existing_refs = assumed_existing_refs or set()
    docs = iter_markdown_docs(
        selected_docs=selected_docs,
        scan_all_docs=scan_all_docs,
    )
    references_by_doc: dict[str, list[str]] = {}
    stale_upstream_by_doc: dict[str, int] = {}
    all_refs: set[str] = set()

    for doc in docs:
        refs = sorted(extract_result_refs(doc))
        if refs:
            references_by_doc[rel(doc)] = refs
            all_refs.update(refs)
        stale_count = extract_stale_upstream_refs(doc)
        if stale_count:
            stale_upstream_by_doc[rel(doc)] = stale_count

    existing = sorted(
        ref for ref in all_refs if result_ref_exists(ref, assumed_existing_refs)
    )
    missing = sorted(
        ref
        for ref in all_refs
        if not result_ref_exists(ref, assumed_existing_refs)
    )
    actual_phase_results = phase_result_files()
    referenced_phase_results = {ref for ref in all_refs if ref.startswith("phase-results/")}
    unlisted_phase_results = sorted(set(actual_phase_results) - referenced_phase_results)
    identity_findings = raw_identity_findings(actual_phase_results)

    results_dir = validation_results_root()
    source_results_dir = VALIDATION_DIR / "results"
    phase_results_dir = VALIDATION_DIR / "phase-results"
    status = "pass" if (
        results_dir.is_dir()
        or source_results_dir.is_dir()
        or phase_results_dir.is_dir()
    ) and not missing and not unlisted_phase_results and not identity_findings else "fail"

    return {
        "generated_at": utc_now(),
        "validation_root": display_path(VALIDATION_DIR),
        "public_evidence_doc": display_path(PUBLIC_EVIDENCE_DOC),
        "scan_all_docs": scan_all_docs,
        "status": status,
        "docs_scanned_count": len(docs),
        "referencing_docs_count": len(references_by_doc),
        "results_dir_exists": results_dir.is_dir() or source_results_dir.is_dir(),
        "source_results_dir_exists": source_results_dir.is_dir(),
        "phase_results_dir_exists": phase_results_dir.is_dir(),
        "out_of_tree_results_dir": display_path(results_dir),
        "out_of_tree_results_dir_exists": results_dir.is_dir(),
        "referenced_result_count": len(all_refs),
        "existing_result_count": len(existing),
        "missing_result_count": len(missing),
        "phase_result_file_count": len(actual_phase_results),
        "unlisted_phase_result_count": len(unlisted_phase_results),
        "unlisted_phase_results": unlisted_phase_results,
        "raw_identity_marker_count": len(identity_findings),
        "raw_identity_findings": identity_findings,
        "existing_results": existing,
        "missing_results": missing,
        "references_by_doc": references_by_doc,
        "stale_upstream_reference_count": sum(stale_upstream_by_doc.values()),
        "stale_upstream_references_by_doc": stale_upstream_by_doc,
    }


def write_json(summary: dict[str, Any], path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_report(summary: dict[str, Any], path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    missing: list[str] = summary["missing_results"]
    existing: list[str] = summary["existing_results"]
    unlisted_phase_results: list[str] = summary["unlisted_phase_results"]
    raw_identity_findings: list[dict[str, str]] = summary["raw_identity_findings"]
    stale_by_doc: dict[str, int] = summary["stale_upstream_references_by_doc"]

    lines = [
        "# Evidence Artifact Inventory - 2026-07-03",
        "",
        "This is a public evidence audit for the Codex CLI `.chat` validation package.",
        "It checks whether Markdown evidence documents reference machine-readable",
        "`results/...` or `phase-results/...` artifacts that are",
        "actually present in this repository snapshot.",
        "",
        "It is not a parity test and does not prove runtime behavior.",
        "",
        "## Gate Files Read",
        "",
        "This audit was run after the required `.chat` execution gate files were read:",
        "",
        "- `Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt`",
        "- `Spec/Chat/README.md`",
        "- `Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md`",
        "- `Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md`",
        "- `Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md`",
        "",
        "## Summary",
        "",
        f"- status: `{summary['status']}`",
        f"- scan all docs: `{str(summary['scan_all_docs']).lower()}`",
        f"- docs scanned: `{summary['docs_scanned_count']}`",
        f"- docs with result references: `{summary['referencing_docs_count']}`",
        f"- `results/` directory exists: `{str(summary['results_dir_exists']).lower()}`",
        f"- `phase-results/` directory exists: `{str(summary['phase_results_dir_exists']).lower()}`",
        f"- referenced result artifacts: `{summary['referenced_result_count']}`",
        f"- existing referenced artifacts: `{summary['existing_result_count']}`",
        f"- missing referenced artifacts: `{summary['missing_result_count']}`",
        f"- phase result files: `{summary['phase_result_file_count']}`",
        f"- unlisted phase result files: `{summary['unlisted_phase_result_count']}`",
        f"- raw public identity markers: `{summary['raw_identity_marker_count']}`",
        f"- stale `upstream/openai-codex-*` references: `{summary['stale_upstream_reference_count']}`",
        "",
        "## Interpretation",
        "",
    ]

    if summary["status"] == "pass":
        lines.append("All referenced result artifacts were present.")
    else:
        lines.extend(
            [
                "The current repository snapshot does not satisfy the public evidence boundary.",
                "Either a referenced result artifact is missing, a retained `phase-results/`",
                "file is not listed in the scanned public evidence index, or a retained",
                "artifact still contains raw runtime identity markers.",
            ]
        )

    lines.extend(["", "## Existing Referenced Artifacts", ""])
    if existing:
        for ref in existing[:120]:
            lines.append(f"- `{ref}`")
        if len(existing) > 120:
            lines.append(f"- ... `{len(existing) - 120}` more; see JSON summary")
    else:
        lines.append("- none")

    lines.extend(["", "## Missing Referenced Artifacts", ""])
    if missing:
        for ref in missing[:160]:
            lines.append(f"- `{ref}`")
        if len(missing) > 160:
            lines.append(f"- ... `{len(missing) - 160}` more; see JSON summary")
    else:
        lines.append("- none")

    lines.extend(["", "## Unlisted Phase Result Files", ""])
    if unlisted_phase_results:
        lines.append(
            "These files exist under `phase-results/` but are not listed in the scanned public evidence index."
        )
        lines.append("")
        for ref in unlisted_phase_results[:160]:
            lines.append(f"- `{ref}`")
        if len(unlisted_phase_results) > 160:
            lines.append(f"- ... `{len(unlisted_phase_results) - 160}` more; see JSON summary")
    else:
        lines.append("- none")

    lines.extend(["", "## Raw Public Identity Markers", ""])
    if raw_identity_findings:
        lines.append(
            "These retained artifacts contain raw runtime identity markers. Marker values are not printed here."
        )
        lines.append("")
        for finding in raw_identity_findings[:160]:
            lines.append(f"- `{finding['path']}`: `{finding['marker']}`")
        if len(raw_identity_findings) > 160:
            lines.append(f"- ... `{len(raw_identity_findings) - 160}` more; see JSON summary")
    else:
        lines.append("- none")

    lines.extend(["", "## Stale Source Path References", ""])
    if stale_by_doc:
        lines.append(
            "These documents still mention the older `upstream/openai-codex-*` path."
        )
        lines.append(
            "That may be historical context, but current source evidence uses `source-snapshots/`."
        )
        lines.append("")
        for doc, count in sorted(stale_by_doc.items()):
            lines.append(f"- `{doc}`: `{count}`")
    else:
        lines.append("- none")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-output", type=pathlib.Path)
    parser.add_argument("--report-output", type=pathlib.Path)
    parser.add_argument(
        "--doc",
        action="append",
        type=pathlib.Path,
        help=(
            "Limit the scan to one Markdown document. May be repeated. Paths are "
            "relative to the validation root unless absolute. Omit to scan the "
            "public evidence index."
        ),
    )
    parser.add_argument(
        "--scan-all-docs",
        action="store_true",
        help=(
            "Scan every validation Markdown document, including historical local "
            "reports. This is for diagnostics, not the public evidence gate."
        ),
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when referenced result artifacts are missing",
    )
    args = parser.parse_args()

    assumed_existing_refs: set[str] = set()
    if args.json_output:
        try:
            json_ref = args.json_output.resolve().relative_to(VALIDATION_DIR).as_posix()
        except ValueError:
            json_ref = ""
        if RESULT_REF_RE.fullmatch(json_ref):
            assumed_existing_refs.add(json_ref)

    summary = build_summary(
        assumed_existing_refs=assumed_existing_refs,
        selected_docs=args.doc,
        scan_all_docs=args.scan_all_docs,
    )
    if args.json_output:
        write_json(summary, args.json_output)
    if args.report_output:
        write_report(summary, args.report_output)

    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if args.strict and summary["status"] != "pass":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
