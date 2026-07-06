from __future__ import annotations


REMOTE_RUNNER = r'''
import base64
import json
import os
import pwd
import grp
import re
import selectors
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import hashlib
from pathlib import Path

request = json.loads(base64.b64decode("__PAYLOAD__").decode("utf-8"))
cases = request["cases"]
run_id = request["run_id"]
max_file_content = int(request.get("max_file_content", 65536))
max_stdout = int(request.get("max_stdout", 524288))
max_stderr = int(request.get("max_stderr", 524288))
max_file_tree_records = int(request.get("max_file_tree_records", 4096))
max_file_tree_bytes = int(request.get("max_file_tree_bytes", 8388608))
max_created_file_bytes = int(request.get("max_created_file_bytes", 4194304))
RUN_ROOT_PREFIX = "/tmp/msp-oracle-capture-"
RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
CASE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

def enc(data):
    return base64.b64encode(data).decode("ascii")

def safe_join(root, relative):
    if not relative or relative in (".", "./") or relative.startswith("/") or ".." in Path(relative).parts:
        raise RuntimeError("unsafe relative path: " + relative)
    path = os.path.normpath(os.path.join(root, relative))
    root_real = os.path.realpath(root)
    parent_real = os.path.realpath(os.path.dirname(path))
    if parent_real != root_real and not parent_real.startswith(root_real + os.sep):
        raise RuntimeError("path escapes case root: " + relative)
    return path

def shell_argv(case):
    dialect = case.get("shell", {}).get("dialect", "bash")
    if dialect == "sh":
        return ["/bin/sh", "-c", case["command_line"]]
    return ["/bin/bash", "--noprofile", "--norc", "-c", case["command_line"]]

def nobody_identity():
    try:
        user = pwd.getpwnam("nobody")
        try:
            group = grp.getgrnam("nogroup")
        except KeyError:
            group = grp.getgrgid(user.pw_gid)
        return user.pw_uid, group.gr_gid
    except KeyError:
        return None, None

def validate_run_id(value):
    if not RUN_ID_RE.fullmatch(value):
        raise RuntimeError("unsafe run id: " + repr(value))

def validate_run_root(path):
    real = os.path.realpath(path)
    expected = RUN_ROOT_PREFIX + run_id + "-"
    if not real.startswith(expected):
        raise RuntimeError("run root escapes oracle prefix: " + real)
    if os.path.islink(real):
        raise RuntimeError("run root must not be a symlink: " + real)
    return real

def append_capped(buffer, data, limit):
    remaining = limit - len(buffer)
    if remaining <= 0:
        return True
    if len(data) > remaining:
        buffer.extend(data[:remaining])
        return True
    buffer.extend(data)
    return False

def run_process_limited(argv, cwd, stdin, env, timeout_seconds, popen_kwargs):
    process = subprocess.Popen(
        argv,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        start_new_session=True,
        **popen_kwargs,
    )
    if stdin:
        try:
            process.stdin.write(stdin)
        except BrokenPipeError:
            pass
    if process.stdin is not None:
        process.stdin.close()

    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    truncated = {"stdout": False, "stderr": False}
    for stream_name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, stream_name)

    deadline = time.monotonic() + timeout_seconds
    timed_out = False
    while selector.get_map():
        if not timed_out and time.monotonic() >= deadline:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        wait_for = 0.05 if timed_out else min(0.05, max(0.0, deadline - time.monotonic()))
        events = selector.select(wait_for)
        if not events and process.poll() is not None:
            wait_for = 0.0
            events = selector.select(wait_for)
            if not events:
                break
        for key, _ in events:
            stream_name = key.data
            try:
                chunk = os.read(key.fileobj.fileno(), 65536)
            except BlockingIOError:
                continue
            if not chunk:
                selector.unregister(key.fileobj)
                key.fileobj.close()
                continue
            if stream_name == "stdout":
                truncated["stdout"] = append_capped(stdout, chunk, max_stdout) or truncated["stdout"]
            else:
                truncated["stderr"] = append_capped(stderr, chunk, max_stderr) or truncated["stderr"]

    if timed_out and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return_code = process.wait()
    if timed_out:
        return_code = 124
    return bytes(stdout), bytes(stderr), return_code, timed_out, truncated

def materialize_fixture(root, fixture):
    for directory in fixture.get("directories", []):
        path = safe_join(root, directory)
        os.makedirs(path, exist_ok=True)
        os.chmod(path, 0o777)
    for item in fixture.get("files", []):
        path = safe_join(root, item["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(item.get("content_b64", "")))
        mode_text = item.get("mode", "0644")
        os.chmod(path, int(mode_text, 8))

def capture_tree(root):
    records = []
    state = {"limit_exceeded": False, "limit_reasons": [], "tree_bytes": 0}

    def mark_limit(reason):
        state["limit_exceeded"] = True
        if reason not in state["limit_reasons"]:
            state["limit_reasons"].append(reason)

    def add_record(record):
        if len(records) >= max_file_tree_records:
            mark_limit("file-tree-record-count")
            return False
        encoded = json.dumps(record, ensure_ascii=False, sort_keys=True).encode("utf-8", "surrogateescape")
        state["tree_bytes"] += len(encoded)
        if state["tree_bytes"] > max_file_tree_bytes:
            mark_limit("file-tree-byte-count")
            return False
        records.append(record)
        return True

    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        dirs.sort()
        files.sort()
        rel_current = os.path.relpath(current, root)
        display_current = "." if rel_current == "." else "./" + rel_current
        st = os.lstat(current)
        if not add_record({
            "path": display_current,
            "path_b64": enc(display_current.encode("utf-8", "surrogateescape")),
            "kind": "directory",
            "mode": format(stat.S_IMODE(st.st_mode), "03o"),
            "size": None,
        }):
            break
        for name in files:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root)
            display = "./" + rel
            st = os.lstat(full)
            mode = format(stat.S_IMODE(st.st_mode), "03o")
            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(full)
                if not add_record({
                    "path": display,
                    "path_b64": enc(display.encode("utf-8", "surrogateescape")),
                    "kind": "symlink",
                    "mode": mode,
                    "target": target,
                    "target_b64": enc(target.encode("utf-8", "surrogateescape")),
                    "size": None,
                }):
                    break
                continue
            if not stat.S_ISREG(st.st_mode):
                if not add_record({
                    "path": display,
                    "path_b64": enc(display.encode("utf-8", "surrogateescape")),
                    "kind": "other",
                    "mode": mode,
                    "size": st.st_size,
                }):
                    break
                continue
            record = {
                "path": display,
                "path_b64": enc(display.encode("utf-8", "surrogateescape")),
                "kind": "file",
                "mode": mode,
                "size": st.st_size,
            }
            if st.st_size > max_created_file_bytes:
                mark_limit("created-file-byte-count")
            else:
                with open(full, "rb") as handle:
                    data = handle.read()
                record["sha256"] = hashlib.sha256(data).hexdigest()
                if len(data) <= max_file_content:
                    record["content_b64"] = enc(data)
            if not add_record(record):
                break
    return records, state

def normalize_bytes(data, case_root, run_root):
    value = data.replace(case_root.encode(), b"<CASE_ROOT>")
    value = value.replace(run_root.encode(), b"<CASE_RUNNER_ROOT>")
    return value

validate_run_id(run_id)
run_root = tempfile.mkdtemp(prefix="msp-oracle-capture-" + run_id + "-", dir="/tmp")
run_root = validate_run_root(run_root)
uid, gid = nobody_identity()
results = []
try:
    os.chmod(run_root, 0o755)
    for case in cases:
        case_id = case["id"]
        if not CASE_ID_RE.fullmatch(case_id):
            raise RuntimeError("unsafe case id: " + repr(case_id))
        case_dir = os.path.join(run_root, case_id)
        case_root = os.path.join(case_dir, "case-root")
        os.makedirs(case_root, exist_ok=True)
        os.chmod(case_dir, 0o755)
        os.chmod(case_root, 0o777)
        materialize_fixture(case_root, case.get("fixture", {}))
        env = {
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "TZ": "UTC",
            "HOME": case_root,
        }
        stdin = base64.b64decode(case.get("standard_input_b64", ""))
        start = time.monotonic()
        kwargs = {}
        if uid is not None and gid is not None and os.geteuid() == 0:
            kwargs["user"] = uid
            kwargs["group"] = gid
            kwargs["extra_groups"] = []
        stdout, stderr, exit_code, timed_out, output_limits = run_process_limited(
            shell_argv(case),
            case_root,
            stdin,
            env,
            float(case.get("timeout_seconds", 5.0)),
            kwargs,
        )
        elapsed = time.monotonic() - start
        file_tree, tree_limits = capture_tree(case_root)
        limit_reasons = []
        if output_limits["stdout"]:
            limit_reasons.append("stdout-byte-count")
        if output_limits["stderr"]:
            limit_reasons.append("stderr-byte-count")
        limit_reasons.extend(tree_limits["limit_reasons"])
        results.append({
            "type": "case",
            "id": case_id,
            "category": case.get("category"),
            "case_type": case.get("case_type"),
            "shell": case.get("shell"),
            "commands": case.get("commands", []),
            "command_line": case.get("command_line"),
            "timeout": timed_out,
            "elapsed_seconds": elapsed,
            "stdout_b64": enc(normalize_bytes(stdout, case_root, run_root)),
            "stderr_b64": enc(normalize_bytes(stderr, case_root, run_root)),
            "raw_stdout_b64": enc(stdout),
            "raw_stderr_b64": enc(stderr),
            "stdout_truncated": output_limits["stdout"],
            "stderr_truncated": output_limits["stderr"],
            "exit_code": exit_code,
            "file_tree": file_tree,
            "limit_exceeded": bool(limit_reasons),
            "limit_reasons": limit_reasons,
            "vps_case_root": case_root,
            "vps_runner_root": run_root,
        })
finally:
    cleanup_root = validate_run_root(run_root)
    if cleanup_root.startswith("/tmp/msp-oracle-capture-" + run_id + "-"):
        shutil.rmtree(run_root, ignore_errors=True)
    else:
        raise RuntimeError("refusing cleanup outside owned run root: " + run_root)

print(json.dumps({
    "run_id": run_id,
    "results": results,
    "tool_versions": {},
}, ensure_ascii=False))
'''
