#!/usr/bin/env python3
"""Check PhotoSorter's default public package boundary."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


GATE_NAME = "photosorter-default-package-boundary"
SCHEMA_VERSION = 1
PHOTOSORTER_ROOT = "Examples/iOS/PhotoSorter"

LOCAL_ONLY_PATHS = (
    f"{PHOTOSORTER_ROOT}/Project/PhotoSorter.local.xcodeproj",
    f"{PHOTOSORTER_ROOT}/Local/FastVLM",
    f"{PHOTOSORTER_ROOT}/Resources/FastVLM/model",
    f"{PHOTOSORTER_ROOT}/Vendor/mlx-swift",
    f"{PHOTOSORTER_ROOT}/Vendor/mlx-swift-examples",
)

PACKAGE_GUARD_FRAGMENTS = (
    'ProcessInfo.processInfo.environment["PHOTOSORTER_ENABLE_LOCAL_FASTVLM"] == "1"',
    'FileManager.default.fileExists(atPath: localFastVLMSourceURL.path)',
    'let localFastVLMSourcePath = "Local/FastVLM"',
    '.appendingPathComponent("FastVLM.swift")',
)


@dataclass(frozen=True)
class PackageMarker:
    marker_id: str
    line_pattern: re.Pattern[str]
    required_fragment: str | None = None


OPTIONAL_PACKAGE_MARKERS = (
    PackageMarker(
        "mlx-swift-package",
        re.compile(r'\.package\(url:\s*"https://github\.com/ml-explore/mlx-swift"'),
        'exact: "0.21.2"',
    ),
    PackageMarker(
        "mlx-swift-examples-package",
        re.compile(r'\.package\(url:\s*"https://github\.com/ml-explore/mlx-swift-examples"'),
        'exact: "2.21.2"',
    ),
    PackageMarker(
        "swift-transformers-package",
        re.compile(r'\.package\(url:\s*"https://github\.com/huggingface/swift-transformers"'),
        'exact: "0.1.18"',
    ),
    PackageMarker("mlx-product", re.compile(r'\.product\(name:\s*"MLX"')),
    PackageMarker("mlxnn-product", re.compile(r'\.product\(name:\s*"MLXNN"')),
    PackageMarker("mlxfast-product", re.compile(r'\.product\(name:\s*"MLXFast"')),
    PackageMarker("mlx-lm-common-product", re.compile(r'\.product\(name:\s*"MLXLMCommon"')),
    PackageMarker("mlx-vlm-product", re.compile(r'\.product\(name:\s*"MLXVLM"')),
    PackageMarker("transformers-product", re.compile(r'\.product\(name:\s*"Transformers"')),
    PackageMarker("local-fastvlm-sources", re.compile(r"\[localFastVLMSourcePath\]")),
    PackageMarker("local-fastvlm-resources", re.compile(r'\.copy\("Resources/FastVLM"\)')),
)

DEFAULT_XCODE_FORBIDDEN_PATTERNS = (
    ("default-xcode-remote-mlx-package", re.compile(r"XCRemoteSwiftPackageReference .*mlx-swift")),
    ("default-xcode-remote-mlx-package", re.compile(r"https://github\.com/ml-explore/mlx-swift")),
    ("default-xcode-remote-mlx-examples-package", re.compile(r"XCRemoteSwiftPackageReference .*mlx-swift-examples")),
    ("default-xcode-remote-mlx-examples-package", re.compile(r"https://github\.com/ml-explore/mlx-swift-examples")),
    ("default-xcode-remote-transformers-package", re.compile(r"XCRemoteSwiftPackageReference .*swift-transformers")),
    ("default-xcode-remote-transformers-package", re.compile(r"https://github\.com/huggingface/swift-transformers")),
    ("default-xcode-mlx-product", re.compile(r"productName = MLX;")),
    ("default-xcode-mlxnn-product", re.compile(r"productName = MLXNN;")),
    ("default-xcode-mlxfast-product", re.compile(r"productName = MLXFast;")),
    ("default-xcode-mlx-lm-common-product", re.compile(r"productName = MLXLMCommon;")),
    ("default-xcode-mlx-vlm-product", re.compile(r"productName = MLXVLM;")),
    ("default-xcode-transformers-product", re.compile(r"productName = Transformers;")),
    ("default-xcode-local-fastvlm-source", re.compile(r"FastVLM\.swift in Sources")),
    ("default-xcode-local-fastvlm-path", re.compile(r"Local/FastVLM")),
    ("default-xcode-fastvlm-model-resource", re.compile(r"FastVLM in Resources")),
)

PACKAGE_RESOLVED_BLOCKED_MARKERS = (
    "mlx-swift",
    "mlx-swift-examples",
    "swift-transformers",
    "https://github.com/ml-explore/mlx-swift",
    "https://github.com/ml-explore/mlx-swift-examples",
    "https://github.com/huggingface/swift-transformers",
)

DOC_REQUIREMENTS = {
    f"{PHOTOSORTER_ROOT}/README.md": (
        "default open-source package",
        "PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1",
        "Local/FastVLM/",
        "Resources/FastVLM/model/",
        "Project/PhotoSorter.local.xcodeproj",
    ),
    f"{PHOTOSORTER_ROOT}/Vendor/README.md": (
        "mlx-swift",
        "0.21.2",
        "mlx-swift-examples",
        "2.21.2",
        "swift-transformers",
        "0.1.18",
        "default open-source package and Xcode project do not include MLX package",
    ),
    f"{PHOTOSORTER_ROOT}/Local/README.md": (
        "Local/FastVLM/",
        "PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1",
    ),
    f"{PHOTOSORTER_ROOT}/Resources/FastVLM/README.md": (
        "Resources/FastVLM/model/",
        "Local/FastVLM/",
        "PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1",
    ),
    f"{PHOTOSORTER_ROOT}/Tools/check-local-packages.sh": (
        "PHOTOSORTER_ENABLE_LOCAL_FASTVLM",
        "Vendor/mlx-swift",
        "Vendor/mlx-swift-examples",
        "swift-transformers",
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify that PhotoSorter's default public package/Xcode surface "
            "does not require local FastVLM sources, model weights, or MLX packages."
        )
    )
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--report", help="JSON report path")
    return parser.parse_args()


def add_finding(
    findings: list[dict[str, str]],
    *,
    rule_id: str,
    path: str,
    message: str,
) -> None:
    findings.append({
        "rule_id": rule_id,
        "path": path,
        "message": message,
    })


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def gated_package_lines(lines: list[str]) -> set[int]:
    line_numbers: set[int] = set()
    inside_true_branch = False
    for index, line in enumerate(lines, start=1):
        if "includeLocalFastVLM ? [" in line:
            inside_true_branch = True
        if inside_true_branch:
            line_numbers.add(index)
        if inside_true_branch and re.search(r"\]\s*:\s*\[?\]?", line):
            inside_true_branch = False
    return line_numbers


def git_output(root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def is_git_worktree(root: Path) -> bool:
    result = git_output(root, ["rev-parse", "--is-inside-work-tree"])
    return result.returncode == 0 and result.stdout.strip() == "true"


def has_tracked_path(root: Path, rel: str) -> bool:
    result = git_output(root, ["ls-files", "--", rel])
    return result.returncode == 0 and bool(result.stdout.strip())


def is_git_ignored_path(root: Path, rel: str, path: Path) -> bool:
    candidates = [rel]
    if path.is_dir() and not rel.endswith("/"):
        candidates.insert(0, f"{rel}/")
    for candidate in candidates:
        if git_output(root, ["check-ignore", "-q", "--", candidate]).returncode == 0:
            return True
    return False


def is_publishable_local_only_path(root: Path, rel: str, path: Path) -> bool:
    if not is_git_worktree(root):
        return True
    if has_tracked_path(root, rel):
        return True
    return not is_git_ignored_path(root, rel, path)


def check_local_only_paths(root: Path, findings: list[dict[str, str]]) -> int:
    checked = 0
    for rel in LOCAL_ONLY_PATHS:
        checked += 1
        path = root / rel
        if (path.exists() or path.is_symlink()) and is_publishable_local_only_path(root, rel, path):
            add_finding(
                findings,
                rule_id="publishable-local-fastvlm-artifact",
                path=rel,
                message="local FastVLM/MLX development artifact must not be present in the default release tree",
            )
    return checked


def check_package_manifest(root: Path, findings: list[dict[str, str]]) -> int:
    rel = f"{PHOTOSORTER_ROOT}/Package.swift"
    text = read_text(root / rel)
    if text is None:
        add_finding(
            findings,
            rule_id="missing-photosorter-package-manifest",
            path=rel,
            message="PhotoSorter Package.swift is required for default package boundary checks",
        )
        return 0

    checked = 0
    for fragment in PACKAGE_GUARD_FRAGMENTS:
        checked += 1
        if fragment not in text:
            add_finding(
                findings,
                rule_id="missing-local-fastvlm-env-gate",
                path=rel,
                message=f"Package.swift is missing required local FastVLM guard fragment: {fragment}",
            )

    lines = text.splitlines()
    gated_lines = gated_package_lines(lines)
    for marker in OPTIONAL_PACKAGE_MARKERS:
        matches = [
            (index, line)
            for index, line in enumerate(lines, start=1)
            if marker.line_pattern.search(line)
        ]
        if not matches:
            add_finding(
                findings,
                rule_id="missing-optional-fastvlm-package-marker",
                path=rel,
                message=f"Package.swift is missing expected optional local FastVLM marker: {marker.marker_id}",
            )
            continue
        for index, line in matches:
            checked += 1
            if index not in gated_lines:
                add_finding(
                    findings,
                    rule_id="ungated-local-fastvlm-package-marker",
                    path=f"{rel}:{index}",
                    message=f"optional local FastVLM marker is not inside the includeLocalFastVLM true branch: {marker.marker_id}",
                )
            if marker.required_fragment is not None and marker.required_fragment not in line:
                add_finding(
                    findings,
                    rule_id="wrong-optional-fastvlm-version",
                    path=f"{rel}:{index}",
                    message=(
                        f"{marker.marker_id} must use {marker.required_fragment} "
                        "to keep docs and release evidence aligned"
                    ),
                )
    return checked


def check_package_resolved(root: Path, findings: list[dict[str, str]]) -> int:
    rel = f"{PHOTOSORTER_ROOT}/Package.resolved"
    path = root / rel
    text = read_text(path)
    if text is None:
        return 0

    checked = 1
    for marker in PACKAGE_RESOLVED_BLOCKED_MARKERS:
        if marker in text:
            add_finding(
                findings,
                rule_id="default-package-resolved-contains-optional-fastvlm-pin",
                path=rel,
                message=f"default Package.resolved must not pin optional local FastVLM dependency: {marker}",
            )
    return checked


def check_default_xcode_project(root: Path, findings: list[dict[str, str]]) -> int:
    rel = f"{PHOTOSORTER_ROOT}/Project/PhotoSorter.xcodeproj/project.pbxproj"
    text = read_text(root / rel)
    if text is None:
        add_finding(
            findings,
            rule_id="missing-photosorter-default-xcode-project",
            path=rel,
            message="default PhotoSorter Xcode project is required for public package boundary checks",
        )
        return 0

    checked = 0
    for rule_id, pattern in DEFAULT_XCODE_FORBIDDEN_PATTERNS:
        for match in pattern.finditer(text):
            checked += 1
            line = text.count("\n", 0, match.start()) + 1
            add_finding(
                findings,
                rule_id=rule_id,
                path=f"{rel}:{line}",
                message="default PhotoSorter Xcode project must not reference optional local FastVLM/MLX build inputs",
            )
    if checked == 0:
        checked = len(DEFAULT_XCODE_FORBIDDEN_PATTERNS)
    return checked


def check_docs(root: Path, findings: list[dict[str, str]]) -> int:
    checked = 0
    for rel, fragments in DOC_REQUIREMENTS.items():
        text = read_text(root / rel)
        if text is None:
            add_finding(
                findings,
                rule_id="missing-photosorter-local-fastvlm-boundary-doc",
                path=rel,
                message="PhotoSorter local FastVLM boundary documentation is missing",
            )
            continue
        checked += 1
        for fragment in fragments:
            if fragment not in text:
                add_finding(
                    findings,
                    rule_id="incomplete-photosorter-local-fastvlm-boundary-doc",
                    path=rel,
                    message=f"local FastVLM boundary documentation is missing required fragment: {fragment}",
                )
    return checked


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    args = parse_args()
    root = Path(args.root).expanduser().resolve()
    findings: list[dict[str, str]] = []

    checked_local_only_path_count = check_local_only_paths(root, findings)
    checked_package_manifest_item_count = check_package_manifest(root, findings)
    checked_package_resolved_count = check_package_resolved(root, findings)
    checked_default_xcode_project_item_count = check_default_xcode_project(root, findings)
    checked_doc_count = check_docs(root, findings)

    report = {
        "schema_version": SCHEMA_VERSION,
        "passed": not findings,
        "gate": GATE_NAME,
        "root": str(root),
        "photosorter_root": PHOTOSORTER_ROOT,
        "local_only_paths": list(LOCAL_ONLY_PATHS),
        "optional_dependency_versions": {
            "mlx-swift": "0.21.2",
            "mlx-swift-examples": "2.21.2",
            "swift-transformers": "0.1.18",
        },
        "checked_local_only_path_count": checked_local_only_path_count,
        "checked_package_manifest_item_count": checked_package_manifest_item_count,
        "checked_package_resolved_count": checked_package_resolved_count,
        "checked_default_xcode_project_item_count": checked_default_xcode_project_item_count,
        "checked_doc_count": checked_doc_count,
        "finding_count": len(findings),
        "findings": findings,
    }

    report_path = Path(args.report).expanduser().resolve() if args.report else None
    if report_path is not None:
        write_report(report_path, report)

    if report["passed"]:
        print("PhotoSorter default package boundary passed")
        if report_path is not None:
            print(f"report={report_path}")
        return 0

    print("PhotoSorter default package boundary failed", file=sys.stderr)
    if report_path is not None:
        print(f"report={report_path}", file=sys.stderr)
    for finding in findings:
        print(
            f"- {finding['rule_id']}: {finding['path']}: {finding['message']}",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
