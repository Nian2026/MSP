enum MSPPythonVFSBootstrapSubprocessRunSource {
    static let source = #"""
def _msp_vfs_subprocess_run(args, input=None, capture_output=False, timeout=None, check=False, **kwargs):
    shell = bool(kwargs.pop("shell", False))
    text = kwargs.pop("text", None)
    universal_newlines = kwargs.pop("universal_newlines", None)
    encoding = kwargs.pop("encoding", None)
    errors = kwargs.pop("errors", None)
    text_mode, encoding, errors = _msp_vfs_subprocess_text_settings(text, universal_newlines, encoding, errors)
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
        stdout_target = _msp_vfs_subprocess.PIPE
        stderr_target = _msp_vfs_subprocess.PIPE
    _msp_vfs_subprocess_validate_stdout_target(stdout_target)
    _msp_vfs_subprocess_validate_stderr_target(stderr_target)
    if input is not None and stdin_target is not None:
        raise ValueError("stdin and input arguments may not both be used.")
    if stdin_target in (None, _msp_vfs_subprocess.PIPE):
        stdin_data = _msp_vfs_subprocess_bytes(input, text_mode, encoding, errors)
    elif stdin_target == _msp_vfs_subprocess.DEVNULL:
        stdin_data = b""
    else:
        stdin_data = _msp_vfs_subprocess_readable_stdin_data(stdin_target, text_mode, encoding, errors)
    command_line = _msp_vfs_subprocess_command_line(args, shell, executable)
    response = _msp_vfs_nested_python_response(args, shell, command_line, stdin_data, cwd, env)
    if response is None:
        try:
            response = _msp_vfs_subprocess_request(
                "run",
                command_line=command_line,
                stdin_data=stdin_data,
                cwd=cwd,
                env=env,
                timeout=timeout,
                merge_stderr_to_stdout=stderr_target is _msp_vfs_subprocess.STDOUT
            )
        except _msp_vfs_subprocess.TimeoutExpired:
            raise _msp_vfs_subprocess_timeout_error(args, timeout) from None
    if response.get("timed_out"):
        stdout_bytes = _msp_vfs_base64.b64decode(response.get("stdout_b64", ""))
        stderr_bytes = _msp_vfs_base64.b64decode(response.get("stderr_b64", ""))
        if stderr_target is _msp_vfs_subprocess.STDOUT:
            stdout_bytes = stdout_bytes + stderr_bytes
            stderr_bytes = b""
        timeout_output = stdout_bytes if stdout_target is _msp_vfs_subprocess.PIPE else None
        timeout_stderr = stderr_bytes if stderr_target is _msp_vfs_subprocess.PIPE else None
        if stdout_target is None:
            if stdout_bytes:
                _msp_vfs_sys.stdout.write(_msp_vfs_subprocess_display_text(stdout_bytes, encoding, errors))
        elif callable(getattr(stdout_target, "write", None)):
            _msp_vfs_subprocess_write_stream_target(stdout_target, stdout_bytes, encoding, errors)
        if stderr_target is None:
            if stderr_bytes:
                _msp_vfs_sys.stderr.write(_msp_vfs_subprocess_display_text(stderr_bytes, encoding, errors))
        elif callable(getattr(stderr_target, "write", None)) and stderr_target is not _msp_vfs_subprocess.STDOUT:
            _msp_vfs_subprocess_write_stream_target(stderr_target, stderr_bytes, encoding, errors)
        raise _msp_vfs_subprocess_timeout_error(args, timeout, output=timeout_output, stderr=timeout_stderr)
    stdout_bytes = _msp_vfs_base64.b64decode(response.get("stdout_b64", ""))
    stderr_bytes = _msp_vfs_base64.b64decode(response.get("stderr_b64", ""))
    if stderr_target is _msp_vfs_subprocess.STDOUT:
        stdout_bytes = stdout_bytes + stderr_bytes
        stderr_bytes = b""
    stdout_value = _msp_vfs_subprocess_text(stdout_bytes, encoding, errors) if text_mode else stdout_bytes
    stderr_value = _msp_vfs_subprocess_text(stderr_bytes, encoding, errors) if text_mode else stderr_bytes
    if stdout_target is None:
        if stdout_bytes:
            _msp_vfs_sys.stdout.write(_msp_vfs_subprocess_display_text(stdout_bytes, encoding, errors))
        completed_stdout = None
    elif stdout_target is _msp_vfs_subprocess.DEVNULL:
        completed_stdout = None
    elif stdout_target is _msp_vfs_subprocess.PIPE:
        completed_stdout = stdout_value
    elif callable(getattr(stdout_target, "write", None)):
        _msp_vfs_subprocess_write_stream_target(stdout_target, stdout_bytes, encoding, errors)
        completed_stdout = None
    else:
        raise ValueError("subprocess only supports stdout=None, PIPE, DEVNULL, or a writable stream target")
    if stderr_target is None:
        if stderr_bytes:
            _msp_vfs_sys.stderr.write(_msp_vfs_subprocess_display_text(stderr_bytes, encoding, errors))
        completed_stderr = None
    elif stderr_target in (_msp_vfs_subprocess.DEVNULL, _msp_vfs_subprocess.STDOUT):
        completed_stderr = None
    elif stderr_target is _msp_vfs_subprocess.PIPE:
        completed_stderr = stderr_value
    elif callable(getattr(stderr_target, "write", None)):
        _msp_vfs_subprocess_write_stream_target(stderr_target, stderr_bytes, encoding, errors)
        completed_stderr = None
    else:
        raise ValueError("subprocess only supports stderr=None, PIPE, STDOUT, DEVNULL, or a writable stream target")
    completed = _msp_vfs_subprocess.CompletedProcess(
        args,
        int(response.get("exit_code", 1)),
        completed_stdout,
        completed_stderr,
    )
    if check:
        completed.check_returncode()
    return completed

def _msp_vfs_subprocess_check_output(*popenargs, timeout=None, **kwargs):
    if "stdout" in kwargs:
        raise ValueError("stdout argument not allowed, it will be overridden.")
    kwargs["stdout"] = _msp_vfs_subprocess.PIPE
    kwargs.setdefault("check", True)
    return _msp_vfs_subprocess_run(*popenargs, timeout=timeout, **kwargs).stdout

def _msp_vfs_subprocess_call(*popenargs, timeout=None, **kwargs):
    return _msp_vfs_subprocess_run(*popenargs, timeout=timeout, **kwargs).returncode

def _msp_vfs_subprocess_check_call(*popenargs, timeout=None, **kwargs):
    return _msp_vfs_subprocess_run(*popenargs, timeout=timeout, check=True, **kwargs).returncode
"""#
}
