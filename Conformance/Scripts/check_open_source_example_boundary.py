#!/usr/bin/env python3
"""Check the iOS examples for public-boundary release hazards."""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


GATE_NAME = "msp-open-source-example-boundary"

EXAMPLE_ROOTS = [
    "Examples/iOS/MSPPlaygroundApp",
    "Examples/iOS/PhotoSorter",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer",
]

PRIVATE_MARKERS = [
    "/Volumes/PrivateReference/Projects/Readex",
    "/Volumes/PrivateReference/Projects/Readex-Internal",
    "PrivateReadexReferenceApp",
    "PRIVATE_READEX_REFERENCE_",
    "PrivateReadexReference",
    "private-readex-reference",
    "private-readex-reference-",
    "com.example.PrivateReadexReference",
    "READOS_SOURCE_ROOT",
    "READEX_SOURCE_ROOT",
    "ReadOS 本地",
    "本地 ReadOS",
]

LEGACY_PUBLIC_NAME_MARKERS = [
    "MSPTranscriptRenderer",
    "ReadOS",
    "ReadexRuntime",
    "ReadexResponses",
    "ReadexTranscript",
    "ReadexMode",
    "ReadexShell",
    "ReadexStreaming",
    "ReadexWorkspace",
    "ReadexTool",
]

LEGACY_PUBLIC_NAME_ALLOWED_PATH_PARTS = [
    "/RuntimeResources/",
]

PRUNE_DIR_NAMES = {
    ".build",
    ".git",
    ".swiftpm",
    "DerivedData",
}

TEXT_SUFFIXES = {
    ".css",
    ".h",
    ".html",
    ".js",
    ".json",
    ".m",
    ".md",
    ".plist",
    ".py",
    ".sh",
    ".swift",
    ".txt",
    ".xcscheme",
    ".yml",
    ".yaml",
}


@dataclass(frozen=True)
class Finding:
    path: str
    rule_id: str
    message: str


def relative(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root).as_posix()


def text_files(scan_root: Path) -> list[Path]:
    paths: list[Path] = []
    for current_root, dirs, files in os.walk(scan_root):
        dirs[:] = [name for name in dirs if name not in PRUNE_DIR_NAMES]
        current = Path(current_root)
        for name in files:
            path = current / name
            if path.suffix in TEXT_SUFFIXES or path.name == "project.pbxproj":
                paths.append(path)
    return sorted(paths)


def source_archive_findings(root: Path, example_roots: list[Path]) -> list[Finding]:
    findings: list[Finding] = []
    for example_root in example_roots:
        for path in example_root.rglob("SourceArchive"):
            if path.is_dir():
                findings.append(
                    Finding(
                        path=relative(path, root),
                        rule_id="source-archive-present",
                        message="SourceArchive is private provenance material and must not be in a public example tree.",
                    )
                )
    return findings


def private_marker_findings(root: Path, example_roots: list[Path]) -> list[Finding]:
    findings: list[Finding] = []
    for example_root in example_roots:
        for path in text_files(example_root):
            relative_path = relative(path, root)
            for marker in PRIVATE_MARKERS:
                if marker in relative_path:
                    findings.append(
                        Finding(
                            path=relative_path,
                            rule_id="private-product-marker",
                            message=f"path contains private product marker {marker!r}",
                        )
                    )
                    break
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for marker in PRIVATE_MARKERS:
                if marker in text:
                    findings.append(
                        Finding(
                            path=relative_path,
                            rule_id="private-product-marker",
                            message=f"contains private product marker {marker!r}",
                        )
                    )
                    break
    return findings


def legacy_public_name_findings(root: Path, example_roots: list[Path]) -> list[Finding]:
    findings: list[Finding] = []
    for example_root in example_roots:
        for path in text_files(example_root):
            relative_path = relative(path, root)
            if any(part in f"/{relative_path}" for part in LEGACY_PUBLIC_NAME_ALLOWED_PATH_PARTS):
                continue
            for marker in LEGACY_PUBLIC_NAME_MARKERS:
                if marker in relative_path:
                    findings.append(
                        Finding(
                            path=relative_path,
                            rule_id="legacy-public-component-name",
                            message=f"path contains legacy public component marker {marker!r}",
                        )
                    )
                    break
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for marker in LEGACY_PUBLIC_NAME_MARKERS:
                if marker in text:
                    findings.append(
                        Finding(
                            path=relative_path,
                            rule_id="legacy-public-component-name",
                            message=f"contains legacy public component marker {marker!r}",
                        )
                    )
                    break
    return findings


def build_report(root: Path) -> dict[str, Any]:
    root = root.resolve()
    example_roots = [root / item for item in EXAMPLE_ROOTS]
    missing_examples = [
        relative(path, root)
        for path in example_roots
        if not path.is_dir()
    ]

    findings: list[Finding] = []
    if missing_examples:
        findings.extend(
            Finding(
                path=path,
                rule_id="missing-example-root",
                message="expected iOS example root is missing",
            )
            for path in missing_examples
        )
    else:
        findings.extend(source_archive_findings(root, example_roots))
        findings.extend(private_marker_findings(root, example_roots))
        findings.extend(legacy_public_name_findings(root, example_roots))

    return {
        "passed": not findings,
        "gate": GATE_NAME,
        "root": str(root),
        "example_roots": EXAMPLE_ROOTS,
        "private_markers": PRIVATE_MARKERS,
        "legacy_public_name_markers": LEGACY_PUBLIC_NAME_MARKERS,
        "legacy_public_name_allowed_path_parts": LEGACY_PUBLIC_NAME_ALLOWED_PATH_PARTS,
        "finding_count": len(findings),
        "findings": [
            {
                "path": finding.path,
                "rule_id": finding.rule_id,
                "message": finding.message,
            }
            for finding in findings
        ],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="repository root to scan")
    parser.add_argument("--report", required=True, help="JSON report path")
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="write the report but do not fail the process when findings exist",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).expanduser().resolve()
    report_path = Path(args.report).expanduser().resolve()
    report = build_report(root)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if report["passed"]:
        print("MSP open-source example boundary gate passed")
        print(f"report={report_path}")
        return 0

    print("MSP open-source example boundary gate found release hazards")
    print(f"report={report_path}")
    for finding in report["findings"]:
        print(f"- {finding['path']}: {finding['message']}")
    return 0 if args.report_only else 1


if __name__ == "__main__":
    raise SystemExit(main())
