#!/usr/bin/env python3
"""Validate the Codex original/adapted source snapshots used as `.chat` evidence.

The source snapshots are intentionally ordinary exported files, not nested git
repositories. This verifier checks the evidence package shape that future
parity work relies on: original must stay clean, adapted must contain only the
expected `.chat` backend source changes, and both trees must keep upstream
license/source sentinel files.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOTS_DIR = pathlib.Path(
    os.environ.get("CODEX_CHAT_VALIDATION_SOURCE_ROOT", VALIDATION_DIR / "source-snapshots")
).expanduser().resolve()
ORIGINAL = SNAPSHOTS_DIR / "openai-codex-original"
ADAPTED = SNAPSHOTS_DIR / "openai-codex-chat-backend"

PINNED_COMMIT = "80f54d1266b4571ef649e7e5ecc382dd4e670937"
EXPECTED_ORIGINAL_FILE_COUNT = 5313
EXPECTED_ADAPTED_FILE_COUNT = 5314

EXPECTED_CHANGED_FILES = {
    "codex-rs/config/src/config_toml.rs",
    "codex-rs/core/src/config/config_tests.rs",
    "codex-rs/core/src/config/mod.rs",
    "codex-rs/core/src/thread_manager.rs",
    "codex-rs/core/src/thread_manager_tests.rs",
    "codex-rs/thread-store/src/lib.rs",
}

EXPECTED_ADAPTED_ONLY_FILES = {
    "codex-rs/thread-store/src/chat/mod.rs",
}

REQUIRED_SENTINELS = [
    "LICENSE",
    "README.md",
    "codex-rs/Cargo.toml",
    "codex-rs/thread-store/src/lib.rs",
    "codex-rs/core/src/thread_manager.rs",
    "codex-rs/rollout/src/recorder.rs",
    "codex-rs/protocol/src/protocol.rs",
    "codex-rs/app-server/src/request_processors/thread_processor.rs",
]

UPSTREAM_SAMPLE_FILES = [
    "LICENSE",
    "codex-rs/config/src/config_toml.rs",
    "codex-rs/core/src/thread_manager.rs",
    "codex-rs/thread-store/src/lib.rs",
]

IGNORED_DIR_NAMES = {".git", "node_modules", "target"}


@dataclass
class Check:
    name: str
    status: str
    detail: str

    def as_json(self) -> dict[str, str]:
        return {"name": self.name, "status": self.status, "detail": self.detail}


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()


def rel(path: pathlib.Path) -> str:
    try:
        return path.relative_to(VALIDATION_DIR).as_posix()
    except ValueError:
        return path.as_posix()


def configure_snapshot_root(source_root: pathlib.Path) -> None:
    global SNAPSHOTS_DIR, ORIGINAL, ADAPTED
    SNAPSHOTS_DIR = source_root.expanduser().resolve()
    ORIGINAL = SNAPSHOTS_DIR / "openai-codex-original"
    ADAPTED = SNAPSHOTS_DIR / "openai-codex-chat-backend"


def add_check(checks: list[Check], name: str, passed: bool, detail: str) -> None:
    checks.append(Check(name=name, status="pass" if passed else "fail", detail=detail))


def add_info(checks: list[Check], name: str, detail: str) -> None:
    checks.append(Check(name=name, status="info", detail=detail))


def iter_files(root: pathlib.Path) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    if not root.exists():
        return files
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in IGNORED_DIR_NAMES]
        base = pathlib.Path(dirpath)
        for filename in filenames:
            files.append(base / filename)
    return sorted(files)


def relative_file_set(root: pathlib.Path) -> set[str]:
    return {path.relative_to(root).as_posix() for path in iter_files(root)}


def run_git(upstream_repo: pathlib.Path, args: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", "-C", str(upstream_repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def verify_upstream_commit(
    checks: list[Check],
    upstream_repo: pathlib.Path | None,
) -> None:
    if upstream_repo is None:
        add_info(
            checks,
            "upstream commit verification",
            "skipped; pass --upstream-repo or set CODEX_UPSTREAM_REPO",
        )
        return

    add_check(
        checks,
        "upstream repo exists",
        upstream_repo.is_dir(),
        str(upstream_repo),
    )
    if not upstream_repo.is_dir():
        return

    commit_check = run_git(upstream_repo, ["cat-file", "-e", f"{PINNED_COMMIT}^{{commit}}"])
    add_check(
        checks,
        "pinned commit object exists",
        commit_check.returncode == 0,
        PINNED_COMMIT,
    )
    if commit_check.returncode != 0:
        return

    tree_files = run_git(
        upstream_repo,
        ["ls-tree", "-r", "--name-only", "--full-tree", PINNED_COMMIT],
    )
    if tree_files.returncode == 0:
        upstream_files = {
            line.decode("utf-8")
            for line in tree_files.stdout.splitlines()
            if line.strip()
        }
        original_files = relative_file_set(ORIGINAL)
        missing = sorted(upstream_files - original_files)
        extra = sorted(original_files - upstream_files)
        add_check(
            checks,
            "original file list matches pinned commit",
            not missing and not extra,
            f"missing={len(missing)} extra={len(extra)}",
        )
    else:
        add_check(
            checks,
            "original file list matches pinned commit",
            False,
            tree_files.stderr.decode("utf-8", errors="replace").strip(),
        )

    mismatches: list[str] = []
    for sample in UPSTREAM_SAMPLE_FILES:
        shown = run_git(upstream_repo, ["show", f"{PINNED_COMMIT}:{sample}"])
        local_path = ORIGINAL / sample
        if shown.returncode != 0 or not local_path.is_file():
            mismatches.append(sample)
            continue
        if local_path.read_bytes() != shown.stdout:
            mismatches.append(sample)
    add_check(
        checks,
        "original sentinel content matches pinned commit",
        not mismatches,
        "mismatches=" + ", ".join(mismatches) if mismatches else "sample sentinels match",
    )


def verify_snapshot_shape(checks: list[Check]) -> None:
    add_check(checks, "original snapshot exists", ORIGINAL.is_dir(), rel(ORIGINAL))
    add_check(checks, "adapted snapshot exists", ADAPTED.is_dir(), rel(ADAPTED))

    original_count = len(iter_files(ORIGINAL))
    adapted_count = len(iter_files(ADAPTED))
    add_check(
        checks,
        "original source entry count",
        original_count == EXPECTED_ORIGINAL_FILE_COUNT,
        f"{original_count} source entries",
    )
    add_check(
        checks,
        "adapted source entry count",
        adapted_count == EXPECTED_ADAPTED_FILE_COUNT,
        f"{adapted_count} source entries",
    )

    for root_name, root in [("original", ORIGINAL), ("adapted", ADAPTED)]:
        license_path = root / "LICENSE"
        license_ok = license_path.is_file() and "Apache License" in license_path.read_text(
            encoding="utf-8",
            errors="replace",
        )
        add_check(checks, f"{root_name} LICENSE retained", license_ok, rel(license_path))

        missing = [path for path in REQUIRED_SENTINELS if not (root / path).is_file()]
        add_check(
            checks,
            f"{root_name} sentinel files present",
            not missing,
            "missing=" + ", ".join(missing) if missing else f"{len(REQUIRED_SENTINELS)} sentinels",
        )

        add_check(
            checks,
            f"{root_name} has no nested git metadata",
            not (root / ".git").exists(),
            rel(root / ".git"),
        )
        add_check(
            checks,
            f"{root_name} preserves upstream symlink entries",
            (root / "codex-rs/vendor/bubblewrap/LICENSE").is_symlink(),
            rel(root / "codex-rs/vendor/bubblewrap/LICENSE"),
        )

    original_chat_mod = ORIGINAL / "codex-rs/thread-store/src/chat/mod.rs"
    adapted_chat_mod = ADAPTED / "codex-rs/thread-store/src/chat/mod.rs"
    add_check(
        checks,
        "original has no chat backend module",
        not original_chat_mod.exists(),
        rel(original_chat_mod),
    )
    add_check(
        checks,
        "adapted has chat backend module",
        adapted_chat_mod.is_file(),
        rel(adapted_chat_mod),
    )

    original_lib = ORIGINAL / "codex-rs/thread-store/src/lib.rs"
    adapted_lib = ADAPTED / "codex-rs/thread-store/src/lib.rs"
    original_has_chat = original_lib.is_file() and b"ChatThreadStore" in original_lib.read_bytes()
    adapted_has_chat = adapted_lib.is_file() and b"ChatThreadStore" in adapted_lib.read_bytes()
    add_check(
        checks,
        "original does not export ChatThreadStore",
        not original_has_chat,
        rel(original_lib),
    )
    add_check(
        checks,
        "adapted exports ChatThreadStore",
        adapted_has_chat,
        rel(adapted_lib),
    )


def verify_diff_allowlist(checks: list[Check]) -> None:
    original_files = relative_file_set(ORIGINAL)
    adapted_files = relative_file_set(ADAPTED)

    original_only = original_files - adapted_files
    adapted_only = adapted_files - original_files
    common = original_files & adapted_files
    changed = {
        path
        for path in common
        if (ORIGINAL / path).read_bytes() != (ADAPTED / path).read_bytes()
    }

    unexpected_original_only = sorted(original_only)
    unexpected_adapted_only = sorted(adapted_only - EXPECTED_ADAPTED_ONLY_FILES)
    missing_adapted_only = sorted(EXPECTED_ADAPTED_ONLY_FILES - adapted_only)
    unexpected_changed = sorted(changed - EXPECTED_CHANGED_FILES)
    missing_changed = sorted(EXPECTED_CHANGED_FILES - changed)

    add_check(
        checks,
        "no original-only files",
        not unexpected_original_only,
        f"unexpected={unexpected_original_only[:8]} count={len(unexpected_original_only)}",
    )
    add_check(
        checks,
        "adapted-only files match allowlist",
        not unexpected_adapted_only and not missing_adapted_only,
        f"unexpected={unexpected_adapted_only} missing={missing_adapted_only}",
    )
    add_check(
        checks,
        "changed files match allowlist",
        not unexpected_changed and not missing_changed,
        f"unexpected={unexpected_changed} missing={missing_changed}",
    )
    add_info(
        checks,
        "diff summary",
        f"changed={len(changed)} adapted_only={len(adapted_only)} original_only={len(original_only)}",
    )


def write_outputs(
    summary: dict[str, Any],
    json_output: pathlib.Path | None,
    report_output: pathlib.Path | None,
) -> None:
    if json_output is not None:
        json_output.parent.mkdir(parents=True, exist_ok=True)
        json_output.write_text(
            json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    if report_output is not None:
        report_output.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# Source Snapshot Integrity - 2026-07-03",
            "",
            "This is retained validation evidence for the Codex CLI `.chat` backend source package.",
            "",
            "It validates only source snapshot integrity. It is not runtime parity evidence.",
            "",
            "## Scope",
            "",
            f"- Pinned commit: `{PINNED_COMMIT}`",
            f"- Original snapshot: `{rel(ORIGINAL)}`",
            f"- Adapted snapshot: `{rel(ADAPTED)}`",
            "",
            "## Gate Files Read",
            "",
            "This report is generated for a gated `.chat` execution pass. The pass must read:",
            "",
            "- `Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt`",
            "- `Spec/Chat/README.md`",
            "- `Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md`",
            "- `Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md`",
            "- `Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md`",
            "",
            "This verifier reuses the current conclusion that `source-snapshots/` is the durable source-evidence path.",
            "",
            "## Result",
            "",
            f"- Status: `{summary['status']}`",
            f"- Generated at: `{summary['generated_at']}`",
            f"- Failed checks: `{summary['failed_check_count']}`",
            "",
            "## Checks",
            "",
        ]
        for check in summary["checks"]:
            lines.append(
                f"- `{check['status']}` {check['name']}: {check['detail']}"
            )
        lines.extend(
            [
                "",
                "## Boundary",
                "",
                "This verifier does not read or modify PhotoSorter, Xcode projects, MLX vendor paths, or any app package graph.",
                "",
            ]
        )
        report_output.write_text("\n".join(lines), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=pathlib.Path, default=SNAPSHOTS_DIR)
    parser.add_argument("--json-output", type=pathlib.Path)
    parser.add_argument("--report-output", type=pathlib.Path)
    parser.add_argument(
        "--upstream-repo",
        type=pathlib.Path,
        default=(
            pathlib.Path(os.environ["CODEX_UPSTREAM_REPO"])
            if os.environ.get("CODEX_UPSTREAM_REPO")
            else None
        ),
        help="Optional local git checkout containing the pinned upstream commit.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    configure_snapshot_root(args.source_root)
    checks: list[Check] = []
    verify_snapshot_shape(checks)
    verify_diff_allowlist(checks)
    verify_upstream_commit(checks, args.upstream_repo)

    failed = [check for check in checks if check.status == "fail"]
    summary: dict[str, Any] = {
        "status": "pass" if not failed else "fail",
        "generated_at": utc_now(),
        "validation_dir": str(VALIDATION_DIR),
        "pinned_commit": PINNED_COMMIT,
        "failed_check_count": len(failed),
        "checks": [check.as_json() for check in checks],
    }
    write_outputs(summary, args.json_output, args.report_output)

    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
