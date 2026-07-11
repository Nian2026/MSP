#!/usr/bin/env python3
"""Check that the publishable MSP tree has no local/build/private artifacts."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


GATE_NAME = "msp-open-source-hygiene"
REQUIRED_RULE_IDS = [
    "macos-finder-metadata",
    "python-bytecode-cache",
    "swift-and-xcode-build-output",
    "private-construction-state",
    "root-runtime-artifacts",
    "example-backups-and-build-mcp",
    "bundled-js-output",
    "internal-validation-results",
    "internal-chat-spec-drafts",
    "internal-agentbridge-construction-notes",
    "local-linux-source-snapshot",
    "local-codex-source-snapshot",
    "local-readex-reference-snapshot",
    "first-party-local-host-paths",
    "codex-validation-local-host-paths",
    "codex-validation-local-evidence-references",
    "codex-validation-private-gate-narrative",
    "codex-validation-phase-results-public-surface",
    "codex-apply-patch-vendor-hygiene",
    "markstream-public-surface",
    "msp-chat-ui-markstream-vendor-hygiene",
    "local-internal-spec-reference-paths",
]

PRUNE_DIR_NAMES = {
    ".git",
    ".build",
    ".swiftpm",
    ".codex-tmp",
    "node_modules",
    "DerivedData",
}

ALLOWED_EXTENSIONLESS_ROOT_NAMES = {
    "CODEOWNERS",
    "CONTRIBUTING",
    "Conformance",
    "Docs",
    "Examples",
    "Implementations",
    "LICENSE",
    "Makefile",
    "NOTICE",
    "Package",
    "README",
    "References",
    "SECURITY",
    "Sources",
    "Spec",
    "Tests",
    "Tools",
}

LOCAL_LINUX_SOURCE_SNAPSHOT_ROOT = "References/LinuxSourceSnapshot/debian12-bookworm/sources"
LOCAL_CODEX_SOURCE_SNAPSHOT_ROOT = "Conformance/Chat/CodexCliValidation/source-snapshots"
LOCAL_CHAT_INTERNAL_SPEC_ROOT = "Spec/Chat/Internal"
LOCAL_AGENTBRIDGE_INTERNAL_SPEC_ROOT = "Spec/AgentBridge/Internal"
LOCAL_READEX_REFERENCE_SNAPSHOT_ROOTS = (
    "References/ReadexReadingAgentSnapshot",
    "References/ReadexShellSnapshot",
)
CODEX_VALIDATION_ROOT = "Conformance/Chat/CodexCliValidation"
CODEX_VALIDATION_LOCAL_HOST_PATH_RULE_ID = "codex-validation-local-host-paths"
CODEX_VALIDATION_LOCAL_HOST_PATH_MARKERS = (
    "/Users/",
    "/Volumes/",
    "/private/var/folders/",
    "/var/folders/",
)
CODEX_VALIDATION_LOCAL_EVIDENCE_REFERENCE_RULE_ID = (
    "codex-validation-local-evidence-references"
)
CODEX_VALIDATION_LOCAL_EVIDENCE_REFERENCE_MARKERS = (
    "Conformance/Chat/CodexCliValidation/reports/",
    "Conformance/Chat/CodexCliValidation/results/",
)
CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_RULE_ID = (
    "codex-validation-private-gate-narrative"
)
CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_ROOTS = (
    CODEX_VALIDATION_ROOT,
    "Spec/Chat",
)
CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_MARKERS = (
    "local .chat internal",
    "red-team notes",
    "red-team round",
    "source-mapping draft",
    "review synthesis",
    "private draft",
    "private notes",
    "required `.chat` drafts",
    "required .chat drafts",
)
CODEX_VALIDATION_PHASE_RESULTS_RULE_ID = (
    "codex-validation-phase-results-public-surface"
)
CODEX_VALIDATION_PHASE_RESULTS_ROOT = (
    f"{CODEX_VALIDATION_ROOT}/phase-results"
)
CODEX_VALIDATION_PUBLIC_EVIDENCE = (
    f"{CODEX_VALIDATION_ROOT}/PUBLIC_EVIDENCE.md"
)
CODEX_VALIDATION_PHASE_RESULT_REF_RE = re.compile(
    r"(?<![\w./-])(phase-results/[A-Za-z0-9._/\-]+\.(?:json|md))"
)
CODEX_VALIDATION_RAW_IDENTITY_MARKERS = (
    "installationId",
    '"serverName"',
    "userAgent",
    "remoteControl/status/changed",
    "Codex Desktop/",
)
FIRST_PARTY_LOCAL_HOST_PATH_RULE_ID = "first-party-local-host-paths"
FIRST_PARTY_LOCAL_HOST_PATH_MARKERS = (
    "/Users/example-private-user",
    "/Volumes/ExampleDrive/Projects/PrivateWorktree",
)
FIRST_PARTY_LOCAL_HOST_PATH_EXCLUDED_PATHS = {
    "Conformance/Scripts/check_open_source_hygiene.py",
    "Conformance/Scripts/check_open_source_example_boundary.py",
    "Conformance/Scripts/final_gate_verifier_support/readex_boundary.py",
    "Conformance/Scripts/msp_pressure_contract.py",
}
CODEX_APPLY_PATCH_VENDOR_ROOT = (
    "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch"
)
CODEX_APPLY_PATCH_VENDOR_RULE_ID = "codex-apply-patch-vendor-hygiene"
CODEX_APPLY_PATCH_PROVENANCE = (
    f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Source/CODEX_SOURCE_PROVENANCE.txt"
)
CODEX_APPLY_PATCH_ARTIFACT_ROOT = (
    f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Artifacts/MSPCodexApplyPatchBridge.xcframework"
)
CODEX_APPLY_PATCH_ARTIFACT_RECEIPT = (
    f"{CODEX_APPLY_PATCH_ARTIFACT_ROOT}/BUILD_RECEIPT.txt"
)
CODEX_APPLY_PATCH_REQUIRED_EVIDENCE = [
    f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Licenses/APACHE-2.0.txt",
    f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Licenses/CODEX-LICENSE-NOTE.md",
    f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Licenses/THIRD-PARTY-CARGO-LICENSES.json",
    CODEX_APPLY_PATCH_PROVENANCE,
]
CODEX_APPLY_PATCH_HOST_PATH_TEXT_MARKERS = (
    "/Volumes/",
    "/Users/",
)
CODEX_APPLY_PATCH_HOST_PATH_BINARY_MARKERS = (
    b"/Volumes/",
    b"/Users/",
    b"/private/var/folders/",
    b"/var/folders/",
)
CODEX_APPLY_PATCH_BINARY_SUFFIXES = (
    ".a",
    ".dylib",
    ".so",
)
CODEX_APPLY_PATCH_ARTIFACT_RECEIPT_FORMAT = (
    "msp-codex-apply-patch-artifact-receipt-v1"
)
CODEX_APPLY_PATCH_REQUIRED_ARTIFACT_FILES = {
    "Info.plist",
    "ios-arm64/Headers/module.modulemap",
    "ios-arm64/Headers/msp_codex_apply_patch_bridge.h",
    "ios-arm64/libmsp_codex_apply_patch_bridge.a",
    "ios-arm64-simulator/Headers/module.modulemap",
    "ios-arm64-simulator/Headers/msp_codex_apply_patch_bridge.h",
    "ios-arm64-simulator/libmsp_codex_apply_patch_bridge.a",
}
CODEX_APPLY_PATCH_PROVENANCE_SCOPE = "codex-apply-patch-runtime-surface"
CODEX_APPLY_PATCH_PROVENANCE_SOURCE_ROOT = (
    f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Source/codex-rs"
)
CODEX_APPLY_PATCH_PROVENANCE_EXACT_PATHS = {
    "core/src/tools/handlers/apply_patch_spec.rs",
    "core/src/tools/handlers/apply_patch.lark",
    "core/src/tools/runtimes/apply_patch.rs",
    "tools/src/responses_api.rs",
    "tools/src/tool_spec.rs",
}
CODEX_APPLY_PATCH_PROVENANCE_PREFIXES = (
    "apply-patch/",
    "utils/absolute-path/",
)
CODEX_APPLY_PATCH_REQUIRED_PROVENANCE_PATHS = {
    "apply-patch/src/invocation.rs",
    "apply-patch/src/lib.rs",
    "apply-patch/src/parser.rs",
    "apply-patch/src/seek_sequence.rs",
    "apply-patch/src/standalone_executable.rs",
    "apply-patch/src/streaming_parser.rs",
    "core/src/tools/handlers/apply_patch_spec.rs",
    "core/src/tools/handlers/apply_patch.lark",
    "core/src/tools/runtimes/apply_patch.rs",
    "tools/src/responses_api.rs",
    "tools/src/tool_spec.rs",
    "utils/absolute-path/src/absolutize.rs",
    "utils/absolute-path/src/lib.rs",
}
GIT_BLOB_SHA1_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
MARKSTREAM_PUBLIC_SURFACE_RULE_ID = "markstream-public-surface"
MARKSTREAM_PUBLIC_SURFACE_EXCLUDED_PATHS = {
    "Conformance/Scripts/check_open_source_hygiene.py",
    "Tests/Swift/Integration/ModelShellProxy/StandardFixtures/ModelShellProxyOpenSourceHygieneConformanceTests.swift",
}
MARKSTREAM_PUBLIC_SURFACE_MARKER = "markstream"
MSP_CHAT_UI_ROOT = "Implementations/UI/MSPChatUI"
MSP_CHAT_UI_MARKSTREAM_VENDOR_RULE_ID = "msp-chat-ui-markstream-vendor-hygiene"
MSP_CHAT_UI_MARKSTREAM_BUNDLE = (
    f"{MSP_CHAT_UI_ROOT}/Renderers/Default/runtime/assets/Math/readex-markstream-sdk.js"
)
MSP_CHAT_UI_MARKSTREAM_AUDIT = (
    f"{MSP_CHAT_UI_ROOT}/Conformance/fixtures/markstream-bundle-license-audit.json"
)
MSP_CHAT_UI_MARKSTREAM_RUNTIME_README = (
    f"{MSP_CHAT_UI_ROOT}/Renderers/Default/runtime/markstream/README.md"
)
MSP_CHAT_UI_MARKSTREAM_RUNTIME_ROOT = (
    f"{MSP_CHAT_UI_ROOT}/Renderers/Default/runtime/markstream"
)
MSP_CHAT_UI_VENDOR_MANIFEST = f"{MSP_CHAT_UI_ROOT}/Renderers/Default/VENDOR_MANIFEST.md"
MSP_CHAT_UI_THIRD_PARTY_NOTICES = f"{MSP_CHAT_UI_ROOT}/THIRD_PARTY_NOTICES.md"
MSP_CHAT_UI_PACKAGE_MANIFEST = f"{MSP_CHAT_UI_ROOT}/package.json"
MSP_CHAT_UI_MARKSTREAM_ALLOWED_PATHS = {
    MSP_CHAT_UI_MARKSTREAM_AUDIT,
    MSP_CHAT_UI_MARKSTREAM_BUNDLE,
    MSP_CHAT_UI_MARKSTREAM_RUNTIME_ROOT,
    MSP_CHAT_UI_MARKSTREAM_RUNTIME_README,
}
MSP_CHAT_UI_MARKSTREAM_APPROVED_LICENSES = {
    "MIT",
    "ISC",
    "(MPL-2.0 OR Apache-2.0)",
    "BSD-2-Clause",
    "BSD-3-Clause",
}
LOCAL_INTERNAL_SPEC_REFERENCE_RULE_ID = "local-internal-spec-reference-paths"
LOCAL_INTERNAL_SPEC_REFERENCE_MARKERS = (
    LOCAL_CHAT_INTERNAL_SPEC_ROOT,
    LOCAL_AGENTBRIDGE_INTERNAL_SPEC_ROOT,
)
LOCAL_INTERNAL_SPEC_REFERENCE_EXCLUDED_PATHS = {
    ".gitignore",
    "Conformance/Scripts/check_open_source_hygiene.py",
    "Tests/Swift/Integration/ModelShellProxy/StandardFixtures/ModelShellProxyOpenSourceHygieneConformanceTests.swift",
}


@dataclass(frozen=True)
class BlockedPath:
    path: str
    reason: str
    rule_id: str
    source: str


def relative_path(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root).as_posix()


def is_local_linux_source_snapshot(path: str) -> bool:
    normalized = path.rstrip("/")
    return (
        normalized == LOCAL_LINUX_SOURCE_SNAPSHOT_ROOT
        or normalized.startswith(f"{LOCAL_LINUX_SOURCE_SNAPSHOT_ROOT}/")
    )


def is_local_codex_source_snapshot(path: str) -> bool:
    normalized = path.rstrip("/")
    return (
        normalized == LOCAL_CODEX_SOURCE_SNAPSHOT_ROOT
        or normalized.startswith(f"{LOCAL_CODEX_SOURCE_SNAPSHOT_ROOT}/")
    )


def is_internal_chat_spec(path: str) -> bool:
    normalized = path.rstrip("/")
    return (
        normalized == LOCAL_CHAT_INTERNAL_SPEC_ROOT
        or normalized.startswith(f"{LOCAL_CHAT_INTERNAL_SPEC_ROOT}/")
    )


def is_internal_agentbridge_spec(path: str) -> bool:
    normalized = path.rstrip("/")
    return (
        normalized == LOCAL_AGENTBRIDGE_INTERNAL_SPEC_ROOT
        or normalized.startswith(f"{LOCAL_AGENTBRIDGE_INTERNAL_SPEC_ROOT}/")
    )


def is_local_readex_reference_snapshot(path: str) -> bool:
    normalized = path.rstrip("/")
    for root in LOCAL_READEX_REFERENCE_SNAPSHOT_ROOTS:
        if normalized == root or normalized == f"{root}/SNAPSHOT.md":
            return False
        if normalized.startswith(f"{root}/"):
            return True
    return False


def is_codex_validation_path(path: str) -> bool:
    normalized = path.rstrip("/")
    return normalized == CODEX_VALIDATION_ROOT or normalized.startswith(f"{CODEX_VALIDATION_ROOT}/")


def is_codex_validation_private_gate_narrative_path(path: str) -> bool:
    normalized = path.rstrip("/")
    return any(
        normalized == root or normalized.startswith(f"{root}/")
        for root in CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_ROOTS
    )


def is_first_party_local_host_path_scan_candidate(path: str) -> bool:
    normalized = path.rstrip("/")
    if normalized in FIRST_PARTY_LOCAL_HOST_PATH_EXCLUDED_PATHS:
        return False
    if normalized.startswith(f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Source/codex-rs/"):
        return False
    if (
        is_local_linux_source_snapshot(normalized)
        or is_local_codex_source_snapshot(normalized)
        or is_internal_chat_spec(normalized)
        or is_internal_agentbridge_spec(normalized)
        or is_local_readex_reference_snapshot(normalized)
    ):
        return False
    return hygiene_reason(normalized) is None


def is_markstream_public_surface_excluded(path: str) -> bool:
    normalized = path.rstrip("/")
    return (
        normalized in MARKSTREAM_PUBLIC_SURFACE_EXCLUDED_PATHS
        or normalized == MSP_CHAT_UI_ROOT
        or normalized.startswith(f"{MSP_CHAT_UI_ROOT}/")
        or is_local_readex_reference_snapshot(normalized)
    )


def is_markstream_public_surface_scan_candidate(path: str) -> bool:
    normalized = path.rstrip("/")
    if is_markstream_public_surface_excluded(normalized):
        return False
    return hygiene_reason(normalized) is None


def is_local_internal_spec_reference_scan_candidate(path: str) -> bool:
    normalized = path.rstrip("/")
    if normalized in LOCAL_INTERNAL_SPEC_REFERENCE_EXCLUDED_PATHS:
        return False
    if is_internal_chat_spec(normalized) or is_internal_agentbridge_spec(normalized):
        return False
    return hygiene_reason(normalized) is None


def git_publishable_paths(root: Path) -> list[str]:
    git_dir = root / ".git"
    if not git_dir.exists():
        return []
    cached_command = [
        "git",
        "-C",
        str(root),
        "ls-files",
        "-z",
        "--cached"
    ]
    cached = subprocess.run(cached_command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    paths = []
    for item in cached.stdout.split(b"\0"):
        if not item:
            continue
        path = item.decode("utf-8", errors="surrogateescape")
        paths.append(path)
    status_command = [
        "git",
        "-C",
        str(root),
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=normal",
    ]
    status = subprocess.run(status_command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for item in status.stdout.split(b"\0"):
        if not item:
            continue
        text = item.decode("utf-8", errors="surrogateescape")
        if text.startswith("?? "):
            paths.append(text[3:])
    return paths


def filesystem_hygiene_scan(root: Path) -> tuple[list[str], int]:
    blocked: list[str] = []
    scanned_count = 0
    has_git_metadata = (root / ".git").exists()
    for current_root, dirs, files in os.walk(root):
        current = Path(current_root)
        rel_current = current.relative_to(root).as_posix()
        kept_dirs: list[str] = []
        for name in dirs:
            if name in PRUNE_DIR_NAMES:
                continue
            scanned_count += 1
            rel = name if rel_current == "." else f"{rel_current}/{name}"
            if has_git_metadata and (
                is_local_linux_source_snapshot(rel)
                or is_local_codex_source_snapshot(rel)
                or is_internal_chat_spec(rel)
                or is_internal_agentbridge_spec(rel)
                or is_local_readex_reference_snapshot(rel)
            ):
                continue
            if hygiene_reason(rel) is not None:
                blocked.append(rel)
                continue
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            scanned_count += 1
            rel = name if rel_current == "." else f"{rel_current}/{name}"
            if hygiene_reason(rel) is not None:
                blocked.append(rel)
    return blocked, scanned_count


def hygiene_reason(path: str) -> tuple[str, str] | None:
    name = path.rsplit("/", 1)[-1]
    lower = path.lower()

    if is_local_linux_source_snapshot(path):
        return (
            "local-linux-source-snapshot",
            "local Linux source snapshots must stay out of the publishable Git surface",
        )
    if is_local_codex_source_snapshot(path):
        return (
            "local-codex-source-snapshot",
            "local Codex validation source snapshots must stay out of the publishable Git surface",
        )
    if is_internal_chat_spec(path):
        return (
            "internal-chat-spec-drafts",
            "internal chat construction material must stay out of the publishable Git surface",
        )
    if is_internal_agentbridge_spec(path):
        return (
            "internal-agentbridge-construction-notes",
            "internal AgentBridge construction notes and parity audit drafts must stay out of the publishable Git surface",
        )
    if is_local_readex_reference_snapshot(path):
        return (
            "local-readex-reference-snapshot",
            "local Readex reference snapshots must stay out of the publishable Git surface",
        )
    if path.startswith("References/LinuxSourceSnapshot/"):
        return None
    if (
        MARKSTREAM_PUBLIC_SURFACE_MARKER in lower
        and not is_markstream_public_surface_excluded(path)
    ):
        return (
            MARKSTREAM_PUBLIC_SURFACE_RULE_ID,
            "Markstream renderer SDK/profile surface must not appear in the publishable MSP tree",
        )

    if name == ".DS_Store":
        return ("macos-finder-metadata", "macOS Finder metadata must not be in the release tree")
    if name == "__pycache__" or name.endswith((".pyc", ".pyo")):
        return ("python-bytecode-cache", "Python bytecode/cache output must not be in the release tree")
    if path == ".codex-tmp" or path.startswith(".codex-tmp/"):
        return ("private-construction-state", "private Codex construction drafts must not be in the release tree")
    if path == ".build" or path.startswith(".build/"):
        return ("swift-and-xcode-build-output", "SwiftPM build output must not be in the release tree")
    if path == ".swiftpm" or path.startswith(".swiftpm/"):
        return ("swift-and-xcode-build-output", "SwiftPM workspace state must not be in the release tree")
    if path == "DerivedData" or path.startswith("DerivedData/") or "/DerivedData/" in path:
        return ("swift-and-xcode-build-output", "Xcode DerivedData must not be in the release tree")
    if name in {".gitignore", ".gitkeep"} and "/build/" in lower:
        return None
    if name == "build" or "/build/" in lower:
        return ("swift-and-xcode-build-output", "build output must not be in the release tree")
    if "xcuserdata" in lower or name.endswith(".xcuserstate"):
        return ("swift-and-xcode-build-output", "Xcode user state must not be in the release tree")
    if path == "artifacts" or path.startswith("artifacts/"):
        return ("root-runtime-artifacts", "root artifacts output must not be in the release tree")
    if fnmatch.fnmatch(name, "vfs-request-*.json") or fnmatch.fnmatch(name, "vfs-response-*.json"):
        return ("root-runtime-artifacts", "root VFS broker artifacts must not be in the release tree")
    if path.count("/") == 0 and fnmatch.fnmatch(name, "*-a.txt"):
        return ("root-runtime-artifacts", "one-off root text artifacts must not be in the release tree")
    if path.count("/") == 0 and "." not in name and name not in ALLOWED_EXTENSIONLESS_ROOT_NAMES:
        return ("root-runtime-artifacts", "unexpected extensionless root entry must be explicitly allowed before release")
    if ".backup-" in path or "/backup-" in path or path.startswith("Examples/iOS/PhotoSorter.backup-"):
        return ("example-backups-and-build-mcp", "example backup directories must not be in the release tree")
    if "/build-mcp/" in path or path.endswith("/build-mcp"):
        return ("example-backups-and-build-mcp", "build-mcp checkout/build products must not be in the release tree")
    if path.startswith("Examples/iOS/PhotoSorter/Vendor/mlx-swift"):
        return ("example-backups-and-build-mcp", "large local MLX vendor checkouts need an explicit release policy")
    if path in {"bootstrap.js", "preload.js"}:
        return ("bundled-js-output", "loose bundled JavaScript output must not be in the release tree")
    if fnmatch.fnmatch(name, "main--*.js") or fnmatch.fnmatch(name, "src-*.js"):
        return ("bundled-js-output", "loose bundled JavaScript output must not be in the release tree")
    if path == "Conformance/Chat/CodexCliValidation/results" or path.startswith("Conformance/Chat/CodexCliValidation/results/"):
        return ("internal-validation-results", "generated validation result output must not be in the release tree")
    if path == "Conformance/Chat/CodexCliValidation/upstream" or path.startswith("Conformance/Chat/CodexCliValidation/upstream/"):
        return ("internal-validation-results", "local upstream checkout snapshots need an explicit release policy")
    if path == "Conformance/Chat/CodexCliValidation/instrumented-work" or path.startswith("Conformance/Chat/CodexCliValidation/instrumented-work/"):
        return ("internal-validation-results", "instrumented validation worktrees must not be in the release tree")
    return None


def is_codex_apply_patch_vendor_path(path: str) -> bool:
    normalized = path.rstrip("/")
    return (
        normalized == CODEX_APPLY_PATCH_VENDOR_ROOT
        or normalized.startswith(f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/")
    )


def is_codex_apply_patch_binary_artifact(path: str) -> bool:
    return (
        path.startswith(f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Artifacts/")
        and path.endswith(CODEX_APPLY_PATCH_BINARY_SUFFIXES)
    )


def is_codex_apply_patch_owned_text_path(path: str) -> bool:
    if not is_codex_apply_patch_vendor_path(path):
        return False
    if path.startswith(f"{CODEX_APPLY_PATCH_VENDOR_ROOT}/Source/codex-rs/"):
        return False
    if is_codex_apply_patch_binary_artifact(path):
        return False
    name = path.rsplit("/", 1)[-1]
    return "." in name or name in {"README", "LICENSE", "NOTICE"}


def read_text_if_available(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None


def read_bytes_if_available(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except OSError:
        return None


def is_probably_text(contents: bytes) -> bool:
    return b"\0" not in contents[:4096]


def git_blob_sha1(contents: bytes) -> str:
    header = f"blob {len(contents)}\0".encode("utf-8")
    return hashlib.sha1(header + contents).hexdigest()


def is_safe_relative_source_path(path: str) -> bool:
    if not path or path.startswith("/") or path.startswith("../") or "/../" in path:
        return False
    return not any(marker in path for marker in CODEX_APPLY_PATCH_HOST_PATH_TEXT_MARKERS)


def is_safe_relative_artifact_path(path: str) -> bool:
    if not path or path.startswith("/") or path.startswith("../") or "/../" in path:
        return False
    return not any(marker in path for marker in CODEX_APPLY_PATCH_HOST_PATH_TEXT_MARKERS)


def is_allowed_codex_apply_patch_provenance_path(path: str) -> bool:
    return (
        path in CODEX_APPLY_PATCH_PROVENANCE_EXACT_PATHS
        or path.startswith(CODEX_APPLY_PATCH_PROVENANCE_PREFIXES)
    )


def parse_provenance_source_file_line(line: str) -> tuple[str, str] | None:
    prefix = "git_blob_sha1="
    separator = " path="
    if not line.startswith(prefix) or separator not in line:
        return None
    digest, path = line[len(prefix):].split(separator, 1)
    if not GIT_BLOB_SHA1_PATTERN.fullmatch(digest):
        return None
    return digest, path.strip()


def parse_artifact_receipt_file_line(line: str) -> tuple[str, int, str] | None:
    prefix = "sha256="
    size_separator = " size="
    path_separator = " path="
    if not line.startswith(prefix) or size_separator not in line or path_separator not in line:
        return None
    digest, rest = line[len(prefix):].split(size_separator, 1)
    size_text, path = rest.split(path_separator, 1)
    if not SHA256_PATTERN.fullmatch(digest):
        return None
    try:
        size = int(size_text)
    except ValueError:
        return None
    if size < 0:
        return None
    return digest, size, path.strip()


def key_value_fields(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.splitlines():
        if line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key] = value
    return fields


def provenance_hygiene_reason(text: str, root: Path) -> str | None:
    fields: dict[str, str] = {}
    source_files: dict[str, str] = {}
    in_source_files = False
    saw_source_files_begin = False
    saw_source_files_end = False

    for line in text.splitlines():
        if line.startswith("source_path="):
            return (
                "Codex apply_patch provenance must name reproducible upstream source, "
                "not a local machine path"
            )
        if line in {"required_files_begin", "required_files_end"}:
            return (
                "Codex apply_patch provenance must use scoped source_files hash "
                "evidence, not legacy required_files evidence"
            )
        if line == "source_files_begin":
            saw_source_files_begin = True
            in_source_files = True
            continue
        if line == "source_files_end":
            saw_source_files_end = True
            in_source_files = False
            continue
        if in_source_files:
            parsed = parse_provenance_source_file_line(line)
            if parsed is None:
                return "Codex apply_patch provenance source_files entries must include Git blob hashes"
            digest, path = parsed
            if not is_safe_relative_source_path(path):
                return "Codex apply_patch provenance source file paths must be relative and portable"
            if not is_allowed_codex_apply_patch_provenance_path(path):
                return (
                    "Codex apply_patch provenance must only cover the apply_patch "
                    "runtime/proof source surface"
                )
            source_files[path] = digest
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value
        if line.startswith(("source_relative_status_count=", "source_status_count=")):
            value = line.split("=", 1)[1].strip()
            if value != "0":
                return (
                    "Codex apply_patch provenance must come from a clean source tree, "
                    "not a dirty source snapshot"
                )
        if line.startswith(("?? ", " M ", "M ", "A ", "D ", "R ", "C ", "UU ")):
            return (
                "Codex apply_patch provenance must not record untracked or modified "
                "source files"
            )

    source_git_head = fields.get("source_git_head")
    if source_git_head is None or source_git_head == "unknown":
        return "Codex apply_patch provenance must include a resolved source Git revision"
    if not GIT_BLOB_SHA1_PATTERN.fullmatch(source_git_head):
        return "Codex apply_patch provenance must include a 40-character source Git revision"
    if fields.get("source_scope") != CODEX_APPLY_PATCH_PROVENANCE_SCOPE:
        return "Codex apply_patch provenance must declare the scoped apply_patch runtime surface"
    if not saw_source_files_begin or not saw_source_files_end or not source_files:
        return "Codex apply_patch provenance must include scoped source_files hash evidence"
    missing_required = sorted(CODEX_APPLY_PATCH_REQUIRED_PROVENANCE_PATHS - set(source_files))
    if missing_required:
        return (
            "Codex apply_patch provenance is missing required runtime/proof source "
            f"hashes: {', '.join(missing_required[:3])}"
        )

    source_root = root / CODEX_APPLY_PATCH_PROVENANCE_SOURCE_ROOT
    for path, expected_digest in sorted(source_files.items()):
        source_path = source_root / path
        contents = read_bytes_if_available(source_path)
        if contents is None:
            return f"Codex apply_patch provenance names a missing source file: {path}"
        actual_digest = git_blob_sha1(contents)
        if actual_digest != expected_digest:
            return f"Codex apply_patch provenance hash does not match source file: {path}"
    return None


def provenance_source_file_paths(text: str) -> set[str] | None:
    source_files: set[str] = set()
    in_source_files = False
    saw_source_files_begin = False
    saw_source_files_end = False
    for line in text.splitlines():
        if line == "source_files_begin":
            saw_source_files_begin = True
            in_source_files = True
            continue
        if line == "source_files_end":
            saw_source_files_end = True
            in_source_files = False
            continue
        if in_source_files:
            parsed = parse_provenance_source_file_line(line)
            if parsed is None:
                return None
            _digest, path = parsed
            source_files.add(path)
    if not saw_source_files_begin or not saw_source_files_end:
        return None
    return source_files


def artifact_receipt_hygiene_reason(text: str, root: Path, provenance_text: str | None) -> str | None:
    fields: dict[str, str] = {}
    artifact_files: dict[str, tuple[str, int]] = {}
    in_artifact_files = False
    saw_artifact_files_begin = False
    saw_artifact_files_end = False

    for line in text.splitlines():
        if line == "artifact_files_begin":
            saw_artifact_files_begin = True
            in_artifact_files = True
            continue
        if line == "artifact_files_end":
            saw_artifact_files_end = True
            in_artifact_files = False
            continue
        if in_artifact_files:
            parsed = parse_artifact_receipt_file_line(line)
            if parsed is None:
                return "Codex apply_patch artifact receipt entries must include sha256, size, and relative path"
            digest, size, path = parsed
            if not is_safe_relative_artifact_path(path):
                return "Codex apply_patch artifact receipt paths must be relative and portable"
            artifact_files[path] = (digest, size)
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value

    if fields.get("format") != CODEX_APPLY_PATCH_ARTIFACT_RECEIPT_FORMAT:
        return "Codex apply_patch artifact receipt must declare the supported receipt format"
    if fields.get("artifact") != "MSPCodexApplyPatchBridge.xcframework":
        return "Codex apply_patch artifact receipt must name the XCFramework artifact"
    if fields.get("source_provenance") != "Source/CODEX_SOURCE_PROVENANCE.txt":
        return "Codex apply_patch artifact receipt must point at the source provenance file"
    if fields.get("source_scope") != CODEX_APPLY_PATCH_PROVENANCE_SCOPE:
        return "Codex apply_patch artifact receipt must declare the scoped apply_patch runtime surface"
    if fields.get("build_script") != "Scripts/build-xcframework.sh":
        return "Codex apply_patch artifact receipt must name the reproducible build script"
    if fields.get("path_remap_policy") != "required":
        return "Codex apply_patch artifact receipt must require path remapping"
    if fields.get("debug_symbols") != "stripped":
        return "Codex apply_patch artifact receipt must require stripped debug symbols"
    if not saw_artifact_files_begin or not saw_artifact_files_end or not artifact_files:
        return "Codex apply_patch artifact receipt must include artifact_files checksums"

    provenance_fields = key_value_fields(provenance_text or "")
    expected_source_git_head = provenance_fields.get("source_git_head")
    if expected_source_git_head and fields.get("source_git_head") != expected_source_git_head:
        return "Codex apply_patch artifact receipt source Git revision must match provenance"

    missing_required = sorted(CODEX_APPLY_PATCH_REQUIRED_ARTIFACT_FILES - set(artifact_files))
    if missing_required:
        return (
            "Codex apply_patch artifact receipt is missing required artifact "
            f"hashes: {', '.join(missing_required[:3])}"
        )

    artifact_root = root / CODEX_APPLY_PATCH_ARTIFACT_ROOT
    for path, (expected_digest, expected_size) in sorted(artifact_files.items()):
        artifact_path = artifact_root / path
        contents = read_bytes_if_available(artifact_path)
        if contents is None:
            return f"Codex apply_patch artifact receipt names a missing artifact file: {path}"
        actual_size = len(contents)
        if actual_size != expected_size:
            return f"Codex apply_patch artifact receipt size does not match artifact file: {path}"
        actual_digest = hashlib.sha256(contents).hexdigest()
        if actual_digest != expected_digest:
            return f"Codex apply_patch artifact receipt checksum does not match artifact file: {path}"
        if is_codex_apply_patch_binary_artifact(f"{CODEX_APPLY_PATCH_ARTIFACT_ROOT}/{path}"):
            if b"__DWARF" in contents:
                return "Codex apply_patch binary artifacts must not ship DWARF debug sections"
            if any(marker in contents for marker in CODEX_APPLY_PATCH_HOST_PATH_BINARY_MARKERS):
                return "Codex apply_patch binary artifacts must not embed local machine paths"
    return None


def codex_apply_patch_candidate_paths(root: Path, git_paths: list[str]) -> list[str]:
    if (root / ".git").exists():
        return sorted({
            path.rstrip("/")
            for path in git_paths
            if is_codex_apply_patch_vendor_path(path.rstrip("/"))
        })

    vendor_root = root / CODEX_APPLY_PATCH_VENDOR_ROOT
    if not vendor_root.exists():
        return []
    paths: list[str] = []
    for current_root, dirs, files in os.walk(vendor_root):
        current = Path(current_root)
        rel_current = current.relative_to(root).as_posix()
        for name in dirs:
            paths.append(f"{rel_current}/{name}")
        for name in files:
            paths.append(f"{rel_current}/{name}")
    return sorted(paths)


def codex_apply_patch_vendor_hygiene_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    candidate_paths = codex_apply_patch_candidate_paths(root, git_paths)
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    seen: set[tuple[str, str]] = set()

    def source_for(path: str) -> str:
        return "git-publishable" if path in git_publishable else "filesystem"

    def block(path: str, reason: str) -> None:
        key = (path, CODEX_APPLY_PATCH_VENDOR_RULE_ID)
        if key in seen:
            return
        seen.add(key)
        blocked.append(BlockedPath(
            path=path,
            reason=reason,
            rule_id=CODEX_APPLY_PATCH_VENDOR_RULE_ID,
            source=source_for(path),
        ))

    for required_path in CODEX_APPLY_PATCH_REQUIRED_EVIDENCE:
        if not (root / required_path).is_file():
            block(
                required_path,
                "Codex apply_patch vendor must include license and source provenance evidence",
            )

    provenance_path = root / CODEX_APPLY_PATCH_PROVENANCE
    provenance = read_text_if_available(provenance_path)
    declared_source_paths: set[str] | None = None
    if provenance is not None:
        reason = provenance_hygiene_reason(provenance, root)
        if reason is not None:
            block(CODEX_APPLY_PATCH_PROVENANCE, reason)
        declared_source_paths = provenance_source_file_paths(provenance)

    artifact_binary_paths = [
        path
        for path in candidate_paths
        if is_codex_apply_patch_binary_artifact(path)
    ]
    if artifact_binary_paths and not (root / CODEX_APPLY_PATCH_ARTIFACT_RECEIPT).is_file():
        block(
            CODEX_APPLY_PATCH_ARTIFACT_RECEIPT,
            "Codex apply_patch binary artifacts must include a build receipt and checksums",
        )
    receipt = read_text_if_available(root / CODEX_APPLY_PATCH_ARTIFACT_RECEIPT)
    if receipt is not None:
        reason = artifact_receipt_hygiene_reason(receipt, root, provenance)
        if reason is not None:
            block(CODEX_APPLY_PATCH_ARTIFACT_RECEIPT, reason)

    for path in candidate_paths:
        file_path = root / path
        if path.startswith(f"{CODEX_APPLY_PATCH_PROVENANCE_SOURCE_ROOT}/"):
            if file_path.is_file() or file_path.is_symlink():
                source_relative = path[len(f"{CODEX_APPLY_PATCH_PROVENANCE_SOURCE_ROOT}/"):]
                if declared_source_paths is None or source_relative not in declared_source_paths:
                    block(
                        path,
                        "Codex apply_patch source snapshot must only ship files listed in source provenance",
                    )
            continue
        if not file_path.is_file():
            continue
        if is_codex_apply_patch_binary_artifact(path):
            contents = read_bytes_if_available(file_path)
            if contents is None:
                continue
            if any(marker in contents for marker in CODEX_APPLY_PATCH_HOST_PATH_BINARY_MARKERS):
                block(
                    path,
                    "Codex apply_patch binary artifacts must not embed local machine paths",
                )
            continue
        if not is_codex_apply_patch_owned_text_path(path):
            continue
        contents = read_text_if_available(file_path)
        if contents is None:
            continue
        if any(marker in contents for marker in CODEX_APPLY_PATCH_HOST_PATH_TEXT_MARKERS):
            block(
                path,
                "Codex apply_patch vendor metadata and scripts must not contain local machine paths",
            )

    return sorted(blocked, key=lambda item: item.path), len(candidate_paths)


def codex_validation_local_host_path_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if (
                is_codex_validation_path(path.rstrip("/"))
                and not is_local_codex_source_snapshot(path.rstrip("/"))
                and hygiene_reason(path.rstrip("/")) is None
            )
        })
    else:
        validation_root = root / CODEX_VALIDATION_ROOT
        candidate_paths = []
        if validation_root.exists():
            for current_root, dirs, files in os.walk(validation_root):
                current = Path(current_root)
                rel_current = current.relative_to(root).as_posix()
                dirs[:] = [
                    name
                    for name in dirs
                    if name not in PRUNE_DIR_NAMES
                    and not is_local_codex_source_snapshot(f"{rel_current}/{name}")
                ]
                for name in files:
                    rel = f"{rel_current}/{name}"
                    if hygiene_reason(rel) is None:
                        candidate_paths.append(rel)
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore")
        if not any(marker in text for marker in CODEX_VALIDATION_LOCAL_HOST_PATH_MARKERS):
            continue
        blocked.append(BlockedPath(
            path=path,
            reason=(
                "Codex CLI validation evidence must use repo-relative paths, "
                "environment variables, or public placeholders instead of local machine paths"
            ),
            rule_id=CODEX_VALIDATION_LOCAL_HOST_PATH_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def codex_validation_local_evidence_reference_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if (
                is_codex_validation_path(path.rstrip("/"))
                and not is_local_codex_source_snapshot(path.rstrip("/"))
                and hygiene_reason(path.rstrip("/")) is None
            )
        })
    else:
        validation_root = root / CODEX_VALIDATION_ROOT
        candidate_paths = []
        if validation_root.exists():
            for current_root, dirs, files in os.walk(validation_root):
                current = Path(current_root)
                rel_current = current.relative_to(root).as_posix()
                dirs[:] = [
                    name
                    for name in dirs
                    if name not in PRUNE_DIR_NAMES
                    and not is_local_codex_source_snapshot(f"{rel_current}/{name}")
                ]
                for name in files:
                    rel = f"{rel_current}/{name}"
                    if hygiene_reason(rel) is None:
                        candidate_paths.append(rel)
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore")
        if not any(marker in text for marker in CODEX_VALIDATION_LOCAL_EVIDENCE_REFERENCE_MARKERS):
            continue
        blocked.append(BlockedPath(
            path=path,
            reason=(
                "Codex CLI validation public files must cite PUBLIC_EVIDENCE.md "
                "or retained phase-results instead of local reports/results paths"
            ),
            rule_id=CODEX_VALIDATION_LOCAL_EVIDENCE_REFERENCE_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def codex_validation_private_gate_narrative_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if (
                is_codex_validation_private_gate_narrative_path(path.rstrip("/"))
                and not is_local_codex_source_snapshot(path.rstrip("/"))
                and hygiene_reason(path.rstrip("/")) is None
            )
        })
    else:
        candidate_paths = []
        for relative_root in CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_ROOTS:
            candidate_root = root / relative_root
            if not candidate_root.exists():
                continue
            for current_root, dirs, files in os.walk(candidate_root):
                current = Path(current_root)
                rel_current = current.relative_to(root).as_posix()
                dirs[:] = [
                    name
                    for name in dirs
                    if name not in PRUNE_DIR_NAMES
                    and not is_local_codex_source_snapshot(f"{rel_current}/{name}")
                ]
                for name in files:
                    rel = f"{rel_current}/{name}"
                    if hygiene_reason(rel) is None:
                        candidate_paths.append(rel)
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore")
        if not any(marker in text for marker in CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_MARKERS):
            continue
        blocked.append(BlockedPath(
            path=path,
            reason=(
                "Codex CLI validation public files must cite public spec, "
                "manifest, mapping, and evidence inputs instead of local "
                "private draft or review-note gate narratives"
            ),
            rule_id=CODEX_VALIDATION_PRIVATE_GATE_NARRATIVE_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def codex_validation_public_phase_results_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    public_evidence = root / CODEX_VALIDATION_PUBLIC_EVIDENCE
    public_evidence_text = read_text_if_available(public_evidence) or ""
    listed_phase_results = set(
        CODEX_VALIDATION_PHASE_RESULT_REF_RE.findall(public_evidence_text)
    )

    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if path.rstrip("/") == CODEX_VALIDATION_PHASE_RESULTS_ROOT
            or path.rstrip("/").startswith(f"{CODEX_VALIDATION_PHASE_RESULTS_ROOT}/")
        })
    else:
        phase_results_root = root / CODEX_VALIDATION_PHASE_RESULTS_ROOT
        candidate_paths = []
        if phase_results_root.exists():
            for current_root, _dirs, files in os.walk(phase_results_root):
                current = Path(current_root)
                rel_current = current.relative_to(root).as_posix()
                for name in files:
                    candidate_paths.append(f"{rel_current}/{name}")
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        phase_ref = path.removeprefix(f"{CODEX_VALIDATION_ROOT}/")
        if phase_ref not in listed_phase_results:
            blocked.append(BlockedPath(
                path=path,
                reason=(
                    "Codex CLI validation phase-results files must be listed in "
                    "PUBLIC_EVIDENCE.md before they enter the public surface"
                ),
                rule_id=CODEX_VALIDATION_PHASE_RESULTS_RULE_ID,
                source="git-publishable" if path in git_publishable else "filesystem",
            ))
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore")
        if not any(marker in text for marker in CODEX_VALIDATION_RAW_IDENTITY_MARKERS):
            continue
        blocked.append(BlockedPath(
            path=path,
            reason=(
                "Codex CLI validation phase-results must not retain raw runtime "
                "identity markers such as installation IDs, server names, or user agents"
            ),
            rule_id=CODEX_VALIDATION_PHASE_RESULTS_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def first_party_local_host_path_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if is_first_party_local_host_path_scan_candidate(path.rstrip("/"))
        })
    else:
        candidate_paths = []
        for current_root, dirs, files in os.walk(root):
            current = Path(current_root)
            rel_current = current.relative_to(root).as_posix()
            kept_dirs: list[str] = []
            for name in dirs:
                rel = name if rel_current == "." else f"{rel_current}/{name}"
                if name in PRUNE_DIR_NAMES:
                    continue
                if (
                    is_local_linux_source_snapshot(rel)
                    or is_local_codex_source_snapshot(rel)
                    or is_internal_chat_spec(rel)
                    or is_local_readex_reference_snapshot(rel)
                ):
                    continue
                kept_dirs.append(name)
            dirs[:] = kept_dirs
            for name in files:
                rel = name if rel_current == "." else f"{rel_current}/{name}"
                if is_first_party_local_host_path_scan_candidate(rel):
                    candidate_paths.append(rel)
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore")
        if not any(marker in text for marker in FIRST_PARTY_LOCAL_HOST_PATH_MARKERS):
            continue
        blocked.append(BlockedPath(
            path=path,
            reason=(
                "first-party release files must use repo-relative paths, "
                "environment variables, or public placeholders instead of local machine paths"
            ),
            rule_id=FIRST_PARTY_LOCAL_HOST_PATH_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def markstream_public_surface_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if is_markstream_public_surface_scan_candidate(path.rstrip("/"))
        })
    else:
        candidate_paths = []
        for current_root, dirs, files in os.walk(root):
            current = Path(current_root)
            rel_current = current.relative_to(root).as_posix()
            kept_dirs: list[str] = []
            for name in dirs:
                rel = name if rel_current == "." else f"{rel_current}/{name}"
                if name in PRUNE_DIR_NAMES:
                    continue
                if is_markstream_public_surface_excluded(rel):
                    continue
                if hygiene_reason(rel) is not None:
                    continue
                kept_dirs.append(name)
            dirs[:] = kept_dirs
            for name in files:
                rel = name if rel_current == "." else f"{rel_current}/{name}"
                if is_markstream_public_surface_scan_candidate(rel):
                    candidate_paths.append(rel)
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore").lower()
        if MARKSTREAM_PUBLIC_SURFACE_MARKER not in text:
            continue
        blocked.append(BlockedPath(
            path=path,
            reason="Markstream renderer SDK/profile strings must not appear in the publishable MSP tree",
            rule_id=MARKSTREAM_PUBLIC_SURFACE_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def msp_chat_ui_markstream_vendor_hygiene_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if (
                path.rstrip("/") == MSP_CHAT_UI_ROOT
                or path.rstrip("/").startswith(f"{MSP_CHAT_UI_ROOT}/")
            )
        })
    else:
        ui_root = root / MSP_CHAT_UI_ROOT
        candidate_paths = []
        if ui_root.exists():
            for current_root, dirs, files in os.walk(ui_root):
                current = Path(current_root)
                rel_current = current.relative_to(root).as_posix()
                dirs[:] = [name for name in dirs if name not in PRUNE_DIR_NAMES]
                candidate_paths.extend(f"{rel_current}/{name}" for name in dirs)
                candidate_paths.extend(f"{rel_current}/{name}" for name in files)
            candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    seen: set[str] = set()

    def block(path: str, reason: str) -> None:
        if path in seen:
            return
        seen.add(path)
        blocked.append(BlockedPath(
            path=path,
            reason=reason,
            rule_id=MSP_CHAT_UI_MARKSTREAM_VENDOR_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))

    markstream_named_paths = {
        path
        for path in candidate_paths
        if MARKSTREAM_PUBLIC_SURFACE_MARKER in path.lower()
    }
    for path in sorted(markstream_named_paths - MSP_CHAT_UI_MARKSTREAM_ALLOWED_PATHS):
        block(
            path,
            "MSPChatUI must not add undeclared Markstream files outside the audited vendor surface",
        )

    required_paths = [
        MSP_CHAT_UI_MARKSTREAM_BUNDLE,
        MSP_CHAT_UI_MARKSTREAM_AUDIT,
        MSP_CHAT_UI_MARKSTREAM_RUNTIME_README,
        MSP_CHAT_UI_VENDOR_MANIFEST,
        MSP_CHAT_UI_THIRD_PARTY_NOTICES,
        MSP_CHAT_UI_PACKAGE_MANIFEST,
    ]
    for path in required_paths:
        if not (root / path).is_file():
            block(path, "MSPChatUI Markstream vendor surface is missing required audit evidence")

    bundle = read_bytes_if_available(root / MSP_CHAT_UI_MARKSTREAM_BUNDLE)
    audit_text = read_text_if_available(root / MSP_CHAT_UI_MARKSTREAM_AUDIT)
    audit: dict[str, object] | None = None
    if audit_text is not None:
        try:
            decoded = json.loads(audit_text)
            if isinstance(decoded, dict):
                audit = decoded
        except json.JSONDecodeError:
            pass
    if audit is None:
        block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit fixture must be valid JSON")
    else:
        bundle_record = audit.get("bundle")
        if not isinstance(bundle_record, dict):
            block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit must declare the bundled asset")
        else:
            expected_relative_bundle = MSP_CHAT_UI_MARKSTREAM_BUNDLE[len(f"{MSP_CHAT_UI_ROOT}/"):]
            if bundle_record.get("path") != expected_relative_bundle:
                block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit bundle path is not canonical")
            if bundle is not None:
                if bundle_record.get("bytes") != len(bundle):
                    block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit byte count does not match the bundle")
                if bundle_record.get("sha256") != hashlib.sha256(bundle).hexdigest():
                    block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit checksum does not match the bundle")

        allowed_licenses = audit.get("allowedLicenses")
        if (
            not isinstance(allowed_licenses, list)
            or not all(isinstance(item, str) for item in allowed_licenses)
            or set(allowed_licenses) != MSP_CHAT_UI_MARKSTREAM_APPROVED_LICENSES
        ):
            block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit license allowlist is incomplete or unexpected")

        packages = audit.get("packages")
        calculated_counts: dict[str, int] = {}
        if not isinstance(packages, list) or not packages:
            block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit must enumerate bundled packages")
        else:
            for package in packages:
                if not isinstance(package, dict):
                    block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit package records must be objects")
                    continue
                package_path = package.get("path")
                version = package.get("version")
                license_name = package.get("license")
                if not isinstance(package_path, str) or not package_path.startswith("node_modules/"):
                    block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit package paths must be node_modules-relative")
                if not isinstance(version, str) or not version:
                    block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit packages must declare versions")
                if license_name not in MSP_CHAT_UI_MARKSTREAM_APPROVED_LICENSES:
                    block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit contains an unapproved package license")
                if isinstance(license_name, str):
                    calculated_counts[license_name] = calculated_counts.get(license_name, 0) + 1
        if audit.get("licenseCounts") != calculated_counts:
            block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit license counts do not match package records")

        source_record = audit.get("source")
        package_lock = source_record.get("packageLock") if isinstance(source_record, dict) else None
        if (
            not isinstance(package_lock, str)
            or not package_lock
            or package_lock.startswith(("/", "~"))
            or ".." in Path(package_lock).parts
            or "/Users/" in package_lock
            or "/Volumes/" in package_lock
        ):
            block(MSP_CHAT_UI_MARKSTREAM_AUDIT, "MSPChatUI Markstream audit source path must be portable and relative")

    for evidence_path in [MSP_CHAT_UI_VENDOR_MANIFEST, MSP_CHAT_UI_THIRD_PARTY_NOTICES]:
        evidence = read_text_if_available(root / evidence_path)
        if evidence is None:
            continue
        if (
            "markstream-bundle-license-audit.json" not in evidence
            or "readex-markstream-sdk.js" not in evidence
        ):
            block(evidence_path, "MSPChatUI vendor evidence must name the audited Markstream bundle and fixture")

    package_text = read_text_if_available(root / MSP_CHAT_UI_PACKAGE_MANIFEST)
    if package_text is not None:
        try:
            package_manifest = json.loads(package_text)
        except json.JSONDecodeError:
            package_manifest = None
        scripts = package_manifest.get("scripts") if isinstance(package_manifest, dict) else None
        if (
            not isinstance(scripts, dict)
            or scripts.get("check:licenses") != "node Conformance/scripts/license-audit.cjs"
            or "check:licenses" not in str(scripts.get("check", ""))
        ):
            block(MSP_CHAT_UI_PACKAGE_MANIFEST, "MSPChatUI release checks must execute the Markstream license audit")

    return sorted(blocked, key=lambda item: item.path), len(candidate_paths)


def local_internal_spec_reference_scan(
    root: Path,
    git_paths: list[str],
) -> tuple[list[BlockedPath], int]:
    if (root / ".git").exists():
        candidate_paths = sorted({
            path.rstrip("/")
            for path in git_paths
            if is_local_internal_spec_reference_scan_candidate(path.rstrip("/"))
        })
    else:
        candidate_paths = []
        for current_root, dirs, files in os.walk(root):
            current = Path(current_root)
            rel_current = current.relative_to(root).as_posix()
            kept_dirs: list[str] = []
            for name in dirs:
                rel = name if rel_current == "." else f"{rel_current}/{name}"
                if name in PRUNE_DIR_NAMES:
                    continue
                if is_internal_chat_spec(rel) or is_internal_agentbridge_spec(rel):
                    continue
                if hygiene_reason(rel) is not None:
                    continue
                kept_dirs.append(name)
            dirs[:] = kept_dirs
            for name in files:
                rel = name if rel_current == "." else f"{rel_current}/{name}"
                if is_local_internal_spec_reference_scan_candidate(rel):
                    candidate_paths.append(rel)
        candidate_paths.sort()
    if not candidate_paths:
        return [], 0

    git_publishable = set(git_paths)
    blocked: list[BlockedPath] = []
    for path in candidate_paths:
        file_path = root / path
        if not file_path.is_file():
            continue
        contents = read_bytes_if_available(file_path)
        if contents is None or not is_probably_text(contents):
            continue
        text = contents.decode("utf-8", errors="ignore")
        if not any(marker in text for marker in LOCAL_INTERNAL_SPEC_REFERENCE_MARKERS):
            continue
        blocked.append(BlockedPath(
            path=path,
            reason=(
                "publishable files must not reference local-only internal spec "
                "paths that are absent from the release tree"
            ),
            rule_id=LOCAL_INTERNAL_SPEC_REFERENCE_RULE_ID,
            source="git-publishable" if path in git_publishable else "filesystem",
        ))
    return blocked, len(candidate_paths)


def blocked_paths(root: Path) -> tuple[list[BlockedPath], int, list[str]]:
    sources: dict[str, str] = {}
    git_paths = git_publishable_paths(root)
    for path in git_paths:
        sources[path.rstrip("/")] = "git-publishable"
    filesystem_paths, filesystem_scanned_count = filesystem_hygiene_scan(root)
    for path in filesystem_paths:
        sources.setdefault(path.rstrip("/"), "filesystem")

    blocked: list[BlockedPath] = []
    for path, source in sorted(sources.items()):
        reason = hygiene_reason(path)
        if reason is None:
            continue
        rule_id, message = reason
        blocked.append(BlockedPath(path=path, reason=message, rule_id=rule_id, source=source))
    apply_patch_blocked, apply_patch_scanned_count = codex_apply_patch_vendor_hygiene_scan(
        root,
        git_paths,
    )
    codex_validation_blocked, codex_validation_scanned_count = codex_validation_local_host_path_scan(
        root,
        git_paths,
    )
    codex_validation_evidence_blocked, codex_validation_evidence_scanned_count = (
        codex_validation_local_evidence_reference_scan(root, git_paths)
    )
    codex_validation_private_gate_blocked, codex_validation_private_gate_scanned_count = (
        codex_validation_private_gate_narrative_scan(root, git_paths)
    )
    codex_validation_phase_blocked, codex_validation_phase_scanned_count = (
        codex_validation_public_phase_results_scan(root, git_paths)
    )
    first_party_blocked, first_party_scanned_count = first_party_local_host_path_scan(
        root,
        git_paths,
    )
    markstream_blocked, markstream_scanned_count = markstream_public_surface_scan(
        root,
        git_paths,
    )
    msp_chat_ui_markstream_blocked, msp_chat_ui_markstream_scanned_count = (
        msp_chat_ui_markstream_vendor_hygiene_scan(root, git_paths)
    )
    local_internal_reference_blocked, local_internal_reference_scanned_count = (
        local_internal_spec_reference_scan(root, git_paths)
    )
    blocked.extend(codex_validation_blocked)
    blocked.extend(codex_validation_evidence_blocked)
    blocked.extend(codex_validation_private_gate_blocked)
    blocked.extend(codex_validation_phase_blocked)
    blocked.extend(first_party_blocked)
    blocked.extend(apply_patch_blocked)
    blocked.extend(markstream_blocked)
    blocked.extend(msp_chat_ui_markstream_blocked)
    blocked.extend(local_internal_reference_blocked)
    blocked.sort(key=lambda item: (item.path, item.rule_id, item.reason))
    return (
        blocked,
        (
            len(set(git_paths))
            + filesystem_scanned_count
            + codex_validation_scanned_count
            + codex_validation_evidence_scanned_count
            + codex_validation_private_gate_scanned_count
            + codex_validation_phase_scanned_count
            + first_party_scanned_count
            + apply_patch_scanned_count
            + markstream_scanned_count
            + msp_chat_ui_markstream_scanned_count
            + local_internal_reference_scanned_count
        ),
        git_paths,
    )


def build_report(root: Path) -> dict[str, object]:
    blocked, scanned_count, git_paths = blocked_paths(root)
    failures = [
        f"{item.path}: {item.reason}"
        for item in blocked
    ]
    return {
        "passed": not failures,
        "gate": GATE_NAME,
        "root": str(root),
        "source_sets": [
            "git tracked and untracked non-ignored files",
            "filesystem hygiene sentinel paths",
            "first-party local-host path scan",
            "Codex CLI validation local-host path scan",
            "Codex CLI validation local evidence reference scan",
            "Codex CLI validation private gate narrative scan",
            "Codex CLI validation phase-results public surface scan",
            "Codex apply_patch vendor provenance and artifacts",
            "Markstream public surface scan",
            "MSPChatUI Markstream vendor audit",
            "local internal spec reference scan",
        ],
        "required_rule_ids": REQUIRED_RULE_IDS,
        "git_publishable_path_count": len(git_paths),
        "scanned_path_count": scanned_count,
        "blocked_path_count": len(blocked),
        "blocked_paths": [
            {
                "path": item.path,
                "reason": item.reason,
                "rule_id": item.rule_id,
                "source": item.source,
            }
            for item in blocked
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
        print("MSP open-source hygiene gate passed")
        print(f"report={report_path}")
        return 0
    print("MSP open-source hygiene gate failed", file=sys.stderr)
    print(f"report={report_path}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
