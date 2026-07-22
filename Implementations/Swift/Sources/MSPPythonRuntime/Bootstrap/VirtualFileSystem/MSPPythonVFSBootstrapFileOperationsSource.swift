enum MSPPythonVFSBootstrapFileOperationsSource {
    static let source = #"""
def _msp_vfs_mkdir(path, mode=0o777, *args, **kwargs):
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_MKDIR(path, mode)
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        _msp_vfs_request("mkdir", path=_msp_vfs_virtual_path(path, dir_fd=dir_fd), creation_mode=_msp_vfs_apply_umask(mode), intermediates=False)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_makedirs(path, mode=0o777, exist_ok=False):
    if _msp_vfs_is_internal_real_path(path):
        return _msp_vfs_real_makedirs(path, mode=mode, exist_ok=exist_ok)
    virtual_path = _msp_vfs_absolute_virtual_path(path)
    try:
        response = _msp_vfs_request("stat", path=virtual_path)
        info = response.get("info") or {}
        if exist_ok and info.get("type") == "directory":
            return
        raise FileExistsError(_msp_vfs_errno.EEXIST, "File exists", _msp_vfs_path_result(path, virtual_path))
    except FileNotFoundError:
        pass
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)
    try:
        _msp_vfs_request("mkdir", path=virtual_path, creation_mode=_msp_vfs_apply_umask(mode), intermediates=True)
    except FileExistsError as error:
        if not exist_ok or not _msp_vfs_isdir(path):
            _msp_vfs_reraise_path_error(error, path)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_ensure_virtual_directory(path, mode=0o777):
    virtual_path = _msp_vfs_absolute_virtual_path(path)
    try:
        _msp_vfs_request("mkdir", path=virtual_path, creation_mode=_msp_vfs_apply_umask(mode), intermediates=True)
        return
    except FileExistsError:
        pass
    response = _msp_vfs_request("stat", path=virtual_path)
    info = response.get("info") or {}
    if info.get("type") != "directory":
        raise NotADirectoryError(_msp_vfs_errno.ENOTDIR, "Not a directory", virtual_path)

def _msp_vfs_remove(path, *args, **kwargs):
    dir_fd = _msp_vfs_pop_dir_fd(kwargs)
    virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
    discarded = _msp_vfs_discard_pending_writebacks(virtual_path)
    try:
        _msp_vfs_request("remove", path=virtual_path, recursive=False)
    except FileNotFoundError as error:
        if not discarded:
            _msp_vfs_reraise_path_error(error, path)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_rmdir(path, *args, **kwargs):
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        _msp_vfs_request("rmdir", path=_msp_vfs_virtual_path(path, dir_fd=dir_fd), recursive=False)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_rename(src, dst, *args, **kwargs):
    try:
        src_dir_fd = _msp_vfs_pop_dir_fd(kwargs, "src_dir_fd")
        dst_dir_fd = _msp_vfs_pop_dir_fd(kwargs, "dst_dir_fd")
        source_virtual_path = _msp_vfs_virtual_path(src, dir_fd=src_dir_fd)
        destination_virtual_path = _msp_vfs_virtual_path(dst, dir_fd=dst_dir_fd)
        if _msp_vfs_repath_pending_writeback(source_virtual_path, destination_virtual_path):
            return
        _msp_vfs_request("rename", path=source_virtual_path, destination=destination_virtual_path, overwrite=True)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, src, dst)

def _msp_vfs_replace(src, dst, *args, **kwargs):
    try:
        src_dir_fd = _msp_vfs_pop_dir_fd(kwargs, "src_dir_fd")
        dst_dir_fd = _msp_vfs_pop_dir_fd(kwargs, "dst_dir_fd")
        source_virtual_path = _msp_vfs_virtual_path(src, dir_fd=src_dir_fd)
        destination_virtual_path = _msp_vfs_virtual_path(dst, dir_fd=dst_dir_fd)
        if _msp_vfs_repath_pending_writeback(source_virtual_path, destination_virtual_path):
            return
        _msp_vfs_request("replace", path=source_virtual_path, destination=destination_virtual_path, overwrite=True)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, src, dst)

def _msp_vfs_chmod(path, mode, *args, **kwargs):
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        mode = int(mode) & 0o777
        if _msp_vfs_chmod_pending_writeback(virtual_path, mode):
            return
        _msp_vfs_request("chmod", path=virtual_path, mode=mode)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_chflags(path, flags, *args, **kwargs):
    normalized_flags = int(flags)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_CHFLAGS(path, normalized_flags, *args, **kwargs)
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        _msp_vfs_request("stat", path=_msp_vfs_virtual_path(path, dir_fd=dir_fd))
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_utime(path, *args, **kwargs):
    def _msp_vfs_utime_modification_time(args, kwargs):
        times = args[0] if args else kwargs.get("times", None)
        ns = kwargs.get("ns", None)
        if times is not None and ns is not None:
            raise ValueError("utime: you may specify either 'times' or 'ns' but not both")
        if ns is not None:
            modification_time = float(ns[1]) / 1000000000.0
        elif times is not None:
            modification_time = float(times[1])
        else:
            return None
        if modification_time != modification_time:
            raise ValueError("Invalid value NaN (not a number)")
        if modification_time in (float("inf"), float("-inf")):
            raise OverflowError("timestamp out of range for platform time_t")
        return modification_time

    if isinstance(path, int):
        if _msp_vfs_utime_pending_fd_writeback(path, args, kwargs):
            return
        virtual_path = _msp_vfs_virtual_path_for_fd(path)
        if virtual_path is not None:
            if "dir_fd" in kwargs:
                _MSP_VFS_REAL_UTIME(path, *args, **kwargs)
                return
            _msp_vfs_request("utime", path=virtual_path, modification_time=_msp_vfs_utime_modification_time(args, kwargs))
            return
        _MSP_VFS_REAL_UTIME(path, *args, **kwargs)
        return
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        if _msp_vfs_utime_pending_writeback(virtual_path, args, kwargs):
            return
        _msp_vfs_request("utime", path=virtual_path, modification_time=_msp_vfs_utime_modification_time(args, kwargs))
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_truncate(path, length):
    if isinstance(path, int):
        _msp_vfs_truncate_real_fd(path, length)
        return
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(path)
        real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
        if real_path is not None:
            _msp_vfs_truncate_materialized_path(real_path, length, finalize=False)
            return
        real_path = _msp_vfs_materialize(virtual_path, mode="r+")
        _msp_vfs_truncate_materialized_path(real_path, length, finalize=True)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_ftruncate(fd, length):
    _msp_vfs_truncate_real_fd(fd, length)

def _msp_vfs_readlink(path, *args, **kwargs):
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        value = _msp_vfs_request("readlink", path=_msp_vfs_virtual_path(path, dir_fd=dir_fd)).get("value", "")
        return _msp_vfs_path_result(path, value)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_access(path, mode, *args, **kwargs):
    try:
        dir_fd = _msp_vfs_pop_dir_fd(kwargs)
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        pending_access = _msp_vfs_access_pending_writeback(virtual_path, mode)
        if pending_access is not None:
            return pending_access
        command_access = _msp_vfs_virtual_command_access(virtual_path, mode)
        if command_access is not None:
            return command_access
        response = _msp_vfs_request("access", path=virtual_path, mode=int(mode))
        return bool(response.get("bool_value", False))
    except (TypeError, ValueError):
        raise
    except Exception:
        return False

def _msp_vfs_os_open(path, flags, *args, **kwargs):
    if _MSP_VFS_REAL_OPEN_FD is None:
        raise PermissionError("os.open is unavailable")
    dir_fd = _msp_vfs_pop_dir_fd(kwargs)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_OPEN_FD(path, flags, *args, **kwargs)
    try:
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        creation_mode_base = args[0] if args else kwargs.get("mode", 0o666)
        if not _msp_vfs_flags_write(flags):
            try:
                info = _msp_vfs_request("stat", path=virtual_path).get("info") or {}
            except OSError:
                info = {}
            if info.get("type") == "directory":
                if not _MSP_VFS_MATERIALIZED_DIR:
                    raise PermissionError("MSP Python materialized file directory is unavailable")
                _msp_vfs_real_makedirs(_MSP_VFS_MATERIALIZED_DIR, exist_ok=True)
                real_dir = _msp_vfs_os.path.join(_MSP_VFS_MATERIALIZED_DIR, _msp_vfs_next_id("dirfd") + "-dir")
                _msp_vfs_real_makedirs(real_dir, exist_ok=False)
                fd = _MSP_VFS_REAL_OPEN_FD(real_dir, flags, *args, **kwargs)
                _MSP_VFS_DIR_FDS[fd] = virtual_path
                return fd
        real_path = _msp_vfs_materialize(virtual_path, flags=flags, creation_mode_base=creation_mode_base)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)
    try:
        fd = _MSP_VFS_REAL_OPEN_FD(real_path, flags, *args, **kwargs)
    except Exception as error:
        _MSP_VFS_WRITEBACKS.pop(real_path, None)
        _MSP_VFS_REAL_TO_VIRTUAL.pop(real_path, None)
        if isinstance(error, OSError):
            _msp_vfs_reraise_path_error(error, path)
        raise
    if _msp_vfs_flags_write(flags):
        _MSP_VFS_FD_WRITEBACKS[fd] = real_path
    _msp_vfs_track_fd_real_path(fd, real_path)
    return fd

def _msp_vfs_os_close(fd):
    try:
        return _MSP_VFS_REAL_CLOSE_FD(fd)
    finally:
        real_path = _msp_vfs_forget_fd_mapping(fd)
        _msp_vfs_finalize_writeback(real_path)

def _msp_vfs_os_dup(fd, *args, **kwargs):
    if _MSP_VFS_REAL_DUP is None:
        raise PermissionError("os.dup is unavailable")
    duplicated = _MSP_VFS_REAL_DUP(fd, *args, **kwargs)
    _msp_vfs_track_fd_alias(fd, duplicated)
    return duplicated

def _msp_vfs_os_dup2(fd, fd2, *args, **kwargs):
    if _MSP_VFS_REAL_DUP2 is None:
        raise PermissionError("os.dup2 is unavailable")
    try:
        source_fd = int(fd)
        target_fd = int(fd2)
    except Exception:
        source_fd = fd
        target_fd = fd2
    old_real_path = None
    if source_fd != target_fd:
        old_real_path = _msp_vfs_tracked_real_path_for_fd(target_fd)
    duplicated = _MSP_VFS_REAL_DUP2(fd, fd2, *args, **kwargs)
    if source_fd != target_fd:
        _msp_vfs_forget_fd_mapping(target_fd)
        _msp_vfs_finalize_writeback(old_real_path)
    _msp_vfs_track_fd_alias(source_fd, duplicated)
    return duplicated

def _msp_vfs_umask(mask):
    global _MSP_VFS_FILE_CREATION_MASK
    old_mask = _MSP_VFS_FILE_CREATION_MASK
    _MSP_VFS_FILE_CREATION_MASK = int(mask) & 0o777
    return old_mask

def _msp_vfs_capture_pending_writeback_state():
    return (
        set(list(_MSP_VFS_OPEN_FILE_WRAPPERS)),
        set(_MSP_VFS_FD_WRITEBACKS.keys()),
        set(_MSP_VFS_WRITEBACKS.keys()),
    )

def _msp_vfs_flush_pending_writebacks(baseline_state=None):
    if baseline_state is None:
        baseline_wrappers = None
        baseline_fds = None
        baseline_real_paths = None
    else:
        baseline_wrappers, baseline_fds, baseline_real_paths = baseline_state
    for wrapper in list(_MSP_VFS_OPEN_FILE_WRAPPERS):
        if baseline_wrappers is not None and wrapper in baseline_wrappers:
            continue
        try:
            wrapper.close()
        except Exception:
            pass
    for fd in list(_MSP_VFS_FD_WRITEBACKS.keys()):
        if baseline_fds is not None and fd in baseline_fds:
            continue
        real_path = _MSP_VFS_FD_WRITEBACKS.pop(fd, None)
        _MSP_VFS_FD_REAL_PATHS.pop(fd, None)
        try:
            if _MSP_VFS_REAL_CLOSE_FD is not None:
                _MSP_VFS_REAL_CLOSE_FD(fd)
        except Exception:
                pass
        if real_path is not None:
            try:
                _msp_vfs_finalize_writeback(real_path)
            except Exception:
                pass
    for real_path in list(_MSP_VFS_WRITEBACKS.keys()):
        if baseline_real_paths is not None and real_path in baseline_real_paths:
            continue
        if _msp_vfs_subprocess_stream_writeback_is_held(real_path):
            _MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS.pop(_msp_vfs_os.path.normpath(real_path), None)
        try:
            _msp_vfs_writeback(real_path)
        except Exception:
            pass
"""#
}
