enum MSPPythonVFSBootstrapSubprocessCoreSource {
    static let source = #"""
import signal as _msp_vfs_signal

_MSP_VFS_POPEN_PID_COUNTER = 10000
_MSP_VFS_PIPE_FD_COUNTER = 20000

def _msp_vfs_next_popen_pid():
    global _MSP_VFS_POPEN_PID_COUNTER
    _MSP_VFS_POPEN_PID_COUNTER += 1
    return _MSP_VFS_POPEN_PID_COUNTER

def _msp_vfs_next_pipe_fd():
    global _MSP_VFS_PIPE_FD_COUNTER
    _MSP_VFS_PIPE_FD_COUNTER += 1
    return _MSP_VFS_PIPE_FD_COUNTER

def _msp_vfs_subprocess_default_text_encoding():
    return "utf-8"

def _msp_vfs_subprocess_is_locale_text_encoding(encoding):
    try:
        return str(encoding).lower() == "locale"
    except Exception:
        return False

def _msp_vfs_subprocess_decode_errors(errors=None):
    return errors if errors is not None else "strict"

def _msp_vfs_subprocess_display_errors(errors=None):
    return errors if errors is not None else "replace"

def _msp_vfs_subprocess_text_settings(text=None, universal_newlines=None, encoding=None, errors=None):
    if (text is not None and universal_newlines is not None and
            bool(universal_newlines) != bool(text)):
        raise _msp_vfs_subprocess.SubprocessError(
            "Cannot disambiguate when both text and universal_newlines are supplied but different. Pass one or the other."
        )
    text_mode = encoding or errors or text or universal_newlines
    if text_mode and (encoding is None or _msp_vfs_subprocess_is_locale_text_encoding(encoding)):
        encoding = _msp_vfs_subprocess_default_text_encoding()
    return text_mode, encoding, errors

def _msp_vfs_subprocess_text_mode(text=None, universal_newlines=None, encoding=None, errors=None):
    return _msp_vfs_subprocess_text_settings(text, universal_newlines, encoding, errors)[0]

def _msp_vfs_subprocess_bytes(value, text_mode, encoding=None, errors=None):
    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return value.encode(encoding or "utf-8", _msp_vfs_subprocess_decode_errors(errors))
    return bytes(value)

def _msp_vfs_subprocess_text(value, encoding=None, errors=None):
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return value.decode(encoding or "utf-8", _msp_vfs_subprocess_decode_errors(errors))

def _msp_vfs_subprocess_display_text(value, encoding=None, errors=None):
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return value.decode(encoding or "utf-8", _msp_vfs_subprocess_display_errors(errors))

def _msp_vfs_subprocess_timeout_error(command, timeout, output=None, stderr=None):
    return _msp_vfs_subprocess.TimeoutExpired(command, timeout, output=output, stderr=stderr)

def _msp_vfs_subprocess_readable_stdin_data(stdin_target, text_mode, encoding=None, errors=None):
    if stdin_target is _msp_vfs_subprocess.STDOUT or isinstance(stdin_target, int):
        raise OSError(9, "Bad file descriptor")
    read = getattr(stdin_target, "read", None)
    if not callable(read):
        raise AttributeError("'" + type(stdin_target).__name__ + "' object has no attribute 'fileno'")
    return _msp_vfs_subprocess_bytes(read(), text_mode, encoding, errors)

def _msp_vfs_subprocess_write_stream_target(stream_target, data, encoding=None, errors=None):
    write_subprocess_data = getattr(stream_target, "write_subprocess_data", None)
    if callable(write_subprocess_data):
        write_subprocess_data(data, encoding=encoding, errors=errors)
        return
    write = getattr(stream_target, "write", None)
    if not callable(write):
        raise ValueError("subprocess stream target must be writable")
    mode = getattr(stream_target, "mode", "")
    if isinstance(mode, str) and "b" in mode:
        value = data
    else:
        value = _msp_vfs_subprocess_text(data, encoding, errors)
    try:
        write(value)
    except TypeError:
        if isinstance(value, bytes):
            write(_msp_vfs_subprocess_text(data, encoding, errors))
        else:
            write(data)
    flush = getattr(stream_target, "flush", None)
    if callable(flush):
        flush()

def _msp_vfs_subprocess_is_writable_stream_target(stream_target):
    return callable(getattr(stream_target, "write", None))

class _MSPPythonSubprocessStreamTarget:
    def __init__(self, stream_target):
        self._stream_target = stream_target
        self._real_path = getattr(stream_target, "_msp_real_path", None)
        self._held_writeback = False
        self._position = None
        self.mode = getattr(stream_target, "mode", "")
        if self._real_path is not None:
            self._real_path = _msp_vfs_os.path.normpath(self._real_path)
        if self._real_path in _MSP_VFS_WRITEBACKS:
            flush = getattr(stream_target, "flush", None)
            if callable(flush):
                flush()
            tell = getattr(stream_target, "tell", None)
            if callable(tell):
                try:
                    self._position = tell()
                except Exception:
                    self._position = None
            _msp_vfs_hold_subprocess_stream_writeback(self._real_path)
            self._held_writeback = True

    def write_subprocess_data(self, data, encoding=None, errors=None):
        if not self._held_writeback:
            _msp_vfs_subprocess_write_stream_target(self._stream_target, data, encoding, errors)
            return
        closed = getattr(self._stream_target, "closed", False)
        if not closed:
            _msp_vfs_subprocess_write_stream_target(self._stream_target, data, encoding, errors)
            flush = getattr(self._stream_target, "flush", None)
            if callable(flush):
                flush()
            _msp_vfs_writeback_snapshot(self._real_path)
            tell = getattr(self._stream_target, "tell", None)
            if callable(tell):
                try:
                    self._position = tell()
                except Exception:
                    pass
            return
        with _MSP_VFS_REAL_OPEN(self._real_path, "r+b") as file:
            if self._position is not None:
                file.seek(self._position)
            else:
                file.seek(0, 2)
            file.write(data)
            self._position = file.tell()
        _msp_vfs_writeback_snapshot(self._real_path)

    def close(self):
        if self._held_writeback:
            self._held_writeback = False
            _msp_vfs_release_subprocess_stream_writeback(self._real_path)

def _msp_vfs_subprocess_capture_stream_target(stream_target):
    if _msp_vfs_subprocess_is_writable_stream_target(stream_target):
        return _MSPPythonSubprocessStreamTarget(stream_target)
    return None

def _msp_vfs_subprocess_validate_stdout_target(stream_target):
    if stream_target is None or stream_target is _msp_vfs_subprocess.PIPE or stream_target is _msp_vfs_subprocess.DEVNULL:
        return
    if stream_target is _msp_vfs_subprocess.STDOUT:
        raise ValueError("STDOUT can only be used for stderr")
    if _msp_vfs_subprocess_is_writable_stream_target(stream_target):
        return
    raise ValueError("subprocess only supports stdout=None, PIPE, DEVNULL, or a writable stream target")

def _msp_vfs_subprocess_validate_stderr_target(stream_target):
    if (stream_target is None or stream_target is _msp_vfs_subprocess.PIPE or
            stream_target is _msp_vfs_subprocess.STDOUT or stream_target is _msp_vfs_subprocess.DEVNULL):
        return
    if _msp_vfs_subprocess_is_writable_stream_target(stream_target):
        return
    raise ValueError("subprocess only supports stderr=None, PIPE, STDOUT, DEVNULL, or a writable stream target")

def _msp_vfs_subprocess_executable_path(executable):
    if executable is None:
        return None
    return _msp_vfs_os.fsdecode(_msp_vfs_os.fspath(executable))

def _msp_vfs_subprocess_shell_parts(args):
    if isinstance(args, str):
        return args, []
    sequence = [str(part) for part in args]
    if not sequence:
        return "", []
    return sequence[0], sequence[1:]

def _msp_vfs_subprocess_command_line(args, shell, executable=None):
    executable = _msp_vfs_subprocess_executable_path(executable)
    if shell:
        command, shell_args = _msp_vfs_subprocess_shell_parts(args)
        if executable or shell_args:
            launcher = executable or "/bin/sh"
            return _msp_vfs_shlex.join([launcher, "-c", command] + shell_args)
        return command
    if isinstance(args, str):
        if executable:
            return _msp_vfs_shlex.join([executable])
        return args
    parts = [str(part) for part in args]
    if executable:
        parts = [executable] + parts[1:]
    return _msp_vfs_shlex.join(parts)

def _msp_vfs_nested_python_response(args, shell, command_line, stdin_data, cwd, env):
    handler = globals().get("_msp_cpython_run_nested_python")
    if not callable(handler):
        return None
    return handler(
        args=args,
        shell=shell,
        command_line=command_line,
        stdin_data=stdin_data or b"",
        cwd=_msp_vfs_absolute_virtual_path(cwd) if cwd else None,
        env=env,
    )

def _msp_vfs_can_run_nested_python(args, shell, command_line):
    parser = globals().get("_msp_cpython_parse_nested_python")
    if not callable(parser):
        return False
    try:
        return parser(args, shell, command_line, b"") is not None
    except BaseException:
        return False

def _msp_vfs_subprocess_request(action, command_line=None, stdin_data=None, cwd=None, env=None, timeout=None,
                                stdin_pipe=False, session_id=None, stream=None, max_bytes=None,
                                merge_stderr_to_stdout=False, signal_number=None):
    if not _MSP_VFS_SUBPROCESS_BROKER_DIR:
        raise RuntimeError("subprocess support is unavailable")
    request_id = _msp_vfs_next_id("subprocess")
    request_path = _msp_vfs_os.path.join(_MSP_VFS_SUBPROCESS_BROKER_DIR, "request-" + request_id + ".json")
    request_tmp_path = request_path + ".tmp"
    response_path = _msp_vfs_os.path.join(_MSP_VFS_SUBPROCESS_BROKER_DIR, "response-" + request_id + ".json")
    request = {
        "id": request_id,
        "action": action,
    }
    if command_line is not None:
        request["command_line"] = command_line
    if stdin_data is not None:
        request["stdin_b64"] = _msp_vfs_base64.b64encode(stdin_data).decode("ascii")
    if cwd is not None or action in ("run", "start"):
        request["cwd"] = _msp_vfs_absolute_virtual_path(cwd) if cwd else _MSP_VFS_VIRTUAL_CWD
    if env is not None or action in ("run", "start"):
        request["environment"] = env if env is not None else dict(_msp_vfs_os.environ)
    if timeout is not None:
        request["timeout"] = timeout
        request["deadline_unix"] = _msp_vfs_time.time() + timeout
    if stdin_pipe:
        request["stdin_pipe"] = True
    if session_id is not None:
        request["session_id"] = session_id
    if stream is not None:
        request["stream"] = stream
    if max_bytes is not None:
        request["max_bytes"] = max_bytes
    if merge_stderr_to_stdout:
        request["merge_stderr_to_stdout"] = True
    if signal_number is not None:
        request["signal_number"] = int(signal_number)
    with _MSP_VFS_REAL_OPEN(request_tmp_path, "w", encoding="utf-8") as request_file:
        _msp_vfs_json.dump(request, request_file, separators=(",", ":"))
    _MSP_VFS_REAL_REPLACE(request_tmp_path, request_path)
    started_at = _msp_vfs_time.monotonic()
    response_timeout = timeout + 0.5 if timeout is not None else None
    while not _MSP_VFS_REAL_PATH_EXISTS(response_path):
        if response_timeout is not None and (_msp_vfs_time.monotonic() - started_at) > response_timeout:
            raise _msp_vfs_subprocess_timeout_error(command_line, timeout)
        _msp_vfs_time.sleep(0.005)
    with _MSP_VFS_REAL_OPEN(response_path, "r", encoding="utf-8") as response_file:
        response = _msp_vfs_json.load(response_file)
    try:
        _MSP_VFS_REAL_REMOVE(response_path)
    except Exception:
        pass
    return response

def _msp_vfs_subprocess_session_request(
        action, session_id, stdin_data=None, timeout=None, stream=None, max_bytes=None,
        timeout_output=False, signal_number=None):
    response = _msp_vfs_subprocess_request(
        action,
        stdin_data=stdin_data,
        timeout=timeout,
        session_id=session_id,
        stream=stream,
        max_bytes=max_bytes,
        signal_number=signal_number
    )
    if response.get("timed_out"):
        output = None
        stderr = None
        if timeout_output:
            output = _msp_vfs_base64.b64decode(response.get("stdout_b64", ""))
            stderr = _msp_vfs_base64.b64decode(response.get("stderr_b64", ""))
        raise _msp_vfs_subprocess_timeout_error(session_id, timeout, output=output, stderr=stderr)
    return response
"""#
}
