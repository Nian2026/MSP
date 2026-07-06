enum MSPPythonVFSBootstrapSubprocessPipesSource {
    static let source = #"""
class _MSPPythonPipeMetadata:
    def _init_pipe_metadata(self, process, mode, readable, writable, write_through=False):
        self._process = process
        self._pipe_mode = mode
        self._pipe_readable = bool(readable)
        self._pipe_writable = bool(writable)
        self._pipe_write_through = bool(write_through)
        self._pipe_name = _msp_vfs_next_pipe_fd()

    @property
    def name(self):
        return self._pipe_name

    @property
    def mode(self):
        if self._process._text_mode:
            raise AttributeError("mode")
        return self._pipe_mode

    @property
    def encoding(self):
        if not self._process._text_mode:
            raise AttributeError("encoding")
        return self._process.encoding

    @property
    def errors(self):
        if not self._process._text_mode:
            raise AttributeError("errors")
        return self._process.errors or "strict"

    @property
    def newlines(self):
        if not self._process._text_mode:
            raise AttributeError("newlines")
        return None

    @property
    def line_buffering(self):
        if not self._process._text_mode:
            raise AttributeError("line_buffering")
        return False

    @property
    def write_through(self):
        if not self._process._text_mode:
            raise AttributeError("write_through")
        return self._pipe_write_through

    def readable(self):
        if self.closed and self._pipe_readable:
            raise ValueError("I/O operation on closed file")
        return self._pipe_readable

    def writable(self):
        if self.closed and self._pipe_writable:
            raise ValueError("I/O operation on closed file")
        return self._pipe_writable

    def seekable(self):
        if self.closed:
            raise ValueError("I/O operation on closed file")
        return False

    def isatty(self):
        if self.closed:
            raise ValueError("I/O operation on closed file")
        return False

    def fileno(self):
        if self.closed:
            raise ValueError("I/O operation on closed file")
        return self._pipe_name

    def __enter__(self):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()
        return False

class _MSPPythonInputPipe(_MSPPythonPipeMetadata):
    def __init__(self, process):
        self._init_pipe_metadata(process, "wb", readable=False, writable=True, write_through=True)
        self.closed = False

    def write(self, data):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        payload = _msp_vfs_subprocess_bytes(
            data,
            self._process._text_mode,
            self._process._encoding,
            self._process._errors
        )
        _msp_vfs_subprocess_session_request("write", self._process._session_id, stdin_data=payload)
        return len(data)

    def flush(self):
        if self.closed:
            raise ValueError("I/O operation on closed file.")

    def close(self):
        if self.closed:
            return
        self.closed = True
        _msp_vfs_subprocess_session_request("closeStdin", self._process._session_id)

class _MSPPythonOutputPipe(_MSPPythonPipeMetadata):
    def __init__(self, process, stream):
        self._init_pipe_metadata(process, "rb", readable=True, writable=False)
        self._stream = stream
        self._buffer = b""
        self.closed = False

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if line == "" or line == b"":
            raise StopIteration
        return line

    def close(self):
        if self.closed:
            return
        self.closed = True
        session_id = getattr(self._process, "_session_id", None)
        if session_id:
            _msp_vfs_subprocess_session_request("closeOutput", session_id, stream=self._stream)

    def read(self, size=-1):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        if size is None:
            size = -1
        if size < 0:
            chunks = [self._buffer]
            self._buffer = b""
            while True:
                data = self._read_bridge(-1)
                if not data:
                    break
                chunks.append(data)
            return self._process._decode_pipe_value(b"".join(chunks))
        while len(self._buffer) < size:
            data = self._read_bridge(size - len(self._buffer))
            if not data:
                break
            self._buffer += data
        result = self._buffer[:size]
        self._buffer = self._buffer[size:]
        return self._process._decode_pipe_value(result)

    def readline(self, size=-1):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        if size == 0:
            return self._process._decode_pipe_value(b"")
        while b"\n" not in self._buffer and (size is None or size < 0 or len(self._buffer) < size):
            read_size = 1 if size is None or size < 0 else max(1, min(1, size - len(self._buffer)))
            data = self._read_bridge(read_size)
            if not data:
                break
            self._buffer += data
        if size is not None and size >= 0:
            limit = min(size, len(self._buffer))
        elif b"\n" in self._buffer:
            limit = self._buffer.index(b"\n") + 1
        else:
            limit = len(self._buffer)
        result = self._buffer[:limit]
        self._buffer = self._buffer[limit:]
        return self._process._decode_pipe_value(result)

    def readlines(self, hint=-1):
        data = self.read()
        return data.splitlines(True)

    def _read_bridge(self, max_bytes):
        response = _msp_vfs_subprocess_session_request(
            "read",
            self._process._session_id,
            stream=self._stream,
            max_bytes=max_bytes
        )
        return _msp_vfs_base64.b64decode((response.get("data_b64") or "").encode("ascii"))

class _MSPPythonMemoryOutputPipe(_MSPPythonPipeMetadata):
    def __init__(self, process, data):
        self._init_pipe_metadata(process, "rb", readable=True, writable=False)
        self._buffer = bytes(data or b"")
        self.closed = False

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if line == "" or line == b"":
            raise StopIteration
        return line

    def close(self):
        self.closed = True

    def read(self, size=-1):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        if size is None or size < 0:
            result = self._buffer
            self._buffer = b""
            return self._process._decode_pipe_value(result)
        result = self._buffer[:size]
        self._buffer = self._buffer[size:]
        return self._process._decode_pipe_value(result)

    def readline(self, size=-1):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        if size == 0:
            return self._process._decode_pipe_value(b"")
        if b"\n" in self._buffer:
            limit = self._buffer.index(b"\n") + 1
        else:
            limit = len(self._buffer)
        if size is not None and size >= 0:
            limit = min(limit, size)
        result = self._buffer[:limit]
        self._buffer = self._buffer[limit:]
        return self._process._decode_pipe_value(result)

    def readlines(self, hint=-1):
        data = self.read()
        return data.splitlines(True)

class _MSPPythonDeferredInputPipe(_MSPPythonPipeMetadata):
    def __init__(self, process):
        self._init_pipe_metadata(process, "wb", readable=False, writable=True, write_through=True)
        self._buffer = bytearray()
        self.closed = False

    def write(self, value):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        data = self._process._encode_pipe_value(value)
        self._buffer.extend(data)
        try:
            return len(value)
        except BaseException:
            return len(data)

    def flush(self):
        return None

    def close(self):
        self.closed = True

    def getvalue(self):
        return bytes(self._buffer)

class _MSPPythonDeferredOutputPipe(_MSPPythonPipeMetadata):
    def __init__(self, process, stream):
        self._init_pipe_metadata(process, "rb", readable=True, writable=False)
        self._stream = stream
        self.closed = False

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if line == "" or line == b"":
            raise StopIteration
        return line

    def close(self):
        self.closed = True
        pipe = getattr(self._process, self._stream, None)
        if pipe is not None and pipe is not self:
            pipe.close()

    def _materialized_pipe(self):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        self._process._run_deferred_nested_python()
        pipe = getattr(self._process, self._stream, None)
        if pipe is self or pipe is None:
            return _MSPPythonMemoryOutputPipe(self._process, b"")
        return pipe

    def read(self, size=-1):
        return self._materialized_pipe().read(size)

    def readline(self, size=-1):
        return self._materialized_pipe().readline(size)

    def readlines(self, hint=-1):
        return self._materialized_pipe().readlines(hint)
"""#
}
