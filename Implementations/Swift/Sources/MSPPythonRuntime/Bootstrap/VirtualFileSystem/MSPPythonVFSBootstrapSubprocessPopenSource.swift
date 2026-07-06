enum MSPPythonVFSBootstrapSubprocessPopenSource {
    static let source = #"""
class _MSPPythonPopen:
    def __init__(self, args, *popenargs, **kwargs):
        if popenargs:
            raise TypeError("bufsize must be an integer")
        self.args = args
        self.pid = _msp_vfs_next_popen_pid()
        self._kwargs = self._normalized_kwargs(kwargs)
        self.returncode = None
        self._stdout_mode = self._kwargs.get("stdout")
        self._stderr_mode = self._kwargs.get("stderr")
        self._stdin_mode = self._kwargs.get("stdin")
        _msp_vfs_subprocess_validate_stdout_target(self._stdout_mode)
        _msp_vfs_subprocess_validate_stderr_target(self._stderr_mode)
        self._stdout_stream_target = _msp_vfs_subprocess_capture_stream_target(self._stdout_mode)
        self._stderr_stream_target = _msp_vfs_subprocess_capture_stream_target(self._stderr_mode)
        self._stdout_delivered = False
        self._stderr_delivered = False
        self._communicate_result = None
        self._shell = bool(self._kwargs.get("shell", False))
        self._cwd = self._kwargs.get("cwd")
        self._env = self._kwargs.get("env")
        self.text_mode, self.encoding, self.errors = _msp_vfs_subprocess_text_settings(
            self._kwargs.get("text"),
            self._kwargs.get("universal_newlines"),
            self._kwargs.get("encoding"),
            self._kwargs.get("errors")
        )
        self._text_mode = self.text_mode
        self._encoding = self.encoding
        self._errors = self.errors
        if self._stdin_mode == _msp_vfs_subprocess.DEVNULL:
            stdin_data = b""
        elif self._stdin_mode not in (None, _msp_vfs_subprocess.PIPE):
            stdin_data = _msp_vfs_subprocess_readable_stdin_data(
                self._stdin_mode,
                self._text_mode,
                self._encoding,
                self._errors
            )
        else:
            stdin_data = None
        command_line = _msp_vfs_subprocess_command_line(args, self._shell, self._kwargs.get("executable"))
        self._deferred_nested_python = False
        self._nested_command_line = command_line
        response = None
        if self._stdin_mode != _msp_vfs_subprocess.PIPE:
            response = _msp_vfs_nested_python_response(args, self._shell, command_line, stdin_data or b"", self._cwd, self._env)
        if response is not None:
            self._session_id = None
            stdout_bytes = _msp_vfs_base64.b64decode(response.get("stdout_b64", ""))
            stderr_bytes = _msp_vfs_base64.b64decode(response.get("stderr_b64", ""))
            if self._stderr_mode == _msp_vfs_subprocess.STDOUT:
                stdout_bytes = stdout_bytes + stderr_bytes
                stderr_bytes = b""
            self.returncode = int(response.get("exit_code", 0))
            self.stdin = None
            self.stdout = _MSPPythonMemoryOutputPipe(self, stdout_bytes) if self._stdout_mode == _msp_vfs_subprocess.PIPE else None
            self.stderr = _MSPPythonMemoryOutputPipe(self, stderr_bytes) if self._stderr_mode == _msp_vfs_subprocess.PIPE else None
            self._deliver_completed_output(stdout_bytes, stderr_bytes)
            return
        if self._stdin_mode == _msp_vfs_subprocess.PIPE and _msp_vfs_can_run_nested_python(args, self._shell, command_line):
            self._session_id = None
            self._deferred_nested_python = True
            self.stdin = _MSPPythonDeferredInputPipe(self)
            self.stdout = _MSPPythonDeferredOutputPipe(self, "stdout") if self._stdout_mode == _msp_vfs_subprocess.PIPE else None
            self.stderr = _MSPPythonDeferredOutputPipe(self, "stderr") if self._stderr_mode == _msp_vfs_subprocess.PIPE else None
            return
        response = _msp_vfs_subprocess_request(
            "start",
            command_line=command_line,
            stdin_data=stdin_data,
            cwd=self._cwd,
            env=self._env,
            stdin_pipe=self._stdin_mode == _msp_vfs_subprocess.PIPE,
            merge_stderr_to_stdout=self._stderr_mode == _msp_vfs_subprocess.STDOUT
        )
        self._session_id = response.get("session_id")
        if not self._session_id:
            raise OSError("subprocess failed to start")
        self.stdin = _MSPPythonInputPipe(self) if self._stdin_mode == _msp_vfs_subprocess.PIPE else None
        self.stdout = _MSPPythonOutputPipe(self, "stdout") if self._stdout_mode == _msp_vfs_subprocess.PIPE else None
        self.stderr = _MSPPythonOutputPipe(self, "stderr") if self._stderr_mode == _msp_vfs_subprocess.PIPE else None

    def _normalized_kwargs(self, kwargs):
        normalized = dict(kwargs)
        unsupported = [
            "preexec_fn", "pass_fds", "startupinfo", "creationflags",
            "start_new_session", "process_group", "user", "group",
            "extra_groups", "umask", "pipesize"
        ]
        for name in unsupported:
            value = normalized.get(name)
            if value not in (None, False, (), -1, 0):
                raise PermissionError(name + " is not available in this subprocess runtime")
            normalized.pop(name, None)
        normalized.pop("close_fds", None)
        normalized.pop("restore_signals", None)
        allowed = {
            "stdin", "stdout", "stderr", "shell", "cwd", "env",
            "text", "encoding", "errors", "universal_newlines", "executable"
        }
        for name in list(normalized):
            if name not in allowed:
                raise TypeError("Popen.__init__() got an unexpected keyword argument '" + name + "'")
        return normalized

    def __repr__(self):
        return "<Popen: returncode: %s args: %r>" % (self.returncode, self.args)

    @property
    def universal_newlines(self):
        return self.text_mode

    @universal_newlines.setter
    def universal_newlines(self, value):
        self.text_mode = value
        self._text_mode = value

    def _decode_pipe_value(self, data):
        if self._text_mode:
            return _msp_vfs_subprocess_text(data, self._encoding, self._errors)
        return data

    def _encode_pipe_value(self, value):
        return _msp_vfs_subprocess_bytes(value, self._text_mode, self._encoding, self._errors)

    def _decode_response_stdout_stderr(self, response):
        return (
            _msp_vfs_base64.b64decode((response.get("stdout_b64") or "").encode("ascii")),
            _msp_vfs_base64.b64decode((response.get("stderr_b64") or "").encode("ascii")),
        )

    def _deliver_completed_output(self, stdout_bytes, stderr_bytes):
        if not self._stdout_delivered:
            if self._stdout_mode is None:
                if stdout_bytes:
                    _msp_vfs_sys.stdout.write(_msp_vfs_subprocess_display_text(stdout_bytes, self._encoding, self._errors))
                self._stdout_delivered = True
            elif self._stdout_stream_target is not None:
                try:
                    _msp_vfs_subprocess_write_stream_target(self._stdout_stream_target, stdout_bytes, self._encoding, self._errors)
                finally:
                    self._stdout_stream_target.close()
                    self._stdout_delivered = True
            elif self._stdout_mode is _msp_vfs_subprocess.DEVNULL:
                self._stdout_delivered = True
        if not self._stderr_delivered:
            if self._stderr_mode is None:
                if stderr_bytes:
                    _msp_vfs_sys.stderr.write(_msp_vfs_subprocess_display_text(stderr_bytes, self._encoding, self._errors))
                self._stderr_delivered = True
            elif self._stderr_stream_target is not None:
                try:
                    _msp_vfs_subprocess_write_stream_target(self._stderr_stream_target, stderr_bytes, self._encoding, self._errors)
                finally:
                    self._stderr_stream_target.close()
                    self._stderr_delivered = True
            elif self._stderr_mode is _msp_vfs_subprocess.DEVNULL or self._stderr_mode is _msp_vfs_subprocess.STDOUT:
                self._stderr_delivered = True

    def _complete_from_nested_python_response(self, response):
        stdout_bytes = _msp_vfs_base64.b64decode(response.get("stdout_b64", ""))
        stderr_bytes = _msp_vfs_base64.b64decode(response.get("stderr_b64", ""))
        if self._stderr_mode == _msp_vfs_subprocess.STDOUT:
            stdout_bytes = stdout_bytes + stderr_bytes
            stderr_bytes = b""
        self.returncode = int(response.get("exit_code", 0))
        self.stdout = _MSPPythonMemoryOutputPipe(self, stdout_bytes) if self._stdout_mode == _msp_vfs_subprocess.PIPE else None
        self.stderr = _MSPPythonMemoryOutputPipe(self, stderr_bytes) if self._stderr_mode == _msp_vfs_subprocess.PIPE else None
        self._deliver_completed_output(stdout_bytes, stderr_bytes)

    def _run_deferred_nested_python(self):
        if not self._deferred_nested_python:
            return
        stdin_data = self.stdin.getvalue() if self.stdin is not None else b""
        response = _msp_vfs_nested_python_response(
            self.args,
            self._shell,
            self._nested_command_line,
            stdin_data,
            self._cwd,
            self._env
        )
        if response is None:
            response = {
                "stdout_b64": "",
                "stderr_b64": _msp_vfs_base64.b64encode(b"python3: nested Python runner is unavailable\n").decode("ascii"),
                "exit_code": 126,
            }
        self._complete_from_nested_python_response(response)
        self._deferred_nested_python = False

    def _close_stdin_for_communicate(self, input):
        if input is not None:
            payload = _msp_vfs_subprocess_bytes(input, self._text_mode, self._encoding, self._errors)
            if self._deferred_nested_python:
                self.stdin.write(input)
                return
            _msp_vfs_subprocess_session_request("write", self._session_id, stdin_data=payload)
        if self.stdin is not None and not self.stdin.closed:
            self.stdin.close()

    def communicate(self, input=None, timeout=None):
        if self._communicate_result is not None:
            return self._communicate_result
        if self._deferred_nested_python:
            self._close_stdin_for_communicate(input)
            self._run_deferred_nested_python()
            stdout_value = self.stdout.read() if self.stdout is not None else None
            stderr_value = self.stderr.read() if self.stderr is not None else None
            self._communicate_result = (stdout_value, stderr_value)
            return self._communicate_result
        if self._session_id is None:
            stdout_value = self.stdout.read() if self.stdout is not None else None
            stderr_value = self.stderr.read() if self.stderr is not None else None
            self._communicate_result = (stdout_value, stderr_value)
            return self._communicate_result
        self._close_stdin_for_communicate(input)
        response = self._wait_response(timeout=timeout, timeout_output=True)
        stdout_bytes, stderr_bytes = self._decode_response_stdout_stderr(response)
        self._deliver_completed_output(stdout_bytes, stderr_bytes)
        stdout_value = None
        stderr_value = None
        if self._stdout_mode == _msp_vfs_subprocess.PIPE:
            stdout_value = self.stdout.read() if self.stdout is not None else self._decode_pipe_value(b"")
        if self._stderr_mode == _msp_vfs_subprocess.STDOUT and self._stdout_mode == _msp_vfs_subprocess.PIPE:
            stdout_value = self._decode_pipe_value(stdout_bytes + stderr_bytes)
            stderr_value = None
        elif self._stderr_mode == _msp_vfs_subprocess.PIPE:
            stderr_value = self.stderr.read() if self.stderr is not None else self._decode_pipe_value(b"")
        self._communicate_result = (stdout_value, stderr_value)
        return self._communicate_result

    def _wait_response(self, timeout=None, timeout_output=False):
        if self._deferred_nested_python:
            self._run_deferred_nested_python()
            return {"exit_code": self.returncode or 0}
        if self._session_id is None:
            return {"exit_code": self.returncode or 0}
        try:
            response = _msp_vfs_subprocess_session_request(
                "wait",
                self._session_id,
                timeout=timeout,
                timeout_output=timeout_output
            )
        except _msp_vfs_subprocess.TimeoutExpired as error:
            timeout_stdout = error.output if timeout_output and self._stdout_mode == _msp_vfs_subprocess.PIPE else None
            timeout_stderr = error.stderr if timeout_output and self._stderr_mode == _msp_vfs_subprocess.PIPE else None
            raise _msp_vfs_subprocess_timeout_error(
                self.args,
                timeout,
                output=timeout_stdout,
                stderr=timeout_stderr
            ) from None
        self.returncode = int(response.get("exit_code", 0))
        stdout_bytes, stderr_bytes = self._decode_response_stdout_stderr(response)
        self._deliver_completed_output(stdout_bytes, stderr_bytes)
        return response

    def wait(self, timeout=None):
        self._wait_response(timeout=timeout)
        return self.returncode

    def poll(self):
        if self._session_id is None:
            return self.returncode
        response = _msp_vfs_subprocess_session_request("poll", self._session_id)
        if response.get("running"):
            return None
        self.returncode = int(response.get("exit_code", 0))
        stdout_bytes, stderr_bytes = self._decode_response_stdout_stderr(response)
        self._deliver_completed_output(stdout_bytes, stderr_bytes)
        return self.returncode

    def kill(self):
        return self.send_signal(_msp_vfs_signal.SIGKILL)

    def terminate(self):
        return self.send_signal(_msp_vfs_signal.SIGTERM)

    def send_signal(self, sig):
        if self.returncode is not None:
            return None
        signal_number = int(sig)
        if signal_number == 0:
            return None
        if self._session_id is None:
            self.returncode = -abs(signal_number)
            self._deferred_nested_python = False
            if self.stdin is not None and not self.stdin.closed:
                self.stdin.close()
            return None
        _msp_vfs_subprocess_session_request("signal", self._session_id, signal_number=signal_number)
        return None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.stdout:
            self.stdout.close()
        if self.stderr:
            self.stderr.close()
        try:
            if self.stdin:
                self.stdin.close()
        finally:
            self.wait()
        return False

    def __del__(self):
        session_id = getattr(self, "_session_id", None)
        if session_id:
            try:
                _msp_vfs_subprocess_session_request("close", session_id)
            except Exception:
                pass
"""#
}
