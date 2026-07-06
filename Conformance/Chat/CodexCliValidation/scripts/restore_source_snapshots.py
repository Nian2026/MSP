#!/usr/bin/env python3
"""Restore local Codex source snapshots from upstream plus the `.chat` patch."""

from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile


UPSTREAM_URL = "https://github.com/openai/codex.git"
PINNED_COMMIT = "80f54d1266b4571ef649e7e5ecc382dd4e670937"
ORIGINAL_NAME = "openai-codex-original"
ADAPTED_NAME = "openai-codex-chat-backend"
PATCH_NAME = "chat-backend-minimal-thread-store-2026-07-03.patch"

SCRIPT_PATH = pathlib.Path(__file__).resolve()
VALIDATION_DIR = SCRIPT_PATH.parents[1]
SNAPSHOT_ROOT = VALIDATION_DIR / "source-snapshots"
PATCH_PATH = VALIDATION_DIR / "patches" / PATCH_NAME


def find_repo_root(start: pathlib.Path) -> pathlib.Path:
    for candidate in [start, *start.parents]:
        if (candidate / ".git").exists():
            return candidate
    return VALIDATION_DIR.parents[2]


REPO_ROOT = find_repo_root(VALIDATION_DIR)
DEFAULT_CACHE_REPO = REPO_ROOT / ".build" / "codex-cli-validation" / "openai-codex.git"


def run(command: list[str], cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=str(cwd) if cwd is not None else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "command failed: "
            + " ".join(command)
            + f"\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def ensure_upstream_repo(cache_repo: pathlib.Path, upstream_url: str) -> pathlib.Path:
    if cache_repo.exists():
        run(["git", "-C", str(cache_repo), "fetch", "--no-tags", "origin", PINNED_COMMIT])
    else:
        cache_repo.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--bare", "--no-tags", upstream_url, str(cache_repo)])
        run(["git", "-C", str(cache_repo), "fetch", "--no-tags", "origin", PINNED_COMMIT])
    return cache_repo


def verify_commit(repo: pathlib.Path) -> None:
    run(["git", "-C", str(repo), "cat-file", "-e", f"{PINNED_COMMIT}^{{commit}}"])


def export_archive(repo: pathlib.Path, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True)
    archive = subprocess.Popen(
        ["git", "-C", str(repo), "archive", "--format=tar", PINNED_COMMIT],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert archive.stdout is not None
    extracted = subprocess.run(
        ["tar", "-x", "-C", str(destination)],
        stdin=archive.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    archive.stdout.close()
    _, archive_stderr = archive.communicate()
    if archive.returncode != 0:
        raise RuntimeError(archive_stderr.decode("utf-8", errors="replace"))
    if extracted.returncode != 0:
        raise RuntimeError(extracted.stderr.decode("utf-8", errors="replace"))


def rewrite_path_line(line: str, adapted_root: pathlib.Path) -> str:
    marker = None
    if line.startswith("--- "):
        marker = "--- "
    elif line.startswith("+++ "):
        marker = "+++ "
    if marker is None:
        return line

    body = line[len(marker):]
    path_text, separator, suffix = body.partition("\t")
    original_prefix = f"Conformance/Chat/CodexCliValidation/source-snapshots/{ORIGINAL_NAME}/"
    adapted_prefix = f"Conformance/Chat/CodexCliValidation/source-snapshots/{ADAPTED_NAME}/"

    if path_text.startswith(original_prefix):
        relative = path_text.removeprefix(original_prefix)
        if marker == "--- " and not (adapted_root / relative).exists():
            return "--- /dev/null\n"
        return marker + relative + (separator + suffix if separator else "")
    if path_text.startswith(adapted_prefix):
        relative = path_text.removeprefix(adapted_prefix)
        return marker + relative + (separator + suffix if separator else "")
    return line


def rewrite_patch_for_adapted_tree(patch_path: pathlib.Path, adapted_root: pathlib.Path) -> str:
    original_prefix = f"Conformance/Chat/CodexCliValidation/source-snapshots/{ORIGINAL_NAME}/"
    adapted_prefix = f"Conformance/Chat/CodexCliValidation/source-snapshots/{ADAPTED_NAME}/"
    lines: list[str] = []
    for line in patch_path.read_text(encoding="utf-8").splitlines(keepends=True):
        if line.startswith("--- ") or line.startswith("+++ "):
            lines.append(rewrite_path_line(line, adapted_root))
        elif line.startswith("diff "):
            lines.append(line.replace(original_prefix, "").replace(adapted_prefix, ""))
        else:
            lines.append(line)
    return "".join(lines)


def apply_chat_backend_patch(adapted_root: pathlib.Path, patch_path: pathlib.Path) -> None:
    rewritten = rewrite_patch_for_adapted_tree(patch_path, adapted_root)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(rewritten)
        temporary_patch = pathlib.Path(handle.name)
    try:
        run(["patch", "-p0", "--batch", "--forward", "-i", str(temporary_patch)], cwd=adapted_root)
    finally:
        temporary_patch.unlink(missing_ok=True)


def restore_snapshots(
    upstream_repo: pathlib.Path,
    source_root: pathlib.Path,
    force: bool,
) -> None:
    original = source_root / ORIGINAL_NAME
    adapted = source_root / ADAPTED_NAME
    existing = [path for path in [original, adapted] if path.exists()]
    if existing and not force:
        joined = ", ".join(str(path) for path in existing)
        raise RuntimeError(f"snapshot directories already exist; pass --force to replace: {joined}")
    for path in existing:
        shutil.rmtree(path)

    source_root.mkdir(parents=True, exist_ok=True)
    export_archive(upstream_repo, original)
    shutil.copytree(original, adapted, symlinks=True)
    apply_chat_backend_patch(adapted, PATCH_PATH)


def run_integrity_check(source_root: pathlib.Path, upstream_repo: pathlib.Path | None) -> None:
    command = [
        sys.executable,
        str(VALIDATION_DIR / "tests" / "source_snapshot_integrity.py"),
        "--source-root",
        str(source_root),
    ]
    if upstream_repo is not None:
        command.extend(["--upstream-repo", str(upstream_repo)])
    run(command, cwd=REPO_ROOT)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=pathlib.Path, default=SNAPSHOT_ROOT)
    parser.add_argument("--upstream-repo", type=pathlib.Path)
    parser.add_argument("--cache-repo", type=pathlib.Path, default=DEFAULT_CACHE_REPO)
    parser.add_argument("--upstream-url", default=UPSTREAM_URL)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--skip-verify", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    upstream_repo = args.upstream_repo.expanduser().resolve() if args.upstream_repo else None
    if upstream_repo is None:
        upstream_repo = ensure_upstream_repo(args.cache_repo.expanduser().resolve(), args.upstream_url)
    verify_commit(upstream_repo)

    source_root = args.source_root.expanduser().resolve()
    restore_snapshots(upstream_repo, source_root, force=args.force)
    if not args.skip_verify:
        run_integrity_check(source_root, upstream_repo)

    print(f"restored source snapshots under {source_root}")
    print(f"pinned_commit={PINNED_COMMIT}")
    print(f"patch={PATCH_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
