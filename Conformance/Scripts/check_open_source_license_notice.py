#!/usr/bin/env python3
"""Check project-level license and notice readiness for the publish tree."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path


GATE_NAME = "msp-open-source-license-notice"


@dataclass(frozen=True)
class Finding:
    path: str
    rule_id: str
    message: str


@dataclass(frozen=True)
class NoticeRequirement:
    requirement_id: str
    terms: tuple[str, ...]
    message: str


ROOT_REQUIRED_FILES = ("LICENSE", "NOTICE")

NOTICE_REQUIREMENTS = (
    NoticeRequirement(
        "project-license-pointer",
        ("license",),
        "root NOTICE must point readers to the project-level license",
    ),
    NoticeRequirement(
        "codex-apply-patch-notice",
        (
            "codex",
            "apply_patch",
            "apache-2.0",
            "third-party-cargo-licenses.json",
            "codex_source_provenance.txt",
        ),
        "root NOTICE must describe the vendored Codex apply_patch runtime and evidence files",
    ),
    NoticeRequirement(
        "example-chat-renderer-notice",
        (
            "examplechattranscriptrenderer",
            "chat-unified-markdown",
            "mathjax-full",
            "remark",
            "micromark",
            "katex",
            "highlight.js",
            "prettier",
            "d3",
            "markmap-view",
            "pagedjs",
            "legacy-spinner",
        ),
        "root NOTICE must name the bundled example transcript renderer third-party assets",
    ),
    NoticeRequirement(
        "lightweight-reader-generated-artifacts-notice",
        (
            "lightweightreader",
            "desktop-ui-conformance.png",
            "mobile-ui-conformance.png",
            "playwright",
            "generated",
        ),
        "root NOTICE must identify generated LightweightReader UI evidence artifacts",
    ),
    NoticeRequirement(
        "swiftpm-dependency-notice",
        ("swift-cgit2", "swiftpm"),
        "root NOTICE must identify public SwiftPM dependencies that are referenced but not vendored",
    ),
    NoticeRequirement(
        "photosorter-optional-dependency-notice",
        ("mlx-swift", "mlx-swift-examples", "swift-transformers"),
        "root NOTICE must identify PhotoSorter optional FastVLM SwiftPM dependencies",
    ),
)

REQUIRED_EVIDENCE_FILES = (
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/katex-LICENSE.txt",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/highlightjs-LICENSE.txt",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/prettier-LICENSE.txt",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/chat-unified-markdown-THIRD-PARTY.json",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/PROJECT-ASSET-PROVENANCE.md",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/KnowledgeMap/d3-LICENSE.txt",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/KnowledgeMap/markmap-view-LICENSE.txt",
    "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Paged/pagedjs-LICENSE.md",
    "Spec/Chat/Demos/LightweightReader/results/GENERATED_ARTIFACTS.md",
    "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Licenses/APACHE-2.0.txt",
    "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Licenses/CODEX-LICENSE-NOTE.md",
    "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Licenses/THIRD-PARTY-CARGO-LICENSES.json",
    "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Source/CODEX_SOURCE_PROVENANCE.txt",
)


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def root_file_findings(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for rel in ROOT_REQUIRED_FILES:
        path = root / rel
        if not path.is_file():
            findings.append(Finding(
                path=rel,
                rule_id="missing-root-license-notice-file",
                message=f"publishable source tree must include root {rel}",
            ))
            continue
        text = read_text(path)
        if text is None or not text.strip():
            findings.append(Finding(
                path=rel,
                rule_id="empty-root-license-notice-file",
                message=f"root {rel} must not be empty",
            ))
    return findings


def notice_findings(root: Path) -> list[Finding]:
    notice_path = root / "NOTICE"
    text = read_text(notice_path)
    if text is None:
        return []
    normalized = text.lower()
    findings: list[Finding] = []
    for requirement in NOTICE_REQUIREMENTS:
        missing = [
            term
            for term in requirement.terms
            if term.lower() not in normalized
        ]
        if missing:
            findings.append(Finding(
                path="NOTICE",
                rule_id=requirement.requirement_id,
                message=f"{requirement.message}; missing terms: {', '.join(missing)}",
            ))
    return findings


def evidence_findings(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for rel in REQUIRED_EVIDENCE_FILES:
        path = root / rel
        if not path.is_file():
            findings.append(Finding(
                path=rel,
                rule_id="missing-third-party-license-evidence",
                message="publishable source tree must include third-party license/provenance evidence",
            ))
    return findings


def build_report(root: Path) -> dict[str, object]:
    findings = root_file_findings(root) + notice_findings(root) + evidence_findings(root)
    failures = [
        f"{finding.path}: {finding.message}"
        for finding in findings
    ]
    return {
        "passed": not findings,
        "gate": GATE_NAME,
        "root": str(root),
        "required_root_files": list(ROOT_REQUIRED_FILES),
        "required_notice_requirements": [
            {
                "requirement_id": item.requirement_id,
                "terms": list(item.terms),
                "message": item.message,
            }
            for item in NOTICE_REQUIREMENTS
        ],
        "required_evidence_files": list(REQUIRED_EVIDENCE_FILES),
        "finding_count": len(findings),
        "findings": [
            {
                "path": finding.path,
                "rule_id": finding.rule_id,
                "message": finding.message,
            }
            for finding in findings
        ],
        "failures": failures,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="repository root to scan")
    parser.add_argument("--report", required=True, help="JSON report path")
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
        print("MSP open-source license/notice gate passed")
        print(f"report={report_path}")
        return 0
    print("MSP open-source license/notice gate failed", file=sys.stderr)
    print(f"report={report_path}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
