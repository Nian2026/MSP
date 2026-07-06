import Foundation
import MSPPythonRuntime

enum MSPCPythonBootstrapSource {
    static func makeSource(payload: MSPCPythonExecutionPayload) throws -> String {
        let payloadData = try JSONEncoder().encode(payload)
        let payloadB64 = payloadData.base64EncodedString()
        let vfsBootstrapSource = indentedSource(MSPPythonVirtualFileSystemBootstrapSource.source, spaces: 8)
        let body = #"""
import base64 as _msp_base64
import builtins as _msp_builtins
import io as _msp_io
import json as _msp_json
import os as _msp_os
import runpy as _msp_runpy
import shlex as _msp_shlex
import subprocess as _msp_subprocess
import sys as _msp_sys
import time as _msp_time
import traceback as _msp_traceback
import uuid as _msp_uuid

_msp_payload = _msp_json.loads(_msp_base64.b64decode("__MSP_PAYLOAD_B64__").decode("utf-8"))
_msp_stdout_bytes = _msp_io.BytesIO()
_msp_stderr_bytes = _msp_io.BytesIO()
_msp_old_stdin = _msp_sys.stdin
_msp_old_stdout = _msp_sys.stdout
_msp_old_stderr = _msp_sys.stderr
_msp_old_argv = list(_msp_sys.argv)
_msp_old_path0 = _msp_sys.path[0] if _msp_sys.path else None
_msp_old_environ = dict(_msp_os.environ)
_msp_real_open = _msp_builtins.open
_msp_exit_code = 0

class _MSPCPythonUserCodeException(BaseException):
    def __init__(self, exc_type, exc_value, exc_tb):
        self.exc_type = exc_type
        self.exc_value = exc_value
        self.exc_tb = exc_tb

class _MSPTeeRawIO(_msp_io.RawIOBase):
    def __init__(self, *targets):
        self._targets = targets

    def writable(self):
        return True

    def write(self, value):
        data = bytes(value)
        for target in self._targets:
            target.write(data)
            try:
                target.flush()
            except BaseException:
                pass
        return len(data)

    def flush(self):
        for target in self._targets:
            try:
                target.flush()
            except BaseException:
                pass

def _msp_cpython_stdin_binary():
    stdin_fd = _msp_payload.get("stdin_fd")
    if stdin_fd is not None:
        return _msp_os.fdopen(int(stdin_fd), "rb", buffering=0, closefd=False)
    return _msp_io.BytesIO(_msp_base64.b64decode(_msp_payload["stdin_b64"]))

def _msp_cpython_output_text(byte_buffer, fd_key, encoding, errors):
    fd = _msp_payload.get(fd_key)
    binary = byte_buffer
    if fd is not None:
        live_binary = _msp_os.fdopen(int(fd), "wb", buffering=0, closefd=False)
        binary = _MSPTeeRawIO(byte_buffer, live_binary)
    return _msp_io.TextIOWrapper(
        binary,
        encoding=encoding,
        errors=errors,
        write_through=True,
    )

def _msp_cpython_set_path0(value):
    if _msp_sys.path:
        _msp_sys.path[0] = value
    else:
        _msp_sys.path.insert(0, value)

def _msp_cpython_exec_user_code(source_bytes, filename):
    globals_dict = {
        "__name__": "__main__",
        "__doc__": None,
        "__package__": None,
        "__loader__": None,
        "__spec__": None,
        "__builtins__": _msp_builtins,
        "__file__": filename,
    }
    try:
        exec(compile(source_bytes, filename, "exec"), globals_dict)
    except SystemExit:
        raise
    except BaseException as _msp_user_error:
        raise _MSPCPythonUserCodeException(
            type(_msp_user_error),
            _msp_user_error,
            _msp_user_error.__traceback__
        )

def _msp_cpython_exit(code=None):
    raise SystemExit(code)

def _msp_cpython_run_basic_repl():
    globals_dict = {
        "__name__": "__main__",
        "__doc__": None,
        "__package__": None,
        "__loader__": None,
        "__spec__": None,
        "__builtins__": _msp_builtins,
        "exit": _msp_cpython_exit,
        "quit": _msp_cpython_exit,
    }
    while True:
        line = _msp_sys.stdin.readline()
        if line == "":
            return
        if not line.strip():
            continue
        try:
            code = compile(line, "<stdin>", "single")
            exec(code, globals_dict)
        except SystemExit:
            raise
        except BaseException as _msp_repl_error:
            _msp_cpython_print_exception(
                type(_msp_repl_error),
                _msp_repl_error,
                _msp_repl_error.__traceback__
            )

def _msp_cpython_is_internal_frame(frame):
    name = getattr(frame, "name", "")
    return name.startswith("_msp_cpython_") or name.startswith("_msp_vfs_")

def _msp_cpython_print_exception(exc_type, exc_value, exc_tb):
    extracted = [
        frame
        for frame in _msp_traceback.extract_tb(exc_tb)
        if not _msp_cpython_is_internal_frame(frame)
    ]
    _msp_sys.stderr.write("Traceback (most recent call last):\n")
    for frame in extracted:
        _msp_sys.stderr.write(f'  File "{frame.filename}", line {frame.lineno}, in {frame.name}\n')
    _msp_sys.stderr.write("".join(_msp_traceback.format_exception_only(exc_type, exc_value)))

def _msp_cpython_subprocess_bytes(value, text_mode):
    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return value.encode("utf-8", "surrogateescape")
    return bytes(value)

def _msp_cpython_subprocess_text(value):
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return value.decode("utf-8", "surrogateescape")

def _msp_cpython_subprocess_executable_path(executable):
    if executable is None:
        return None
    return _msp_os.fsdecode(_msp_os.fspath(executable))

def _msp_cpython_subprocess_shell_parts(args):
    if isinstance(args, str):
        return args, []
    sequence = [str(part) for part in args]
    if not sequence:
        return "", []
    return sequence[0], sequence[1:]

def _msp_cpython_subprocess_command_line(args, shell, executable=None):
    executable = _msp_cpython_subprocess_executable_path(executable)
    if shell:
        command, shell_args = _msp_cpython_subprocess_shell_parts(args)
        if executable or shell_args:
            launcher = executable or "/bin/sh"
            return _msp_shlex.join([launcher, "-c", command] + shell_args)
        return command
    if isinstance(args, str):
        if executable:
            return _msp_shlex.join([executable])
        return args
    parts = [str(part) for part in args]
    if executable:
        parts = [executable] + parts[1:]
    return _msp_shlex.join(parts)

def _msp_cpython_subprocess_request(command_line, stdin_data, cwd, env, timeout):
    broker_dir = _msp_payload.get("subprocess_broker_dir")
    if not broker_dir:
        raise RuntimeError("subprocess support is unavailable")
    request_id = str(_msp_uuid.uuid4())
    request_path = _msp_os.path.join(broker_dir, "request-" + request_id + ".json")
    request_tmp_path = request_path + ".tmp"
    response_path = _msp_os.path.join(broker_dir, "response-" + request_id + ".json")
    request = {
        "id": request_id,
        "command_line": command_line,
        "stdin_b64": _msp_base64.b64encode(stdin_data).decode("ascii"),
        "cwd": cwd or _msp_payload.get("virtual_cwd") or "/",
        "environment": env if env is not None else _msp_payload.get("environment", {}),
    }
    with open(request_tmp_path, "w", encoding="utf-8") as request_file:
        _msp_json.dump(request, request_file)
    _msp_os.replace(request_tmp_path, request_path)
    started_at = _msp_time.monotonic()
    while not _msp_os.path.exists(response_path):
        if timeout is not None and (_msp_time.monotonic() - started_at) > timeout:
            raise _msp_subprocess.TimeoutExpired(command_line, timeout)
        _msp_time.sleep(0.005)
    with open(response_path, "r", encoding="utf-8") as response_file:
        return _msp_json.load(response_file)

def _msp_cpython_subprocess_run(args, input=None, capture_output=False, timeout=None, check=False, **kwargs):
    shell = bool(kwargs.pop("shell", False))
    text_mode = bool(kwargs.pop("text", False) or kwargs.pop("universal_newlines", False))
    encoding = kwargs.pop("encoding", None)
    errors = kwargs.pop("errors", None)
    if encoding is not None:
        text_mode = True
    stdout_target = kwargs.pop("stdout", None)
    stderr_target = kwargs.pop("stderr", None)
    stdin_target = kwargs.pop("stdin", None)
    cwd = kwargs.pop("cwd", None)
    env = kwargs.pop("env", None)
    executable = kwargs.pop("executable", None)
    if kwargs:
        raise TypeError("subprocess.run() got unsupported keyword argument(s): " + ", ".join(sorted(kwargs.keys())))
    if capture_output:
        if stdout_target is not None or stderr_target is not None:
            raise ValueError("stdout and stderr arguments may not be used with capture_output")
        stdout_target = _msp_subprocess.PIPE
        stderr_target = _msp_subprocess.PIPE
    if stdin_target not in (None, _msp_subprocess.PIPE):
        raise ValueError("subprocess only supports stdin=None or stdin=PIPE")
    stdin_data = _msp_cpython_subprocess_bytes(input, text_mode)
    command_line = _msp_cpython_subprocess_command_line(args, shell, executable)
    response = _msp_cpython_subprocess_request(command_line, stdin_data, cwd, env, timeout)
    stdout_bytes = _msp_base64.b64decode(response.get("stdout_b64", ""))
    stderr_bytes = _msp_base64.b64decode(response.get("stderr_b64", ""))
    if stderr_target is _msp_subprocess.STDOUT:
        stdout_bytes = stdout_bytes + stderr_bytes
        stderr_bytes = b""
    stdout_value = _msp_cpython_subprocess_text(stdout_bytes) if text_mode else stdout_bytes
    stderr_value = _msp_cpython_subprocess_text(stderr_bytes) if text_mode else stderr_bytes
    if stdout_target is None:
        if stdout_value:
            _msp_sys.stdout.write(stdout_value if text_mode else stdout_bytes.decode("utf-8", "surrogateescape"))
        completed_stdout = None
    elif stdout_target is _msp_subprocess.DEVNULL:
        completed_stdout = None
    elif stdout_target is _msp_subprocess.PIPE:
        completed_stdout = stdout_value
    else:
        raise ValueError("subprocess only supports stdout=None, PIPE, or DEVNULL")
    if stderr_target is None:
        if stderr_value:
            _msp_sys.stderr.write(stderr_value if text_mode else stderr_bytes.decode("utf-8", "replace"))
        completed_stderr = None
    elif stderr_target in (_msp_subprocess.DEVNULL, _msp_subprocess.STDOUT):
        completed_stderr = None
    elif stderr_target is _msp_subprocess.PIPE:
        completed_stderr = stderr_value
    else:
        raise ValueError("subprocess only supports stderr=None, PIPE, STDOUT, or DEVNULL")
    completed = _msp_subprocess.CompletedProcess(
        args,
        int(response.get("exit_code", 1)),
        completed_stdout,
        completed_stderr,
    )
    if check:
        completed.check_returncode()
    return completed

def _msp_cpython_subprocess_check_output(*popenargs, timeout=None, **kwargs):
    kwargs["stdout"] = _msp_subprocess.PIPE
    kwargs.setdefault("check", True)
    return _msp_cpython_subprocess_run(*popenargs, timeout=timeout, **kwargs).stdout

def _msp_cpython_subprocess_call(*popenargs, timeout=None, **kwargs):
    return _msp_cpython_subprocess_run(*popenargs, timeout=timeout, **kwargs).returncode

def _msp_cpython_subprocess_check_call(*popenargs, timeout=None, **kwargs):
    return _msp_cpython_subprocess_run(*popenargs, timeout=timeout, check=True, **kwargs).returncode

def _msp_cpython_install_subprocess_patch():
    _msp_subprocess.run = _msp_cpython_subprocess_run
    _msp_subprocess.check_output = _msp_cpython_subprocess_check_output
    _msp_subprocess.call = _msp_cpython_subprocess_call
    _msp_subprocess.check_call = _msp_cpython_subprocess_check_call

def _msp_cpython_is_python_executable(name):
    try:
        base = str(name).replace("\\\\", "/").rsplit("/", 1)[-1]
    except BaseException:
        return False
    return base in ("python", "python3")

def _msp_cpython_parse_shell_heredoc(command_line):
    lines = str(command_line).splitlines()
    if len(lines) < 2 or "<<" not in lines[0]:
        return None
    before, marker = lines[0].split("<<", 1)
    marker = marker.strip()
    if not marker:
        return None
    if (marker.startswith("'") and marker.endswith("'")) or (marker.startswith('"') and marker.endswith('"')):
        marker = marker[1:-1]
    if not lines[-1].strip() == marker:
        return None
    try:
        argv = _msp_shlex.split(before.strip())
    except BaseException:
        return None
    body = "\n".join(lines[1:-1]) + "\n"
    return argv, body.encode("utf-8", "surrogateescape")

def _msp_cpython_parse_nested_python(args, shell, command_line, stdin_data):
    if shell:
        parsed_heredoc = _msp_cpython_parse_shell_heredoc(command_line)
        if parsed_heredoc is not None:
            argv, stdin_data = parsed_heredoc
        else:
            try:
                argv = _msp_shlex.split(str(command_line))
            except BaseException:
                return None
    elif isinstance(args, (list, tuple)):
        argv = [str(part) for part in args]
    else:
        try:
            argv = _msp_shlex.split(str(args))
        except BaseException:
            return None
    if not argv or not _msp_cpython_is_python_executable(argv[0]):
        return None
    child_args = list(argv[1:])
    index = 0
    while index < len(child_args):
        argument = child_args[index]
        if argument == "--":
            index += 1
            break
        if argument == "-c":
            if index + 1 >= len(child_args):
                return None
            return {
                "mode": "command",
                "source": str(child_args[index + 1]).encode("utf-8", "surrogateescape"),
                "filename": "<string>",
                "argv": ["-c"] + child_args[index + 2:],
            }
        if argument.startswith("-c") and argument != "-":
            return {
                "mode": "command",
                "source": str(argument[2:]).encode("utf-8", "surrogateescape"),
                "filename": "<string>",
                "argv": ["-c"] + child_args[index + 1:],
            }
        if argument == "-":
            return {
                "mode": "stdin",
                "source": stdin_data or b"",
                "filename": "<stdin>",
                "argv": ["-"] + child_args[index + 1:],
            }
        if argument == "-m" or argument.startswith("-m"):
            return None
        if not argument.startswith("-"):
            return {
                "mode": "script",
                "source_path": str(argument),
                "filename": str(argument),
                "argv": [str(argument)] + child_args[index + 1:],
            }
        if argument in ("-W", "-X") and index + 1 < len(child_args):
            index += 2
            continue
        index += 1
    if index < len(child_args):
        script_path = str(child_args[index])
        return {
            "mode": "script",
            "source_path": script_path,
            "filename": script_path,
            "argv": [script_path] + child_args[index + 1:],
        }
    if not child_args:
        return {
            "mode": "stdin",
            "source": stdin_data or b"",
            "filename": "<stdin>",
            "argv": [""],
        }
    return None

def _msp_cpython_run_nested_python(args=None, shell=False, command_line=None, stdin_data=b"", cwd=None, env=None):
    parsed = _msp_cpython_parse_nested_python(args, shell, command_line, stdin_data)
    if parsed is None:
        return None
    stdout_bytes = _msp_io.BytesIO()
    stderr_bytes = _msp_io.BytesIO()
    old_stdin = _msp_sys.stdin
    old_stdout = _msp_sys.stdout
    old_stderr = _msp_sys.stderr
    old_argv = list(_msp_sys.argv)
    old_path0 = _msp_sys.path[0] if _msp_sys.path else None
    old_environ = dict(_msp_os.environ)
    old_cwd = None
    try:
        old_cwd = _msp_os.getcwd()
    except BaseException:
        old_cwd = None
    try:
        pending_writeback_state = _msp_vfs_capture_pending_writeback_state()
    except NameError:
        pending_writeback_state = None
    except BaseException:
        pending_writeback_state = None
    captured_stdout_bytes = b""
    captured_stderr_bytes = b""
    exit_code = 0
    try:
        if env is not None:
            _msp_os.environ.clear()
            _msp_os.environ.update(env)
        if cwd:
            _msp_os.chdir(cwd)
        _msp_sys.argv = list(parsed["argv"])
        _msp_sys.stdin = _msp_io.TextIOWrapper(
            _msp_io.BytesIO(stdin_data or b""),
            encoding="utf-8",
            errors="surrogateescape",
        )
        _msp_sys.stdout = _msp_io.TextIOWrapper(
            stdout_bytes,
            encoding="utf-8",
            errors="surrogateescape",
            write_through=True,
        )
        _msp_sys.stderr = _msp_io.TextIOWrapper(
            stderr_bytes,
            encoding="utf-8",
            errors="backslashreplace",
            write_through=True,
        )
        _msp_cpython_set_path0("")
        source_bytes = parsed.get("source", b"")
        filename = parsed["filename"]
        if parsed.get("mode") == "script":
            with _msp_builtins.open(parsed["source_path"], "rb") as _msp_nested_script_file:
                source_bytes = _msp_nested_script_file.read()
            _msp_cpython_set_path0(_msp_os.path.dirname(parsed["filename"]) or "")
        try:
            _msp_cpython_exec_user_code(source_bytes, filename)
        except SystemExit as nested_system_exit:
            if nested_system_exit.code is None:
                exit_code = 0
            elif isinstance(nested_system_exit.code, int):
                exit_code = int(nested_system_exit.code)
            else:
                _msp_sys.stderr.write(str(nested_system_exit.code) + "\n")
                exit_code = 1
        except _MSPCPythonUserCodeException as nested_user_code_error:
            _msp_cpython_print_exception(
                nested_user_code_error.exc_type,
                nested_user_code_error.exc_value,
                nested_user_code_error.exc_tb
            )
            exit_code = 1
        except BaseException as nested_error:
            _msp_cpython_print_exception(type(nested_error), nested_error, nested_error.__traceback__)
            exit_code = 1
    finally:
        try:
            if pending_writeback_state is None:
                _msp_vfs_flush_pending_writebacks()
            else:
                _msp_vfs_flush_pending_writebacks(pending_writeback_state)
        except NameError:
            pass
        except BaseException:
            pass
        try:
            _msp_sys.stdout.flush()
            _msp_sys.stderr.flush()
        except BaseException:
            pass
        try:
            captured_stdout_bytes = stdout_bytes.getvalue()
        except BaseException:
            captured_stdout_bytes = b""
        try:
            captured_stderr_bytes = stderr_bytes.getvalue()
        except BaseException:
            captured_stderr_bytes = b""
        _msp_sys.stdin = old_stdin
        _msp_sys.stdout = old_stdout
        _msp_sys.stderr = old_stderr
        _msp_sys.argv = old_argv
        if old_path0 is not None:
            _msp_cpython_set_path0(old_path0)
        _msp_os.environ.clear()
        _msp_os.environ.update(old_environ)
        if old_cwd:
            try:
                _msp_os.chdir(old_cwd)
            except BaseException:
                pass
    return {
        "stdout_b64": _msp_base64.b64encode(captured_stdout_bytes).decode("ascii"),
        "stderr_b64": _msp_base64.b64encode(captured_stderr_bytes).decode("ascii"),
        "exit_code": exit_code,
    }

try:
    _msp_os.environ.clear()
    _msp_os.environ.update(_msp_payload.get("environment", {}))
    _msp_sys.argv = list(_msp_payload["argv"])
    _msp_sys.stdin = _msp_io.TextIOWrapper(
        _msp_cpython_stdin_binary(),
        encoding="utf-8",
        errors="surrogateescape",
    )
    _msp_sys.stdout = _msp_cpython_output_text(
        _msp_stdout_bytes,
        "stdout_fd",
        "utf-8",
        "surrogateescape",
    )
    _msp_sys.stderr = _msp_cpython_output_text(
        _msp_stderr_bytes,
        "stderr_fd",
        "utf-8",
        "backslashreplace",
    )
    if _msp_payload["mode"] == "script":
        _msp_cpython_set_path0(_msp_os.path.dirname(_msp_payload["filename"]) or "")
    else:
        _msp_cpython_set_path0("")

    try:
__MSP_VFS_BOOTSTRAP_SOURCE__

        if _msp_payload["mode"] == "interactive":
            _msp_cpython_run_basic_repl()
        elif _msp_payload["mode"] == "module":
            _msp_runpy.run_module(_msp_payload["module_name"], run_name="__main__", alter_sys=False)
        else:
            _msp_cpython_exec_user_code(
                _msp_base64.b64decode(_msp_payload["source_b64"]),
                _msp_payload["filename"]
            )
    except SystemExit as _msp_system_exit:
        if _msp_system_exit.code is None:
            _msp_exit_code = 0
        elif isinstance(_msp_system_exit.code, int):
            _msp_exit_code = int(_msp_system_exit.code)
        else:
            _msp_sys.stderr.write(str(_msp_system_exit.code) + "\n")
            _msp_exit_code = 1
    except _MSPCPythonUserCodeException as _msp_user_code_error:
        _msp_cpython_print_exception(
            _msp_user_code_error.exc_type,
            _msp_user_code_error.exc_value,
            _msp_user_code_error.exc_tb
        )
        _msp_exit_code = 1
    except BaseException as _msp_error:
        _msp_cpython_print_exception(type(_msp_error), _msp_error, _msp_error.__traceback__)
        _msp_exit_code = 1
finally:
    try:
        _msp_vfs_flush_pending_writebacks()
    except NameError:
        pass
    except BaseException:
        pass
    try:
        _msp_sys.stdout.flush()
        _msp_sys.stderr.flush()
    except BaseException:
        pass
    _msp_final_stdout_bytes = _msp_stdout_bytes.getvalue()
    _msp_final_stderr_bytes = _msp_stderr_bytes.getvalue()
    try:
        _msp_final_stdout_bytes = _msp_vfs_virtualize_bytes(_msp_final_stdout_bytes)
        _msp_final_stderr_bytes = _msp_vfs_virtualize_bytes(_msp_final_stderr_bytes)
    except NameError:
        pass
    except BaseException:
        pass
    _msp_result = {
        "stdout_b64": _msp_base64.b64encode(_msp_final_stdout_bytes).decode("ascii"),
        "stderr_b64": _msp_base64.b64encode(_msp_final_stderr_bytes).decode("ascii"),
        "exit_code": _msp_exit_code,
    }
    with _msp_real_open(_msp_payload["result_path"], "w", encoding="utf-8") as _msp_result_file:
        _msp_json.dump(_msp_result, _msp_result_file)
    try:
        _msp_restore_python_vfs()
    except NameError:
        pass
    except BaseException:
        pass
    _msp_sys.stdin = _msp_old_stdin
    _msp_sys.stdout = _msp_old_stdout
    _msp_sys.stderr = _msp_old_stderr
    _msp_sys.argv = _msp_old_argv
    if _msp_old_path0 is not None:
        _msp_cpython_set_path0(_msp_old_path0)
    _msp_os.environ.clear()
    _msp_os.environ.update(_msp_old_environ)
"""#
        .replacingOccurrences(of: "__MSP_PAYLOAD_B64__", with: payloadB64)
        .replacingOccurrences(of: "__MSP_VFS_BOOTSTRAP_SOURCE__", with: vfsBootstrapSource)
        let bodyB64 = Data(body.utf8).base64EncodedString()
        return #"""
import base64 as _msp_cpython_bootstrap_base64
_msp_cpython_bootstrap_source = _msp_cpython_bootstrap_base64.b64decode("__MSP_BOOTSTRAP_BODY_B64__").decode("utf-8")
_msp_cpython_bootstrap_globals = {
    "__name__": "__msp_cpython_execution__",
    "__builtins__": __builtins__,
}
exec(
    compile(_msp_cpython_bootstrap_source, "<msp-cpython-bootstrap>", "exec"),
    _msp_cpython_bootstrap_globals,
    _msp_cpython_bootstrap_globals,
)
"""#
        .replacingOccurrences(of: "__MSP_BOOTSTRAP_BODY_B64__", with: bodyB64)
    }

    private static func indentedSource(_ source: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
