enum MSPPythonVFSBootstrapTracebackSource {
    static let source = #"""
def _msp_vfs_virtualize_traceback_lines(lines):
    if isinstance(lines, str):
        return _msp_vfs_virtualize_text(lines)
    return [_msp_vfs_virtualize_text(line) for line in lines]

def _msp_vfs_traceback_frame_is_internal(frame):
    filename = _msp_vfs_virtualize_text(getattr(frame, "filename", "") or "")
    name = getattr(frame, "name", "") or ""
    basename = _msp_vfs_os.path.basename(filename)
    return (
        basename == "msp-python-launcher.py"
        or name.startswith("_msp_vfs_")
        or name.startswith("_msp_launcher_")
        or name.startswith("_msp_cpython_")
    )

def _msp_vfs_format_exception_filtered(exc_type, exc_value, exc_tb, limit=None, chain=True):
    lines = []
    if exc_tb is not None:
        frames = [
            frame for frame in _msp_vfs_traceback.extract_tb(exc_tb, limit=limit)
            if not _msp_vfs_traceback_frame_is_internal(frame)
        ]
        if frames:
            lines.append("Traceback (most recent call last):\n")
            lines.extend(_MSP_VFS_REAL_TRACEBACK_FORMAT_LIST(frames))
    lines.extend(_MSP_VFS_REAL_TRACEBACK_FORMAT_EXCEPTION_ONLY(exc_type, exc_value))
    return _msp_vfs_virtualize_traceback_lines(lines)

def _msp_vfs_parse_traceback_exception_args(args, kwargs):
    limit = kwargs.get("limit", None)
    chain = kwargs.get("chain", True)
    if len(args) >= 4:
        limit = args[3]
    if len(args) >= 5:
        chain = args[4]
    if len(args) >= 3 or (args and isinstance(args[0], type)):
        exc_type = args[0] if args else kwargs.get("exc")
        exc_value = args[1] if len(args) >= 2 else kwargs.get("value")
        exc_tb = args[2] if len(args) >= 3 else kwargs.get("tb")
        if exc_type is None and exc_value is not None:
            exc_type = type(exc_value)
        return exc_type, exc_value, exc_tb, limit, chain
    if args:
        exc_value = args[0]
        return type(exc_value), exc_value, getattr(exc_value, "__traceback__", None), limit, chain
    exc_type, exc_value, exc_tb = _msp_vfs_sys.exc_info()
    return exc_type, exc_value, exc_tb, limit, chain

def _msp_vfs_traceback_format_exception(*args, **kwargs):
    try:
        exc_type, exc_value, exc_tb, limit, chain = _msp_vfs_parse_traceback_exception_args(args, kwargs)
        if exc_type is not None:
            return _msp_vfs_format_exception_filtered(exc_type, exc_value, exc_tb, limit, chain)
    except Exception:
        pass
    return _msp_vfs_virtualize_traceback_lines(_MSP_VFS_REAL_TRACEBACK_FORMAT_EXCEPTION(*args, **kwargs))

def _msp_vfs_traceback_format_exception_only(*args, **kwargs):
    return _msp_vfs_virtualize_traceback_lines(
        _MSP_VFS_REAL_TRACEBACK_FORMAT_EXCEPTION_ONLY(*args, **kwargs)
    )

def _msp_vfs_traceback_format_exc(*args, **kwargs):
    try:
        exc_type, exc_value, exc_tb = _msp_vfs_sys.exc_info()
        limit = args[0] if args else kwargs.get("limit", None)
        chain = kwargs.get("chain", True)
        if exc_type is not None:
            return "".join(_msp_vfs_format_exception_filtered(exc_type, exc_value, exc_tb, limit, chain))
    except Exception:
        pass
    return _msp_vfs_virtualize_text(_MSP_VFS_REAL_TRACEBACK_FORMAT_EXC(*args, **kwargs))

def _msp_vfs_traceback_format_list(*args, **kwargs):
    return _msp_vfs_virtualize_traceback_lines(
        _MSP_VFS_REAL_TRACEBACK_FORMAT_LIST(*args, **kwargs)
    )

def _msp_vfs_traceback_format_stack(*args, **kwargs):
    return _msp_vfs_virtualize_traceback_lines(
        _MSP_VFS_REAL_TRACEBACK_FORMAT_STACK(*args, **kwargs)
    )

def _msp_vfs_traceback_format_tb(*args, **kwargs):
    try:
        tb = args[0] if args else kwargs.get("tb")
        limit = args[1] if len(args) > 1 else kwargs.get("limit", None)
        frames = [
            frame for frame in _msp_vfs_traceback.extract_tb(tb, limit=limit)
            if not _msp_vfs_traceback_frame_is_internal(frame)
        ]
        return _msp_vfs_virtualize_traceback_lines(_MSP_VFS_REAL_TRACEBACK_FORMAT_LIST(frames))
    except Exception:
        return _msp_vfs_virtualize_traceback_lines(_MSP_VFS_REAL_TRACEBACK_FORMAT_TB(*args, **kwargs))
"""#
}
