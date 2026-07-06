#!/usr/bin/env python3
"""Create and verify a publishable open-source dry-run tree."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


GATE_NAME = "msp-open-source-release-dry-run"
SCHEMA_VERSION = 1
PUBLISHABLE_FILE_SET_RULE = "git ls-files -co --exclude-standard -z, existing files and symlinks only"

EXAMPLES = [
    ("MSPPlaygroundApp", "Examples/iOS/MSPPlaygroundApp"),
    ("PhotoSorter", "Examples/iOS/PhotoSorter"),
]

RELEASE_CANDIDATE_CONTRACT = [
    "copy current publishable Git worktree surface into a temporary release tree",
    "run open-source gates inside the copied release tree",
    "run default SwiftPM tests for MSPPlaygroundApp and PhotoSorter inside the copied release tree",
    "do not treat source-tree-only results as publishable release evidence",
]

REQUIRED_CHECKS = [
    {
        "check_id": "open-source-example-boundary",
        "kind": "gate-script",
        "description": "copied tree only contains the public iOS examples and their allowed dependencies",
    },
    {
        "check_id": "open-source-hygiene",
        "kind": "gate-script",
        "description": "copied tree contains no release-blocking local artifacts or private validation output",
    },
    {
        "check_id": "example-chat-renderer-vendor-hygiene",
        "kind": "gate-script",
        "description": "copied tree example transcript renderer vendor assets have manifests, bounded symlinks, and third-party license evidence",
    },
    {
        "check_id": "open-source-license-notice",
        "kind": "gate-script",
        "description": "copied tree has root license/notice files and public third-party license evidence",
    },
    {
        "check_id": "photosorter-default-package-boundary",
        "kind": "gate-script",
        "description": "copied tree PhotoSorter default package excludes local FastVLM sources, model weights, and MLX package products",
    },
    {
        "check_id": "swift-test-MSPPlaygroundApp",
        "kind": "swiftpm-test",
        "package_path": "Examples/iOS/MSPPlaygroundApp",
        "description": "default SwiftPM test for the public MSPPlaygroundApp example package",
    },
    {
        "check_id": "swift-test-PhotoSorter",
        "kind": "swiftpm-test",
        "package_path": "Examples/iOS/PhotoSorter",
        "description": "default SwiftPM test for the public PhotoSorter example package",
    },
]

REQUIRED_EXAMPLES = [
    {
        "name": example,
        "package_path": package_path,
        "required_command": "swift test",
    }
    for example, package_path in EXAMPLES
]

COVERAGE = [
    "copied publishable release tree",
    "open-source example boundary gate on copied tree",
    "open-source hygiene gate on copied tree",
    "example chat renderer vendor/license hygiene gate on copied tree",
    "open-source license/notice gate on copied tree",
    "PhotoSorter default package/local FastVLM boundary gate on copied tree",
    "public MSPPlaygroundApp and PhotoSorter SwiftPM tests on copied tree",
]

TEST_SUMMARY_RE = re.compile(
    r"Executed\s+([0-9,]+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>[0-9,]+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>[0-9,]+)\s+failures?"
    r"(?:\s+\((?P<unexpected>[0-9,]+)\s+unexpected\))?",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class PathRule:
    rule_id: str
    reason: str
    predicate: Callable[[str], bool]


PATH_RULES = [
    PathRule(
        "swift-build-output",
        "build output must not be copied into the release dry-run tree",
        lambda path: (
            path == ".build"
            or path.startswith(".build/")
            or path == ".swiftpm"
            or path.startswith(".swiftpm/")
            or path == "DerivedData"
            or path.startswith("DerivedData/")
            or "/DerivedData/" in path
            or "/.build/" in path
            or "/.swiftpm/" in path
            or "/build/" in path.lower()
            or path.lower().endswith("/build")
            or "xcuserdata" in path.lower()
            or path.endswith(".xcuserstate")
        ),
    ),
    PathRule(
        "old-readex-runtime-surface",
        "old ReadexRuntime adapters/vendors/tests must not be in the public example release tree",
        lambda path: (
            "/ReadexRuntime/" in f"/{path}/"
            or "/Tests/ReadexRuntimeTests/" in f"/{path}/"
            or path.startswith("Examples/iOS/MSPPlaygroundApp/Adapters/ReadexRuntime/")
            or path.startswith("Examples/iOS/PhotoSorter/Adapters/ReadexRuntime/")
        ),
    ),
    PathRule(
        "private-source-archive",
        "private source archive directories must not be in the release dry-run tree",
        lambda path: "/SourceArchive/" in f"/{path}/" or path.endswith("/SourceArchive"),
    ),
    PathRule(
        "local-fastvlm-artifacts",
        "local FastVLM sources, model weights, and MLX checkouts must stay out of the default release tree",
        lambda path: (
            path.startswith("Examples/iOS/PhotoSorter/Local/FastVLM/")
            or path == "Examples/iOS/PhotoSorter/Project/PhotoSorter.local.xcodeproj"
            or path.startswith("Examples/iOS/PhotoSorter/Project/PhotoSorter.local.xcodeproj/")
            or path.startswith("Examples/iOS/PhotoSorter/Resources/FastVLM/model/")
            or path.startswith("Examples/iOS/PhotoSorter/Vendor/mlx-swift")
        ),
    ),
]

POST_TEST_GENERATED_PATH_RULES = [
    PathRule(
        "swiftpm-generated-package-resolved",
        "SwiftPM-generated package resolution files must not remain in the final release dry-run tree",
        lambda path: path == "Package.resolved" or path.endswith("/Package.resolved"),
    ),
    *PATH_RULES,
]

POST_TEST_REMOVABLE_PATHS = (
    "Examples/iOS/MSPPlaygroundApp/Package.resolved",
    "Examples/iOS/PhotoSorter/Package.resolved",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Copy the current publishable Git worktree surface to a temporary "
            "release tree, then run open-source gates and example SwiftPM tests "
            "against that copied tree."
        )
    )
    parser.add_argument("--root", default=".", help="source repository root")
    parser.add_argument(
        "--out-dir",
        help=(
            "output directory for the dry-run. Defaults to "
            ".build/msp-conformance/open-source-release-dry-run/<timestamp>"
        ),
    )
    parser.add_argument(
        "--publish-dir-name",
        default="publish",
        help="directory name under --out-dir for the copied release tree",
    )
    parser.add_argument(
        "--report",
        help="JSON report path. Defaults to <out-dir>/open-source-release-dry-run-report.json",
    )
    parser.add_argument(
        "--skip-swift-tests",
        action="store_true",
        help="copy the tree and run hygiene gates, but skip example swift test commands",
    )
    return parser.parse_args()


def is_relative_to(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def run(
    command: list[str],
    *,
    cwd: Path,
    log_path: Path,
    check_id: str,
    purpose: str,
    package_path: str | None = None,
    evidence_report: Path | None = None,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    with log_path.open("w", encoding="utf-8") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.write(f"cwd={cwd}\n\n")
        try:
            completed = subprocess.run(
                command,
                cwd=cwd,
                env=merged_env,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
            exit_code = completed.returncode
        except FileNotFoundError as error:
            log.write(f"\ncommand not found: {error}\n")
            exit_code = 127

    elapsed = round(time.time() - started_at, 3)
    report: dict[str, Any] = {
        "check_id": check_id,
        "purpose": purpose,
        "command": command,
        "cwd": str(cwd),
        "exit_code": exit_code,
        "log": str(log_path.resolve()),
        "passed": exit_code == 0,
        "elapsed_seconds": elapsed,
    }
    if package_path is not None:
        report["package_path"] = package_path
    if evidence_report is not None:
        report["evidence_report"] = str(evidence_report.resolve())
    return report


def swift_test_summary(log_path: Path) -> dict[str, int | None]:
    if not log_path.is_file():
        return {
            "executed_test_count": None,
            "skipped_test_count": None,
            "failure_count": None,
            "unexpected_failure_count": None,
        }
    text = log_path.read_text(encoding="utf-8", errors="replace")
    matches = list(TEST_SUMMARY_RE.finditer(text))
    if not matches:
        return {
            "executed_test_count": None,
            "skipped_test_count": None,
            "failure_count": None,
            "unexpected_failure_count": None,
        }
    match = matches[-1]
    return {
        "executed_test_count": int(match.group(1).replace(",", "")),
        "skipped_test_count": int((match.group("skipped") or "0").replace(",", "")),
        "failure_count": int(match.group("failures").replace(",", "")),
        "unexpected_failure_count": int((match.group("unexpected") or "0").replace(",", "")),
    }


def git_current_file_set(root: Path) -> list[str]:
    command = ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"]
    completed = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    paths: set[str] = set()
    for item in completed.stdout.split(b"\0"):
        if not item:
            continue
        rel = item.decode("utf-8", errors="surrogateescape")
        path = root / rel
        if path.exists() or path.is_symlink():
            paths.add(rel)
    return sorted(paths)


def safe_reset_out_dir(out_dir: Path, root: Path) -> None:
    build_root = root / ".build"
    if out_dir.exists() or out_dir.is_symlink():
        if not is_relative_to(out_dir, build_root):
            raise SystemExit(
                f"refusing to remove out-dir outside {build_root}: {out_dir}"
            )
        if out_dir.is_symlink() or out_dir.is_file():
            out_dir.unlink()
        else:
            shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)


def copy_file_set(root: Path, publish_root: Path, paths: list[str]) -> dict[str, Any]:
    copied_files = 0
    copied_symlinks = 0
    skipped: list[str] = []

    for rel in paths:
        source = root / rel
        destination = publish_root / rel
        if source.is_symlink():
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(os.readlink(source), destination)
            copied_symlinks += 1
            continue
        if not source.is_file():
            skipped.append(rel)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied_files += 1

    return {
        "candidate_path_count": len(paths),
        "copied_file_count": copied_files,
        "copied_symlink_count": copied_symlinks,
        "skipped_paths": skipped,
    }


def path_rule_findings(
    paths: list[str],
    rules: list[PathRule] | None = None,
) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    path_rules = PATH_RULES if rules is None else rules
    for path in paths:
        for rule in path_rules:
            if rule.predicate(path):
                findings.append({
                    "path": path,
                    "rule_id": rule.rule_id,
                    "message": rule.reason,
                })
                break
    return findings


def release_tree_paths(publish_root: Path) -> list[str]:
    paths: list[str] = []
    if not publish_root.exists():
        return paths
    for path in sorted(publish_root.rglob("*")):
        if path == publish_root:
            continue
        try:
            rel = path.relative_to(publish_root).as_posix()
        except ValueError:
            continue
        paths.append(rel)
    return paths


def remove_post_test_generated_paths(publish_root: Path) -> list[str]:
    removed: list[str] = []
    for rel in POST_TEST_REMOVABLE_PATHS:
        path = publish_root / rel
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
        removed.append(rel)
    return removed


def symlink_findings(publish_root: Path) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    root = publish_root.resolve()
    for path in sorted(publish_root.rglob("*")):
        if not path.is_symlink():
            continue
        rel = path.relative_to(publish_root).as_posix()
        target = os.readlink(path)
        if os.path.isabs(target):
            findings.append({
                "path": rel,
                "rule_id": "absolute-symlink-target",
                "message": f"symlink target is absolute: {target}",
            })
            continue
        resolved = (path.parent / target).resolve(strict=False)
        if not resolved.exists():
            findings.append({
                "path": rel,
                "rule_id": "broken-symlink",
                "message": f"symlink target does not exist: {target}",
            })
            continue
        if not is_relative_to(resolved, root):
            findings.append({
                "path": rel,
                "rule_id": "symlink-target-outside-release-tree",
                "message": f"symlink target resolves outside release tree: {target}",
            })
    return findings


def write_report(report_path: Path, report: dict[str, Any]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    args = parse_args()
    root = Path(args.root).expanduser().resolve()
    if not (root / ".git").exists():
        print(f"source root is not a Git worktree: {root}", file=sys.stderr)
        return 2

    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = (
        Path(args.out_dir).expanduser().resolve()
        if args.out_dir
        else root / ".build" / "msp-conformance" / "open-source-release-dry-run" / stamp
    )
    report_path = (
        Path(args.report).expanduser().resolve()
        if args.report
        else out_dir / "open-source-release-dry-run-report.json"
    )
    publish_root = out_dir / args.publish_dir_name
    logs_dir = out_dir / "logs"
    reports_dir = out_dir / "reports"
    scratch_root = out_dir / "scratch"

    safe_reset_out_dir(out_dir, root)

    print("== collect current publishable file set ==")
    paths = git_current_file_set(root)
    print(f"candidate_paths={len(paths)}")

    print("== copy release dry-run tree ==")
    copy_summary = copy_file_set(root, publish_root, paths)
    print(f"publish_root={publish_root}")
    print(
        "copied_files={copied_file_count} copied_symlinks={copied_symlink_count}".format(
            **copy_summary
        )
    )

    copied_path_findings = path_rule_findings(paths)
    copied_symlink_findings = symlink_findings(publish_root)

    command_results: list[dict[str, Any]] = []
    command_env = {"PYTHONDONTWRITEBYTECODE": "1"}

    print("== run open-source example boundary gate on copied tree ==")
    boundary_report = reports_dir / "open-source-example-boundary.json"
    command_results.append(run(
        [
            sys.executable,
            str(publish_root / "Conformance/Scripts/check_open_source_example_boundary.py"),
            "--root",
            str(publish_root),
            "--report",
            str(boundary_report),
        ],
        cwd=publish_root,
        log_path=logs_dir / "open-source-example-boundary.log",
        check_id="open-source-example-boundary",
        purpose="open-source example boundary gate on copied tree",
        evidence_report=boundary_report,
        env=command_env,
    ))

    print("== run open-source hygiene gate on copied tree ==")
    hygiene_report = reports_dir / "open-source-hygiene.json"
    command_results.append(run(
        [
            sys.executable,
            str(publish_root / "Conformance/Scripts/check_open_source_hygiene.py"),
            "--root",
            str(publish_root),
            "--report",
            str(hygiene_report),
        ],
        cwd=publish_root,
        log_path=logs_dir / "open-source-hygiene.log",
        check_id="open-source-hygiene",
        purpose="open-source hygiene gate on copied tree",
        evidence_report=hygiene_report,
        env=command_env,
    ))

    print("== run example chat renderer vendor hygiene gate on copied tree ==")
    renderer_vendor_report = reports_dir / "example-chat-renderer-vendor-hygiene.json"
    command_results.append(run(
        [
            sys.executable,
            str(publish_root / "Conformance/Scripts/check_example_chat_renderer_vendor_hygiene.py"),
            "--root",
            str(publish_root),
            "--report",
            str(renderer_vendor_report),
        ],
        cwd=publish_root,
        log_path=logs_dir / "example-chat-renderer-vendor-hygiene.log",
        check_id="example-chat-renderer-vendor-hygiene",
        purpose="example chat renderer vendor/license hygiene gate on copied tree",
        evidence_report=renderer_vendor_report,
        env=command_env,
    ))

    print("== run open-source license/notice gate on copied tree ==")
    license_notice_report = reports_dir / "open-source-license-notice.json"
    command_results.append(run(
        [
            sys.executable,
            str(publish_root / "Conformance/Scripts/check_open_source_license_notice.py"),
            "--root",
            str(publish_root),
            "--report",
            str(license_notice_report),
        ],
        cwd=publish_root,
        log_path=logs_dir / "open-source-license-notice.log",
        check_id="open-source-license-notice",
        purpose="open-source license/notice gate on copied tree",
        evidence_report=license_notice_report,
        env=command_env,
    ))

    print("== run PhotoSorter default package boundary gate on copied tree ==")
    photosorter_boundary_report = reports_dir / "photosorter-default-package-boundary.json"
    command_results.append(run(
        [
            sys.executable,
            str(publish_root / "Conformance/Scripts/check_photosorter_default_package_boundary.py"),
            "--root",
            str(publish_root),
            "--report",
            str(photosorter_boundary_report),
        ],
        cwd=publish_root,
        log_path=logs_dir / "photosorter-default-package-boundary.log",
        check_id="photosorter-default-package-boundary",
        purpose="PhotoSorter default package/local FastVLM boundary gate on copied tree",
        evidence_report=photosorter_boundary_report,
        env=command_env,
    ))

    if args.skip_swift_tests:
        print("== skip example swift tests ==")
    else:
        for example, package_rel in EXAMPLES:
            print(f"== run {example} swift test on copied tree ==")
            log_path = logs_dir / f"{example}-swift-test.log"
            result = run(
                [
                    "swift",
                    "test",
                    "--package-path",
                    str(publish_root / package_rel),
                    "--scratch-path",
                    str(scratch_root / example),
                ],
                cwd=publish_root,
                log_path=log_path,
                check_id=f"swift-test-{example}",
                purpose=f"default SwiftPM test for public {example} example on copied tree",
                package_path=package_rel,
                env=command_env,
            )
            result.update(swift_test_summary(log_path))
            command_results.append(result)

    print("== scan release dry-run tree after commands ==")
    post_test_removed_paths = remove_post_test_generated_paths(publish_root)
    post_test_generated_path_findings = path_rule_findings(
        release_tree_paths(publish_root),
        POST_TEST_GENERATED_PATH_RULES,
    )

    failures: list[str] = []
    if copy_summary["skipped_paths"]:
        failures.append("some candidate paths were skipped during copy")
    for finding in copied_path_findings + copied_symlink_findings:
        failures.append(f"{finding['rule_id']}: {finding['path']}")
    for finding in post_test_generated_path_findings:
        failures.append(f"{finding['rule_id']}: {finding['path']}")
    for result in command_results:
        if not result["passed"]:
            failures.append(
                f"command failed with exit code {result['exit_code']}: "
                + " ".join(result["command"])
            )
        if result["command"][:2] == ["swift", "test"] and result.get("failure_count") not in (0, None):
            failures.append(f"swift test reported failures: {result['log']}")

    report = {
        "schema_version": SCHEMA_VERSION,
        "passed": not failures,
        "gate": GATE_NAME,
        "source_root": str(root),
        "out_dir": str(out_dir),
        "publish_root": str(publish_root),
        "report": str(report_path),
        "release_candidate_contract": RELEASE_CANDIDATE_CONTRACT,
        "publishable_file_set_rule": PUBLISHABLE_FILE_SET_RULE,
        "file_set_rule": PUBLISHABLE_FILE_SET_RULE,
        "required_checks": REQUIRED_CHECKS,
        "required_examples": REQUIRED_EXAMPLES,
        "coverage": COVERAGE,
        "copy_summary": copy_summary,
        "release_tree_checks": {
            "path_findings": copied_path_findings,
            "symlink_findings": copied_symlink_findings,
            "post_test_removed_paths": post_test_removed_paths,
            "post_test_generated_path_findings": post_test_generated_path_findings,
        },
        "commands": command_results,
        "failures": failures,
    }
    write_report(report_path, report)

    if report["passed"]:
        print("MSP open-source release dry-run passed")
        print(f"publish_root={publish_root}")
        print(f"report={report_path}")
        return 0

    print("MSP open-source release dry-run failed", file=sys.stderr)
    print(f"publish_root={publish_root}", file=sys.stderr)
    print(f"report={report_path}", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
