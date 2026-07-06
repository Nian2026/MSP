enum MSPPythonVFSBootstrapFileMaterializationSource {
    static let source = #"""
def _msp_vfs_existing_bytes(virtual_path):
    real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
    if real_path is not None:
        with _MSP_VFS_REAL_OPEN(real_path, "rb") as materialized:
            return materialized.read()
    try:
        response = _msp_vfs_request("read_file", path=virtual_path)
        return _msp_vfs_base64.b64decode(response.get("data_b64", ""))
    except FileNotFoundError:
        return None

def _msp_vfs_real_is_dir(path):
    try:
        return _msp_vfs_stat.S_ISDIR(_MSP_VFS_REAL_STAT(path).st_mode)
    except Exception:
        return False

def _msp_vfs_real_makedirs(path, mode=0o777, exist_ok=False):
    normalized = _msp_vfs_os.path.normpath(path)
    if _MSP_VFS_REAL_PATH_EXISTS(normalized):
        if exist_ok and _msp_vfs_real_is_dir(normalized):
            return
        raise FileExistsError(_msp_vfs_errno.EEXIST, "File exists", normalized)
    parent = _msp_vfs_os.path.dirname(normalized)
    if parent and parent != normalized and not _MSP_VFS_REAL_PATH_EXISTS(parent):
        _msp_vfs_real_makedirs(parent, mode=mode, exist_ok=True)
    try:
        _MSP_VFS_REAL_MKDIR(normalized, mode)
    except FileExistsError:
        if not (exist_ok and _msp_vfs_real_is_dir(normalized)):
            raise

def _msp_vfs_materialize(virtual_path, mode="r", flags=None, creation_mode_base=0o666):
    writes = _msp_vfs_flags_write(flags) if flags is not None else _msp_vfs_mode_writes(mode)
    text_mode = "r" if mode is None else str(mode)
    exclusive = "x" in text_mode or (flags is not None and int(flags) & getattr(_msp_vfs_os, "O_EXCL", 0))
    existing = None if ("w" in text_mode and "+" not in text_mode) else _msp_vfs_existing_bytes(virtual_path)
    if exclusive and existing is not None:
        raise FileExistsError(_msp_vfs_errno.EEXIST, "workspace path already exists", virtual_path)
    created = existing is None
    if existing is None:
        if not writes:
            _msp_vfs_request("read_file", path=virtual_path)
        existing = b""
    if not _MSP_VFS_MATERIALIZED_DIR:
        raise PermissionError("MSP Python materialized file directory is unavailable")
    _msp_vfs_real_makedirs(_MSP_VFS_MATERIALIZED_DIR, exist_ok=True)
    suffix = _msp_vfs_os.path.basename(virtual_path.rstrip("/")) or "file"
    real_path = _msp_vfs_os.path.join(_MSP_VFS_MATERIALIZED_DIR, _msp_vfs_next_id("materialized") + "-" + suffix)
    real_path = _msp_vfs_os.path.normpath(real_path)
    if not (exclusive and created and writes):
        with _MSP_VFS_REAL_OPEN(real_path, "wb") as materialized:
            materialized.write(existing)
    _MSP_VFS_REAL_TO_VIRTUAL[real_path] = virtual_path
    if writes:
        creation_mode = _msp_vfs_apply_umask(creation_mode_base) if created else None
        _MSP_VFS_WRITEBACKS[real_path] = (virtual_path, True, creation_mode)
    return real_path

def _msp_vfs_writeback(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    entry = _MSP_VFS_WRITEBACKS.pop(real_path, None)
    if entry is None:
        return
    virtual_path, overwrite, creation_mode = entry
    with _MSP_VFS_REAL_OPEN(real_path, "rb") as materialized:
        data_b64 = _msp_vfs_base64.b64encode(materialized.read()).decode("ascii")
    payload = {"path": virtual_path, "data_b64": data_b64, "overwrite": bool(overwrite)}
    if creation_mode is not None:
        payload["creation_mode"] = creation_mode
    _msp_vfs_request("write_file", **payload)

def _msp_vfs_writeback_snapshot(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    entry = _MSP_VFS_WRITEBACKS.get(real_path)
    if entry is None:
        return
    virtual_path, overwrite, creation_mode = entry
    with _MSP_VFS_REAL_OPEN(real_path, "rb") as materialized:
        data_b64 = _msp_vfs_base64.b64encode(materialized.read()).decode("ascii")
    payload = {"path": virtual_path, "data_b64": data_b64, "overwrite": bool(overwrite)}
    if creation_mode is not None:
        payload["creation_mode"] = creation_mode
    _msp_vfs_request("write_file", **payload)

def _msp_vfs_hold_subprocess_stream_writeback(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS[real_path] = (
        _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS.get(real_path, 0) + 1
    )

def _msp_vfs_subprocess_stream_writeback_is_held(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    return _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS.get(real_path, 0) > 0

def _msp_vfs_real_path_has_open_file_wrapper(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    for wrapper in list(_MSP_VFS_OPEN_FILE_WRAPPERS):
        try:
            if (_msp_vfs_os.path.normpath(wrapper._msp_real_path) == real_path and
                    not wrapper._msp_file.closed):
                return True
        except Exception:
            pass
    return False

def _msp_vfs_track_fd_real_path(fd, real_path):
    if fd is None or real_path is None:
        return
    try:
        _MSP_VFS_FD_REAL_PATHS[int(fd)] = _msp_vfs_os.path.normpath(real_path)
    except Exception:
        pass

def _msp_vfs_tracked_real_path_for_fd(fd):
    try:
        fd = int(fd)
    except Exception:
        return None
    real_path = _MSP_VFS_FD_REAL_PATHS.get(fd) or _MSP_VFS_FD_WRITEBACKS.get(fd)
    if real_path is None:
        return None
    return _msp_vfs_os.path.normpath(real_path)

def _msp_vfs_real_path_has_pending_fd_writeback(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    for fd_real_path in list(_MSP_VFS_FD_WRITEBACKS.values()):
        try:
            if _msp_vfs_os.path.normpath(fd_real_path) == real_path:
                return True
        except Exception:
            pass
    return False

def _msp_vfs_pending_real_path_for_virtual_path(virtual_path):
    virtual_path = _msp_vfs_os.path.normpath(virtual_path)
    for real_path, entry in list(_MSP_VFS_WRITEBACKS.items()):
        try:
            if _msp_vfs_os.path.normpath(entry[0]) == virtual_path:
                return _msp_vfs_os.path.normpath(real_path)
        except Exception:
            pass
    return None

def _msp_vfs_finalize_writeback(real_path):
    if real_path is None:
        return
    real_path = _msp_vfs_os.path.normpath(real_path)
    if _msp_vfs_subprocess_stream_writeback_is_held(real_path):
        return
    if (_msp_vfs_real_path_has_pending_fd_writeback(real_path) or
            _msp_vfs_real_path_has_open_file_wrapper(real_path)):
        _msp_vfs_writeback_snapshot(real_path)
    else:
        _msp_vfs_writeback(real_path)

def _msp_vfs_open_owns_fd(args, kwargs):
    if "closefd" in kwargs:
        return bool(kwargs.get("closefd"))
    if len(args) > 5:
        return bool(args[5])
    return True

def _msp_vfs_track_fd_alias(source_fd, target_fd):
    try:
        source_fd = int(source_fd)
        target_fd = int(target_fd)
    except Exception:
        return
    if source_fd in _MSP_VFS_DIR_FDS:
        _MSP_VFS_DIR_FDS[target_fd] = _MSP_VFS_DIR_FDS[source_fd]
    real_path = _msp_vfs_tracked_real_path_for_fd(source_fd)
    if real_path is None:
        return
    _MSP_VFS_FD_REAL_PATHS[target_fd] = real_path
    if source_fd in _MSP_VFS_FD_WRITEBACKS or real_path in _MSP_VFS_WRITEBACKS:
        _MSP_VFS_FD_WRITEBACKS[target_fd] = real_path

def _msp_vfs_forget_fd_mapping(fd):
    try:
        fd = int(fd)
    except Exception:
        return None
    _MSP_VFS_DIR_FDS.pop(fd, None)
    _MSP_VFS_FD_REAL_PATHS.pop(fd, None)
    return _MSP_VFS_FD_WRITEBACKS.pop(fd, None)

def _msp_vfs_release_subprocess_stream_writeback(real_path):
    real_path = _msp_vfs_os.path.normpath(real_path)
    count = _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS.get(real_path, 0)
    if count <= 1:
        _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS.pop(real_path, None)
        if not _msp_vfs_real_path_has_open_file_wrapper(real_path):
            _msp_vfs_writeback(real_path)
    else:
        _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS[real_path] = count - 1

def _msp_vfs_discard_pending_writebacks(virtual_path):
    virtual_path = _msp_vfs_os.path.normpath(virtual_path)
    discarded = False
    for real_path, entry in list(_MSP_VFS_WRITEBACKS.items()):
        if _msp_vfs_os.path.normpath(entry[0]) != virtual_path:
            continue
        _MSP_VFS_WRITEBACKS.pop(real_path, None)
        _MSP_VFS_REAL_TO_VIRTUAL.pop(real_path, None)
        try:
            _MSP_VFS_REAL_REMOVE(real_path)
        except Exception:
            pass
        discarded = True
    for fd, real_path in list(_MSP_VFS_FD_WRITEBACKS.items()):
        if _msp_vfs_os.path.normpath(_MSP_VFS_REAL_TO_VIRTUAL.get(real_path, "")) != virtual_path:
            continue
        _MSP_VFS_FD_WRITEBACKS.pop(fd, None)
        _MSP_VFS_REAL_TO_VIRTUAL.pop(real_path, None)
        try:
            _MSP_VFS_REAL_REMOVE(real_path)
        except Exception:
            pass
        discarded = True
    return discarded

def _msp_vfs_repath_pending_writeback(source_virtual_path, destination_virtual_path):
    source_virtual_path = _msp_vfs_os.path.normpath(source_virtual_path)
    destination_virtual_path = _msp_vfs_os.path.normpath(destination_virtual_path)
    if source_virtual_path == destination_virtual_path:
        return True
    real_path = _msp_vfs_pending_real_path_for_virtual_path(source_virtual_path)
    if real_path is None:
        return False
    destination_real_path = _msp_vfs_pending_real_path_for_virtual_path(destination_virtual_path)
    if destination_real_path is not None and destination_real_path != real_path:
        _msp_vfs_discard_pending_writebacks(destination_virtual_path)
    entry = _MSP_VFS_WRITEBACKS.get(real_path)
    if entry is None:
        return False
    _MSP_VFS_WRITEBACKS[real_path] = (destination_virtual_path, True, entry[2])
    _MSP_VFS_REAL_TO_VIRTUAL[real_path] = destination_virtual_path
    return True

def _msp_vfs_chmod_pending_writeback(virtual_path, mode):
    virtual_path = _msp_vfs_os.path.normpath(virtual_path)
    real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
    if real_path is None:
        return False
    mode = int(mode) & 0o777
    _MSP_VFS_REAL_CHMOD(real_path, mode)
    entry = _MSP_VFS_WRITEBACKS.get(real_path)
    if entry is None:
        return False
    virtual_path, overwrite, creation_mode = entry
    if creation_mode is None:
        _msp_vfs_request("chmod", path=virtual_path, mode=mode)
    else:
        creation_mode = mode
    _MSP_VFS_WRITEBACKS[real_path] = (virtual_path, overwrite, creation_mode)
    return True

def _msp_vfs_access_pending_writeback(virtual_path, mode):
    virtual_path = _msp_vfs_os.path.normpath(virtual_path)
    real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
    if real_path is None:
        return None
    return bool(_MSP_VFS_REAL_ACCESS(real_path, int(mode)))

def _msp_vfs_utime_pending_writeback(virtual_path, args, kwargs):
    virtual_path = _msp_vfs_os.path.normpath(virtual_path)
    real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
    if real_path is None:
        return False
    _MSP_VFS_REAL_UTIME(real_path, *args, **kwargs)
    return True

def _msp_vfs_utime_pending_fd_writeback(fd, args, kwargs):
    real_path = _msp_vfs_tracked_real_path_for_fd(fd)
    if real_path is None or real_path not in _MSP_VFS_WRITEBACKS:
        return False
    _MSP_VFS_REAL_UTIME(int(fd), *args, **kwargs)
    return True

def _msp_vfs_truncate_real_fd(fd, length):
    if _MSP_VFS_REAL_FTRUNCATE is not None:
        _MSP_VFS_REAL_FTRUNCATE(int(fd), int(length))
    else:
        _MSP_VFS_REAL_TRUNCATE(int(fd), int(length))

def _msp_vfs_truncate_materialized_path(real_path, length, finalize):
    try:
        _MSP_VFS_REAL_TRUNCATE(real_path, int(length))
        if finalize:
            _msp_vfs_writeback(real_path)
    except Exception:
        if finalize:
            _MSP_VFS_WRITEBACKS.pop(real_path, None)
            _MSP_VFS_REAL_TO_VIRTUAL.pop(real_path, None)
            try:
                _MSP_VFS_REAL_REMOVE(real_path)
            except Exception:
                pass
        raise
"""#
}
