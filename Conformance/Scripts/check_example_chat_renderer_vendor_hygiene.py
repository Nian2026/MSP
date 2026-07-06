#!/usr/bin/env python3
"""Check the public example transcript renderer vendor surface."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


GATE_NAME = "example-chat-renderer-vendor-hygiene"
SCHEMA_VERSION = 1
SHARED_RENDERER_ROOT = "Examples/iOS/Shared/ExampleChatTranscriptRenderer"
EXAMPLE_VENDOR_ROOTS = {
    "MSPPlaygroundApp": "Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer",
    "PhotoSorter": "Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer",
}

MANIFEST_REQUIREMENTS = {
    f"{SHARED_RENDERER_ROOT}/VENDOR_MANIFEST.md": [
        "byte-for-byte shared",
        "Third-party markdown, math, highlighting, document, paged, and knowledge-map",
        "chat-unified-markdown-THIRD-PARTY.json",
        "MathJax",
        "remark",
        "micromark",
        "legacy-spinner.apng",
    ],
    "Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/VENDOR_MANIFEST.md": [
        "MSPPlaygroundApp example",
        "intentionally limited to",
        "chat-unified-markdown-THIRD-PARTY.json",
        "legacy-spinner.apng",
        "old request construction",
        "Non-renderer source archives and local machine paths",
    ],
    "Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/VENDOR_MANIFEST.md": [
        "PhotoSorter",
        "intentionally limited to",
        "chat-unified-markdown-THIRD-PARTY.json",
        "legacy-spinner.apng",
        "old request construction",
        "Non-renderer source archives and local machine paths",
    ],
}

LOCAL_PATH_MARKERS = (
    b"/Users/",
    b"/Volumes/",
    b"/private/var/folders/",
    b"/var/folders/",
)
BLOCKED_PATH_MARKERS = (
    "/SourceArchive/",
    "/.build/",
    "/.swiftpm/",
    "/DerivedData/",
    "/__pycache__/",
)
BLOCKED_ARCHIVE_SUFFIXES = (
    ".dSYM",
    ".map",
    ".orig",
    ".tar",
    ".tar.gz",
    ".tgz",
    ".xcarchive",
    ".zip",
)
UNIFIED_MARKDOWN_BUNDLE = "RuntimeResources/Math/chat-unified-markdown.js"
UNIFIED_MARKDOWN_THIRD_PARTY_MANIFEST = (
    "RuntimeResources/Math/chat-unified-markdown-THIRD-PARTY.json"
)
UNIFIED_MARKDOWN_PACKAGE_RE = re.compile(
    r"node_modules/((?:@[^/\n\"']+/[^/\n\"']+)|[^/\n\"']+)"
)
ALLOWED_UNIFIED_MARKDOWN_LICENSES = {
    "Apache-2.0",
    "BSD-2-Clause",
    "ISC",
    "MIT",
}
PROJECT_ASSET_EVIDENCE = {
    "RuntimeResources/Math/PROJECT-ASSET-PROVENANCE.md": (
        "legacy-spinner.apng",
        "project-local UI asset",
        "shared ExampleChatTranscriptRenderer",
    ),
}


@dataclass(frozen=True)
class AssetGroup:
    group_id: str
    assets: tuple[str, ...]
    licenses: tuple[str, ...]


@dataclass(frozen=True)
class LicenseEvidence:
    path: str
    required_fragments: tuple[str, ...]


REQUIRED_ASSET_GROUPS = [
    AssetGroup(
        group_id="katex",
        assets=(
            "RuntimeResources/Math/katex.min.js",
            "RuntimeResources/Math/katex.min.css",
            "RuntimeResources/Math/mhchem.min.js",
            "RuntimeResources/Math/copy-tex.min.js",
        ),
        licenses=("RuntimeResources/Math/katex-LICENSE.txt",),
    ),
    AssetGroup(
        group_id="highlightjs",
        assets=(
            "RuntimeResources/Math/highlight.min.js",
            "RuntimeResources/Math/highlight-github.min.css",
            "RuntimeResources/Math/highlight-github-dark.min.css",
        ),
        licenses=("RuntimeResources/Math/highlightjs-LICENSE.txt",),
    ),
    AssetGroup(
        group_id="prettier",
        assets=(
            "RuntimeResources/Math/prettier-standalone.js",
            "RuntimeResources/Math/prettier-parser-babel.js",
            "RuntimeResources/Math/prettier-parser-html.js",
            "RuntimeResources/Math/prettier-parser-postcss.js",
            "RuntimeResources/Math/prettier-parser-typescript.js",
        ),
        licenses=("RuntimeResources/Math/prettier-LICENSE.txt",),
    ),
    AssetGroup(
        group_id="d3",
        assets=("RuntimeResources/KnowledgeMap/d3.min.js",),
        licenses=("RuntimeResources/KnowledgeMap/d3-LICENSE.txt",),
    ),
    AssetGroup(
        group_id="markmap-view",
        assets=("RuntimeResources/KnowledgeMap/markmap-view.js",),
        licenses=("RuntimeResources/KnowledgeMap/markmap-view-LICENSE.txt",),
    ),
    AssetGroup(
        group_id="pagedjs",
        assets=("RuntimeResources/Paged/paged.polyfill.js",),
        licenses=("RuntimeResources/Paged/pagedjs-LICENSE.md",),
    ),
    AssetGroup(
        group_id="unified-markdown",
        assets=(UNIFIED_MARKDOWN_BUNDLE,),
        licenses=(UNIFIED_MARKDOWN_THIRD_PARTY_MANIFEST,),
    ),
    AssetGroup(
        group_id="legacy-spinner",
        assets=("RuntimeResources/Math/legacy-spinner.apng",),
        licenses=(),
    ),
]

LICENSE_EVIDENCE = [
    LicenseEvidence(
        path="RuntimeResources/Math/katex-LICENSE.txt",
        required_fragments=(
            "The MIT License (MIT)",
            "Khan Academy and other contributors",
            "Permission is hereby granted",
        ),
    ),
    LicenseEvidence(
        path="RuntimeResources/Math/highlightjs-LICENSE.txt",
        required_fragments=(
            "BSD 3-Clause License",
            "Ivan Sagalaev",
            "Redistribution and use",
        ),
    ),
    LicenseEvidence(
        path="RuntimeResources/Math/prettier-LICENSE.txt",
        required_fragments=(
            "Prettier license",
            "James Long and contributors",
            "Permission is hereby granted",
        ),
    ),
    LicenseEvidence(
        path="RuntimeResources/KnowledgeMap/d3-LICENSE.txt",
        required_fragments=(
            "Mike Bostock",
            "Permission to use, copy, modify",
            "THE SOFTWARE IS PROVIDED",
        ),
    ),
    LicenseEvidence(
        path="RuntimeResources/KnowledgeMap/markmap-view-LICENSE.txt",
        required_fragments=(
            "MIT License",
            "Copyright (c) 2020 Gerald",
            "Permission is hereby granted",
        ),
    ),
    LicenseEvidence(
        path="RuntimeResources/Paged/pagedjs-LICENSE.md",
        required_fragments=(
            "The MIT License (MIT)",
            "Copyright (c) 2018 Adam Hyde",
            "Permission is hereby granted",
        ),
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify the vendored ExampleChatTranscriptRenderer surface used by "
            "the public iOS examples."
        )
    )
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--report", help="JSON report path")
    return parser.parse_args()


def is_relative_to(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


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


def read_bytes(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except OSError:
        return None


def read_json(path: Path) -> Any | None:
    text = read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def required_group_entries() -> list[str]:
    entries: set[str] = set()
    for group in REQUIRED_ASSET_GROUPS:
        entries.update(group.assets)
        entries.update(group.licenses)
    return sorted(entries)


def check_manifests(root: Path, findings: list[dict[str, str]]) -> int:
    checked = 0
    for rel, fragments in MANIFEST_REQUIREMENTS.items():
        path = root / rel
        text = read_text(path)
        if text is None:
            add_finding(
                findings,
                rule_id="missing-vendor-manifest",
                path=rel,
                message="required renderer vendor manifest is missing",
            )
            continue
        checked += 1
        for fragment in fragments:
            if fragment not in text:
                add_finding(
                    findings,
                    rule_id="incomplete-vendor-manifest",
                    path=rel,
                    message=f"manifest is missing required boundary text: {fragment}",
                )
    return checked


def check_shared_assets(root: Path, findings: list[dict[str, str]]) -> int:
    shared_root = root / SHARED_RENDERER_ROOT
    checked = 0
    for rel in required_group_entries():
        path = shared_root / rel
        if not path.is_file():
            add_finding(
                findings,
                rule_id="missing-shared-renderer-vendor-asset",
                path=f"{SHARED_RENDERER_ROOT}/{rel}",
                message="required shared renderer vendor asset or license is missing",
            )
            continue
        checked += 1
    return checked


def check_license_evidence(root: Path, findings: list[dict[str, str]]) -> int:
    checked = 0
    shared_root = root / SHARED_RENDERER_ROOT
    for evidence in LICENSE_EVIDENCE:
        rel = f"{SHARED_RENDERER_ROOT}/{evidence.path}"
        text = read_text(shared_root / evidence.path)
        if text is None:
            add_finding(
                findings,
                rule_id="missing-third-party-license-evidence",
                path=rel,
                message="required third-party license evidence is missing",
            )
            continue
        checked += 1
        for fragment in evidence.required_fragments:
            if fragment not in text:
                add_finding(
                    findings,
                    rule_id="incomplete-third-party-license-evidence",
                    path=rel,
                    message=f"license evidence is missing required fragment: {fragment}",
                )
    return checked


def check_unified_markdown_manifest(
    root: Path,
    findings: list[dict[str, str]],
) -> dict[str, Any]:
    shared_root = root / SHARED_RENDERER_ROOT
    bundle_path = shared_root / UNIFIED_MARKDOWN_BUNDLE
    manifest_path = shared_root / UNIFIED_MARKDOWN_THIRD_PARTY_MANIFEST
    bundle_rel = f"{SHARED_RENDERER_ROOT}/{UNIFIED_MARKDOWN_BUNDLE}"
    manifest_rel = f"{SHARED_RENDERER_ROOT}/{UNIFIED_MARKDOWN_THIRD_PARTY_MANIFEST}"
    bundle_text = read_text(bundle_path)
    if bundle_text is None:
        add_finding(
            findings,
            rule_id="missing-unified-markdown-bundle",
            path=bundle_rel,
            message="chat unified markdown bundle is required for package provenance verification",
        )
        return {
            "actual_package_count": 0,
            "manifest_package_count": None,
            "license_ids": [],
        }

    actual_package_names = sorted(set(UNIFIED_MARKDOWN_PACKAGE_RE.findall(bundle_text)))
    manifest = read_json(manifest_path)
    if not isinstance(manifest, dict):
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-manifest",
            path=manifest_rel,
            message="chat unified markdown third-party manifest must be a JSON object",
        )
        return {
            "actual_package_count": len(actual_package_names),
            "manifest_package_count": None,
            "license_ids": [],
        }

    if manifest.get("schema_version") != 1:
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-manifest-schema",
            path=manifest_rel,
            message="chat unified markdown third-party manifest schema_version must be 1",
        )
    if manifest.get("asset") != UNIFIED_MARKDOWN_BUNDLE:
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-manifest-asset",
            path=manifest_rel,
            message=f"chat unified markdown third-party manifest must name asset {UNIFIED_MARKDOWN_BUNDLE}",
        )

    packages = manifest.get("packages")
    if not isinstance(packages, list):
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-package-list",
            path=manifest_rel,
            message="chat unified markdown third-party manifest packages must be a list",
        )
        packages = []

    manifest_package_names: list[str] = []
    package_license_ids: set[str] = set()
    for index, package in enumerate(packages):
        package_path = f"{manifest_rel}#/packages/{index}"
        if not isinstance(package, dict):
            add_finding(
                findings,
                rule_id="invalid-unified-markdown-third-party-package",
                path=package_path,
                message="chat unified markdown package entry must be an object",
            )
            continue
        name = package.get("name")
        version = package.get("version")
        license_id = package.get("license")
        if not isinstance(name, str) or not name:
            add_finding(
                findings,
                rule_id="invalid-unified-markdown-third-party-package-name",
                path=package_path,
                message="chat unified markdown package entry must include a non-empty name",
            )
            continue
        manifest_package_names.append(name)
        if not isinstance(version, str) or not version:
            add_finding(
                findings,
                rule_id="invalid-unified-markdown-third-party-package-version",
                path=package_path,
                message=f"chat unified markdown package {name} must include a non-empty version",
            )
        if not isinstance(license_id, str) or not license_id:
            add_finding(
                findings,
                rule_id="invalid-unified-markdown-third-party-package-license",
                path=package_path,
                message=f"chat unified markdown package {name} must include a non-empty SPDX license id",
            )
            continue
        package_license_ids.add(license_id)
        if license_id not in ALLOWED_UNIFIED_MARKDOWN_LICENSES:
            add_finding(
                findings,
                rule_id="unsupported-unified-markdown-third-party-license",
                path=package_path,
                message=f"chat unified markdown package {name} has unsupported license id: {license_id}",
            )

    duplicate_names = sorted({
        name for name in manifest_package_names if manifest_package_names.count(name) > 1
    })
    for name in duplicate_names:
        add_finding(
            findings,
            rule_id="duplicate-unified-markdown-third-party-package",
            path=manifest_rel,
            message=f"chat unified markdown third-party manifest repeats package: {name}",
        )

    manifest_package_set = set(manifest_package_names)
    actual_package_set = set(actual_package_names)
    missing_packages = sorted(actual_package_set - manifest_package_set)
    extra_packages = sorted(manifest_package_set - actual_package_set)
    for name in missing_packages:
        add_finding(
            findings,
            rule_id="missing-unified-markdown-third-party-package",
            path=manifest_rel,
            message=f"chat unified markdown third-party manifest is missing package from bundle: {name}",
        )
    for name in extra_packages:
        add_finding(
            findings,
            rule_id="stale-unified-markdown-third-party-package",
            path=manifest_rel,
            message=f"chat unified markdown third-party manifest names package not found in bundle: {name}",
        )

    declared_count = manifest.get("package_count")
    if declared_count != len(actual_package_names):
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-package-count",
            path=manifest_rel,
            message=(
                "chat unified markdown third-party manifest package_count "
                f"must be {len(actual_package_names)}"
            ),
        )

    declared_licenses = manifest.get("licenses")
    if not isinstance(declared_licenses, list) or any(
        not isinstance(item, str) for item in declared_licenses
    ):
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-license-list",
            path=manifest_rel,
            message="chat unified markdown third-party manifest licenses must be a string list",
        )
    elif set(declared_licenses) != package_license_ids:
        add_finding(
            findings,
            rule_id="invalid-unified-markdown-third-party-license-summary",
            path=manifest_rel,
            message="chat unified markdown third-party manifest licenses must match package license ids",
        )

    return {
        "actual_package_count": len(actual_package_names),
        "manifest_package_count": len(manifest_package_names),
        "license_ids": sorted(package_license_ids),
    }


def check_project_asset_evidence(root: Path, findings: list[dict[str, str]]) -> int:
    shared_root = root / SHARED_RENDERER_ROOT
    checked = 0
    for evidence_path, fragments in PROJECT_ASSET_EVIDENCE.items():
        rel = f"{SHARED_RENDERER_ROOT}/{evidence_path}"
        text = read_text(shared_root / evidence_path)
        if text is None:
            add_finding(
                findings,
                rule_id="missing-project-asset-provenance",
                path=rel,
                message="project-local renderer asset provenance evidence is missing",
            )
            continue
        checked += 1
        for fragment in fragments:
            if fragment not in text:
                add_finding(
                    findings,
                    rule_id="incomplete-project-asset-provenance",
                    path=rel,
                    message=f"project-local renderer asset provenance is missing required fragment: {fragment}",
                )
    return checked


def check_vendor_exposes_shared_assets(root: Path, findings: list[dict[str, str]]) -> int:
    shared_root = (root / SHARED_RENDERER_ROOT).resolve()
    checked = 0
    for example, vendor_rel in EXAMPLE_VENDOR_ROOTS.items():
        vendor_root = root / vendor_rel
        for rel in required_group_entries():
            path = vendor_root / rel
            report_path = f"{vendor_rel}/{rel}"
            if not path.exists():
                add_finding(
                    findings,
                    rule_id="missing-example-renderer-vendor-asset",
                    path=report_path,
                    message=f"{example} vendor surface does not expose required shared asset",
                )
                continue
            checked += 1
            if not path.is_symlink():
                add_finding(
                    findings,
                    rule_id="example-renderer-vendor-asset-not-symlink",
                    path=report_path,
                    message="shared renderer vendor asset must be exposed through an example-local symlink",
                )
                continue
            resolved = path.resolve(strict=False)
            if not is_relative_to(resolved, shared_root):
                add_finding(
                    findings,
                    rule_id="example-renderer-vendor-asset-outside-shared-root",
                    path=report_path,
                    message="example vendor symlink does not resolve into the shared renderer root",
                )
    return checked


def check_symlink_boundaries(root: Path, findings: list[dict[str, str]]) -> int:
    checked = 0
    shared_root = (root / SHARED_RENDERER_ROOT).resolve()
    for example, vendor_rel in EXAMPLE_VENDOR_ROOTS.items():
        vendor_root = root / vendor_rel
        if not vendor_root.is_dir():
            add_finding(
                findings,
                rule_id="missing-example-renderer-vendor-root",
                path=vendor_rel,
                message=f"{example} renderer vendor root is missing",
            )
            continue
        for path in sorted(vendor_root.rglob("*")):
            if not path.is_symlink():
                continue
            checked += 1
            rel = path.relative_to(root).as_posix()
            target = os.readlink(path)
            if os.path.isabs(target):
                add_finding(
                    findings,
                    rule_id="absolute-example-renderer-vendor-symlink",
                    path=rel,
                    message=f"renderer vendor symlink target is absolute: {target}",
                )
                continue
            resolved = (path.parent / target).resolve(strict=False)
            if not resolved.exists():
                add_finding(
                    findings,
                    rule_id="broken-example-renderer-vendor-symlink",
                    path=rel,
                    message=f"renderer vendor symlink target does not exist: {target}",
                )
                continue
            if not is_relative_to(resolved, shared_root):
                add_finding(
                    findings,
                    rule_id="example-renderer-vendor-symlink-outside-shared-root",
                    path=rel,
                    message=f"renderer vendor symlink target is outside the shared renderer root: {target}",
                )

    shared_dir = root / SHARED_RENDERER_ROOT
    if shared_dir.is_dir():
        for path in sorted(shared_dir.rglob("*")):
            if not path.is_symlink():
                continue
            checked += 1
            rel = path.relative_to(root).as_posix()
            target = os.readlink(path)
            if os.path.isabs(target):
                add_finding(
                    findings,
                    rule_id="absolute-shared-renderer-symlink",
                    path=rel,
                    message=f"shared renderer symlink target is absolute: {target}",
                )
                continue
            resolved = (path.parent / target).resolve(strict=False)
            if not resolved.exists():
                add_finding(
                    findings,
                    rule_id="broken-shared-renderer-symlink",
                    path=rel,
                    message=f"shared renderer symlink target does not exist: {target}",
                )
                continue
            if not is_relative_to(resolved, shared_root):
                add_finding(
                    findings,
                    rule_id="shared-renderer-symlink-outside-shared-root",
                    path=rel,
                    message=f"shared renderer symlink target is outside the shared renderer root: {target}",
                )
    return checked


def check_katex_font_references(root: Path, findings: list[dict[str, str]]) -> int:
    css_rel = f"{SHARED_RENDERER_ROOT}/RuntimeResources/Math/katex.min.css"
    css_path = root / css_rel
    text = read_text(css_path)
    if text is None:
        add_finding(
            findings,
            rule_id="missing-katex-css",
            path=css_rel,
            message="KaTeX CSS is required to verify font references",
        )
        return 0

    references = sorted(set(re.findall(r"url\(([^)]+)\)", text)))
    font_references = [
        ref.strip("\"'")
        for ref in references
        if ref.strip("\"'").startswith("fonts/KaTeX_")
    ]
    if not font_references:
        add_finding(
            findings,
            rule_id="missing-katex-font-references",
            path=css_rel,
            message="KaTeX CSS must reference bundled KaTeX fonts",
        )
        return 0

    math_root = root / SHARED_RENDERER_ROOT / "RuntimeResources" / "Math"
    shared_root = (root / SHARED_RENDERER_ROOT).resolve()
    checked = 0
    for ref in font_references:
        checked += 1
        shared_font = math_root / ref
        if not shared_font.is_file():
            add_finding(
                findings,
                rule_id="missing-katex-font-file",
                path=f"{SHARED_RENDERER_ROOT}/RuntimeResources/Math/{ref}",
                message="KaTeX CSS references a missing bundled font",
            )
            continue
        for example, vendor_rel in EXAMPLE_VENDOR_ROOTS.items():
            vendor_font = root / vendor_rel / "RuntimeResources" / "Math" / ref
            report_path = f"{vendor_rel}/RuntimeResources/Math/{ref}"
            if not vendor_font.exists():
                add_finding(
                    findings,
                    rule_id="missing-example-katex-font-file",
                    path=report_path,
                    message=f"{example} vendor surface does not expose a KaTeX font referenced by CSS",
                )
                continue
            if not vendor_font.is_symlink():
                add_finding(
                    findings,
                    rule_id="example-katex-font-not-symlink",
                    path=report_path,
                    message="KaTeX font in example vendor surface must be a symlink into the shared renderer root",
                )
                continue
            if not is_relative_to(vendor_font.resolve(strict=False), shared_root):
                add_finding(
                    findings,
                    rule_id="example-katex-font-outside-shared-root",
                    path=report_path,
                    message="KaTeX font symlink does not resolve into the shared renderer root",
                )
    return checked


def check_private_artifacts(root: Path, findings: list[dict[str, str]]) -> int:
    checked = 0
    scan_roots = [SHARED_RENDERER_ROOT, *EXAMPLE_VENDOR_ROOTS.values()]
    seen_files: set[Path] = set()
    for scan_rel in scan_roots:
        scan_root = root / scan_rel
        if not scan_root.exists():
            continue
        for path in sorted(scan_root.rglob("*")):
            rel = path.relative_to(root).as_posix()
            normalized = f"/{rel}/"
            if any(marker in normalized for marker in BLOCKED_PATH_MARKERS):
                add_finding(
                    findings,
                    rule_id="private-renderer-vendor-path",
                    path=rel,
                    message="renderer vendor surface contains a private/build path marker",
                )
            if path.name.endswith(BLOCKED_ARCHIVE_SUFFIXES):
                add_finding(
                    findings,
                    rule_id="private-renderer-vendor-archive",
                    path=rel,
                    message="renderer vendor surface must not include source archives, maps, or local build bundles",
                )
            if not path.is_file():
                continue
            try:
                real_path = path.resolve()
            except OSError:
                real_path = path
            if real_path in seen_files:
                continue
            seen_files.add(real_path)
            checked += 1
            contents = read_bytes(path)
            if contents is None:
                continue
            for marker in LOCAL_PATH_MARKERS:
                if marker in contents:
                    add_finding(
                        findings,
                        rule_id="renderer-vendor-local-host-path",
                        path=rel,
                        message=f"renderer vendor file contains local host path marker: {marker.decode()}",
                    )
                    break
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

    checked_manifest_count = check_manifests(root, findings)
    checked_shared_asset_count = check_shared_assets(root, findings)
    checked_license_count = check_license_evidence(root, findings)
    checked_unified_markdown = check_unified_markdown_manifest(root, findings)
    checked_project_asset_evidence_count = check_project_asset_evidence(root, findings)
    checked_vendor_asset_count = check_vendor_exposes_shared_assets(root, findings)
    checked_symlink_count = check_symlink_boundaries(root, findings)
    checked_font_reference_count = check_katex_font_references(root, findings)
    checked_file_count = check_private_artifacts(root, findings)

    report = {
        "schema_version": SCHEMA_VERSION,
        "passed": not findings,
        "gate": GATE_NAME,
        "root": str(root),
        "shared_renderer_root": SHARED_RENDERER_ROOT,
        "example_vendor_roots": EXAMPLE_VENDOR_ROOTS,
        "required_asset_groups": [
            {
                "group_id": group.group_id,
                "assets": list(group.assets),
                "licenses": list(group.licenses),
            }
            for group in REQUIRED_ASSET_GROUPS
        ],
        "checked_manifest_count": checked_manifest_count,
        "checked_shared_asset_count": checked_shared_asset_count,
        "checked_license_count": checked_license_count,
        "checked_unified_markdown": checked_unified_markdown,
        "checked_project_asset_evidence_count": checked_project_asset_evidence_count,
        "checked_vendor_asset_count": checked_vendor_asset_count,
        "checked_symlink_count": checked_symlink_count,
        "checked_katex_font_reference_count": checked_font_reference_count,
        "checked_file_count": checked_file_count,
        "finding_count": len(findings),
        "findings": findings,
    }
    report_path = Path(args.report).expanduser().resolve() if args.report else None
    if report_path is not None:
        write_report(report_path, report)

    if report["passed"]:
        print("Example chat renderer vendor hygiene passed")
        if report_path is not None:
            print(f"report={report_path}")
        return 0

    print("Example chat renderer vendor hygiene failed", file=sys.stderr)
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
