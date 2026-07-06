enum MSPPythonVFSBootstrapPathConversionSource {
    static let source = #"""
def _msp_vfs_virtualize_real_path(value):
    try:
        raw = _msp_vfs_path_text(value)
    except TypeError:
        return value
    if not isinstance(raw, str):
        return value
    absolute = _msp_vfs_os.path.normpath(_MSP_VFS_REAL_PATH_ABSPATH(raw))
    if absolute in _MSP_VFS_REAL_TO_VIRTUAL:
        return _MSP_VFS_REAL_TO_VIRTUAL[absolute]
    for real_path, virtual_path in sorted(_MSP_VFS_REAL_TO_VIRTUAL.items(), key=lambda item: len(item[0]), reverse=True):
        if _msp_vfs_under(absolute, real_path):
            suffix = _msp_vfs_raw_relpath(absolute, real_path)
            return virtual_path if suffix == "." else _msp_vfs_os.path.normpath(virtual_path.rstrip("/") + "/" + suffix)
    if _MSP_VFS_WORKSPACE_ROOT and _msp_vfs_under(absolute, _MSP_VFS_WORKSPACE_ROOT):
        rel = _msp_vfs_raw_relpath(absolute, _MSP_VFS_WORKSPACE_ROOT)
        return "/" if rel == "." else "/" + rel.replace(_msp_vfs_os.sep, "/")
    return raw

def _msp_vfs_raw_relpath(path, start):
    path_text = _msp_vfs_os.path.normpath(str(path or "."))
    start_text = _msp_vfs_os.path.normpath(str(start or "."))
    path_parts = [part for part in path_text.split(_msp_vfs_os.sep) if part]
    start_parts = [part for part in start_text.split(_msp_vfs_os.sep) if part]
    index = 0
    limit = min(len(path_parts), len(start_parts))
    while index < limit and path_parts[index] == start_parts[index]:
        index += 1
    result_parts = [".."] * (len(start_parts) - index) + path_parts[index:]
    return _msp_vfs_os.path.join(*result_parts) if result_parts else "."

def _msp_vfs_virtualize_text(text):
    if not isinstance(text, str):
        return text
    result = text
    for real_path, virtual_path in sorted(_MSP_VFS_RUNTIME_REAL_TO_VIRTUAL.items(), key=lambda item: len(item[0]), reverse=True):
        result = result.replace(real_path, virtual_path)
    for real_path, virtual_path in sorted(_MSP_VFS_REAL_TO_VIRTUAL.items(), key=lambda item: len(item[0]), reverse=True):
        result = result.replace(real_path, virtual_path)
    if _MSP_VFS_WORKSPACE_ROOT:
        result = result.replace(_MSP_VFS_WORKSPACE_ROOT.rstrip(_msp_vfs_os.sep) + _msp_vfs_os.sep, "/")
        result = result.replace(_MSP_VFS_WORKSPACE_ROOT, "/")
    if _MSP_VFS_MATERIALIZED_DIR:
        result = result.replace(_MSP_VFS_MATERIALIZED_DIR, "/tmp")
    if _MSP_VFS_BROKER_DIR:
        result = result.replace(_MSP_VFS_BROKER_DIR, "/tmp")
    if _MSP_VFS_SUBPROCESS_BROKER_DIR:
        result = result.replace(_MSP_VFS_SUBPROCESS_BROKER_DIR, "/tmp")
    if _MSP_VFS_RESULT_PATH:
        result = result.replace(_msp_vfs_os.path.dirname(_MSP_VFS_RESULT_PATH), "/tmp")
    return result

def _msp_vfs_virtualize_bytes(data):
    try:
        return _msp_vfs_virtualize_text(data.decode("utf-8", "surrogateescape")).encode("utf-8", "surrogateescape")
    except Exception:
        return data

def _msp_vfs_is_bytes_path(value):
    try:
        raw = _msp_vfs_os.fspath(value)
    except TypeError:
        return False
    return isinstance(raw, bytes)

def _msp_vfs_path_text(value):
    raw = _msp_vfs_os.fspath(value)
    if isinstance(raw, bytes):
        return _msp_vfs_os.fsdecode(raw)
    return raw

def _msp_vfs_path_result(value, result):
    if _msp_vfs_is_bytes_path(value) and isinstance(result, str):
        return _msp_vfs_os.fsencode(result)
    return result

def _msp_vfs_reraise_path_error(error, path, destination=None, force=False):
    if not isinstance(error, OSError):
        raise error
    should_rebuild = force or destination is not None or _msp_vfs_is_bytes_path(path)
    should_rebuild = should_rebuild or (destination is not None and _msp_vfs_is_bytes_path(destination))
    if not should_rebuild:
        raise error
    filename = _msp_vfs_os.fspath(path)
    if destination is not None:
        filename2 = _msp_vfs_os.fspath(destination)
    else:
        filename2 = getattr(error, "filename2", None)
    message = getattr(error, "strerror", None) or str(error)
    args = (error.errno, message, filename, None, filename2) if filename2 is not None else (error.errno, message, filename)
    if isinstance(error, FileNotFoundError):
        rebuilt = FileNotFoundError(*args)
    elif isinstance(error, FileExistsError):
        rebuilt = FileExistsError(*args)
    elif isinstance(error, NotADirectoryError):
        rebuilt = NotADirectoryError(*args)
    elif isinstance(error, IsADirectoryError):
        rebuilt = IsADirectoryError(*args)
    elif isinstance(error, PermissionError):
        rebuilt = PermissionError(*args)
    else:
        rebuilt = OSError(*args)
    raise rebuilt

def _msp_vfs_absolute_virtual_path(value):
    raw = _msp_vfs_path_text(value)
    if not isinstance(raw, str):
        return raw
    virtualized = _msp_vfs_virtualize_real_path(raw)
    if isinstance(virtualized, str) and virtualized.startswith("/"):
        return _msp_vfs_os.path.normpath(virtualized)
    if _msp_vfs_os.path.isabs(raw):
        return _msp_vfs_os.path.normpath(raw)
    return _msp_vfs_os.path.normpath(_msp_vfs_os.path.join(_MSP_VFS_VIRTUAL_CWD, raw))

def _msp_vfs_dir_fd_base(dir_fd):
    if dir_fd is None:
        return None
    base = _MSP_VFS_DIR_FDS.get(dir_fd)
    if base is None:
        raise OSError(_msp_vfs_errno.EBADF, "Bad file descriptor")
    return base

def _msp_vfs_virtual_path(value, dir_fd=None):
    raw = _msp_vfs_path_text(value)
    if isinstance(raw, str) and dir_fd is not None and not _msp_vfs_os.path.isabs(raw):
        base = _msp_vfs_dir_fd_base(dir_fd)
        return _msp_vfs_os.path.normpath(_msp_vfs_os.path.join(base, raw))
    return _msp_vfs_absolute_virtual_path(value)

def _msp_vfs_pop_dir_fd(kwargs, name="dir_fd"):
    if name in kwargs:
        return kwargs.pop(name)
    return None
"""#
}
