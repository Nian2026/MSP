from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

READ_ONLY_SNAPSHOT_DIRS = [
    "References/ReadexShellSnapshot",
    "References/ReadexReadingAgentSnapshot",
]

SCRIPT_SCAN_ROOTS = [
    "Conformance/Scripts",
    "Examples/iOS/MSPPlaygroundApp/Tools/E2E",
    "Examples/iOS/PhotoSorter/Tools/E2E",
]

FORBIDDEN_EXTERNAL_READEX_MARKERS = [
    "/Volumes/PrivateReference/Projects/Readex",
    "/Volumes/PrivateReference/Projects/Readex-Internal",
    "PrivateReadexReferenceApp",
    "PRIVATE_READEX_REFERENCE_",
    "READEX_SOURCE_ROOT",
    "READOS_SOURCE_ROOT",
]

DEFAULT_SCAN_EXCLUDED_FILENAMES = {
    "readex_boundary.py",
    "verify_readex_boundary.py",
}


def run_git_status(root: Path, relative_paths: list[str]) -> list[str]:
    command = ["git", "-C", str(root), "status", "--porcelain", "--", *relative_paths]
    completed = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        raise ValueError(
            "git status failed while checking Readex snapshots: "
            + completed.stderr.strip()
        )
    return [
        line
        for line in completed.stdout.splitlines()
        if line.strip()
    ]


def script_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for relative_root in SCRIPT_SCAN_ROOTS:
        scan_root = root / relative_root
        if not scan_root.exists():
            continue
        for path in scan_root.rglob("*"):
            if path.is_file() and path.suffix in {".sh", ".py"}:
                paths.append(path)
    return sorted(paths)


def is_excluded_scan_file(path: Path) -> bool:
    return path.name in DEFAULT_SCAN_EXCLUDED_FILENAMES


def scanned_script_paths(root: Path) -> list[str]:
    return [
        path.relative_to(root).as_posix()
        for path in script_files(root)
        if not is_excluded_scan_file(path)
    ]


def scan_forbidden_markers(root: Path) -> list[str]:
    hits: list[str] = []
    for path in script_files(root):
        if is_excluded_scan_file(path):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        relative = path.relative_to(root).as_posix()
        for marker in FORBIDDEN_EXTERNAL_READEX_MARKERS:
            if marker in text:
                hits.append(f"{relative}: forbidden external Readex marker {marker!r}")
    return hits


def verify_readex_boundary_root(root: Path) -> dict[str, Any]:
    root = root.resolve()
    failures: list[str] = []

    missing_snapshots = [
        relative
        for relative in READ_ONLY_SNAPSHOT_DIRS
        if not (root / relative).is_dir()
    ]
    for relative in missing_snapshots:
        failures.append(f"missing Readex reference snapshot directory: {relative}")

    dirty_snapshots: list[str] = []
    if not missing_snapshots:
        try:
            dirty_snapshots = run_git_status(root, READ_ONLY_SNAPSHOT_DIRS)
        except ValueError as exc:
            failures.append(str(exc))
            dirty_snapshots = []
        for line in dirty_snapshots:
            failures.append(f"Readex reference snapshot is not clean: {line}")

    forbidden_hits = scan_forbidden_markers(root)
    failures.extend(forbidden_hits)

    scanned_scripts = scanned_script_paths(root)
    return {
        "passed": not failures,
        "failures": failures,
        "root": str(root),
        "read_only_snapshot_dirs": READ_ONLY_SNAPSHOT_DIRS,
        "dirty_snapshot_status": dirty_snapshots,
        "forbidden_external_readex_markers": FORBIDDEN_EXTERNAL_READEX_MARKERS,
        "script_scan_roots": SCRIPT_SCAN_ROOTS,
        "scanned_script_count": len(scanned_scripts),
        "scanned_scripts": scanned_scripts,
    }
