enum MSPPythonVFSBootstrapPathQuerySource {
    static let source = #"""
def _msp_vfs_chdir(path):
    global _MSP_VFS_VIRTUAL_CWD
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(path)
        response = _msp_vfs_request("stat", path=virtual_path)
        if (response.get("info") or {}).get("type") != "directory":
            raise NotADirectoryError(_msp_vfs_errno.ENOTDIR, "workspace path is not a directory", virtual_path)
        _MSP_VFS_VIRTUAL_CWD = virtual_path
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_getcwdb():
    encoding = _msp_vfs_sys.getfilesystemencoding() or "utf-8"
    return _MSP_VFS_VIRTUAL_CWD.encode(encoding, "surrogateescape")

def _msp_vfs_virtual_home(bytes_mode=False):
    home = _msp_vfs_os.environ.get("HOME", "/") or "/"
    if not isinstance(home, str) or not home.startswith("/"):
        home = "/"
    home = _msp_vfs_os.path.normpath(home)
    return _msp_vfs_os.fsencode(home) if bytes_mode else home

def _msp_vfs_expanduser(path):
    raw = _msp_vfs_os.fspath(path)
    if isinstance(raw, bytes):
        if raw == b"~":
            return _msp_vfs_virtual_home(bytes_mode=True)
        if raw.startswith(b"~/"):
            return _msp_vfs_virtual_home(bytes_mode=True).rstrip(b"/") + raw[1:]
        return raw
    if raw == "~":
        return _msp_vfs_virtual_home()
    if isinstance(raw, str) and raw.startswith("~/"):
        return _msp_vfs_virtual_home().rstrip("/") + raw[1:]
    return raw

def _msp_vfs_exists(path):
    try:
        _msp_vfs_stat_call(path)
        return True
    except OSError:
        return False

def _msp_vfs_lexists(path):
    try:
        _msp_vfs_lstat_call(path)
        return True
    except OSError:
        return False

def _msp_vfs_isdir(path):
    try:
        return _msp_vfs_stat.S_ISDIR(_msp_vfs_stat_call(path).st_mode)
    except OSError:
        return False

def _msp_vfs_isfile(path):
    try:
        return _msp_vfs_stat.S_ISREG(_msp_vfs_stat_call(path).st_mode)
    except OSError:
        return False

def _msp_vfs_islink(path):
    try:
        return _msp_vfs_stat.S_ISLNK(_msp_vfs_lstat_call(path).st_mode)
    except OSError:
        return False

def _msp_vfs_ismount(path):
    raw = _msp_vfs_os.fspath(path)
    if _msp_vfs_is_internal_real_path(raw):
        return _MSP_VFS_REAL_PATH_ISMOUNT(raw)
    virtual_path = _msp_vfs_absolute_virtual_path(raw)
    try:
        response = _msp_vfs_request("lstat", path=virtual_path)
    except OSError:
        return False
    info = response.get("info") or {}
    if info.get("type") != "directory":
        return False
    return _msp_vfs_os.path.normpath(virtual_path) == "/"

def _msp_vfs_abspath(path):
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_PATH_ABSPATH(path)
    return _msp_vfs_path_result(path, _msp_vfs_absolute_virtual_path(path))

def _msp_vfs_realpath(path, *args, **kwargs):
    if args:
        raise TypeError("realpath() takes 1 positional argument but %d were given" % (len(args) + 1))
    for key in kwargs:
        if key != "strict":
            raise TypeError("realpath() got an unexpected keyword argument '%s'" % key)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_PATH_REALPATH(path, *args, **kwargs)
    resolved = _msp_vfs_resolve_virtual_realpath(path, strict=bool(kwargs.get("strict", False)))
    return _msp_vfs_path_result(path, resolved)

def _msp_vfs_resolve_virtual_realpath(path, strict=False):
    absolute = _msp_vfs_absolute_virtual_path(path)
    parts = _msp_vfs_virtual_path_parts(absolute)
    resolved_parts = []
    seen = set()
    index = 0
    while index < len(parts):
        part = parts[index]
        if part in ("", "."):
            index += 1
            continue
        if part == "..":
            if resolved_parts:
                resolved_parts.pop()
            index += 1
            continue
        current = _msp_vfs_join_virtual_parts(resolved_parts + [part])
        try:
            response = _msp_vfs_request("lstat", path=current)
        except OSError as error:
            if strict:
                _msp_vfs_reraise_path_error(error, current, force=True)
            return _msp_vfs_os.path.normpath(_msp_vfs_join_virtual_parts(resolved_parts + parts[index:]))
        info = response.get("info") or {}
        if info.get("type") != "symbolicLink":
            resolved_parts.append(part)
            index += 1
            continue
        if current in seen:
            if strict:
                raise OSError(_msp_vfs_errno.ELOOP, "Too many levels of symbolic links", current)
            return _msp_vfs_os.path.normpath(_msp_vfs_join_virtual_parts(resolved_parts + parts[index:]))
        seen.add(current)
        target = info.get("symbolic_link_target")
        if target is None:
            target = _msp_vfs_request("readlink", path=current).get("value", "")
        remaining = parts[index + 1:]
        if _msp_vfs_os.path.isabs(target):
            parts = _msp_vfs_virtual_path_parts(target) + remaining
        else:
            parent = _msp_vfs_join_virtual_parts(resolved_parts)
            parts = _msp_vfs_virtual_path_parts(_msp_vfs_os.path.join(parent, target)) + remaining
        resolved_parts = []
        index = 0
    return _msp_vfs_join_virtual_parts(resolved_parts)

def _msp_vfs_virtual_path_parts(path):
    text = _msp_vfs_os.path.normpath(str(path or "/"))
    return [part for part in text.split("/") if part]

def _msp_vfs_join_virtual_parts(parts):
    cleaned = [part for part in parts if part and part != "."]
    return "/" + "/".join(cleaned) if cleaned else "/"

def _msp_vfs_relpath(path, start=None):
    path_is_bytes = _msp_vfs_is_bytes_path(path)
    if start is not None and path_is_bytes != _msp_vfs_is_bytes_path(start):
        raise TypeError("Can't mix strings and bytes in path components")
    absolute_path = _msp_vfs_abspath(path)
    absolute_start = _msp_vfs_abspath(_msp_vfs_os.fsencode(".") if path_is_bytes and start is None else ("." if start is None else start))
    if isinstance(absolute_path, bytes):
        absolute_path = _msp_vfs_os.fsdecode(absolute_path)
    if isinstance(absolute_start, bytes):
        absolute_start = _msp_vfs_os.fsdecode(absolute_start)
    result = _msp_vfs_raw_relpath(absolute_path, absolute_start)
    return _msp_vfs_os.fsencode(result) if path_is_bytes else result

def _msp_vfs_samestat(stat1, stat2):
    return stat1.st_ino == stat2.st_ino and stat1.st_dev == stat2.st_dev

def _msp_vfs_samefile(path1, path2):
    if _msp_vfs_is_internal_real_path(path1) and _msp_vfs_is_internal_real_path(path2):
        if _MSP_VFS_REAL_PATH_SAMEFILE is not None:
            return _MSP_VFS_REAL_PATH_SAMEFILE(path1, path2)
    stat1 = _msp_vfs_stat_call(path1)
    stat2 = _msp_vfs_stat_call(path2)
    return _msp_vfs_samestat(stat1, stat2)

def _msp_vfs_virtual_path_for_fd(fd):
    try:
        fd = int(fd)
    except Exception:
        return None
    if fd in _MSP_VFS_DIR_FDS:
        return _MSP_VFS_DIR_FDS[fd]
    real_path = _msp_vfs_tracked_real_path_for_fd(fd)
    if real_path is None:
        return None
    return _MSP_VFS_REAL_TO_VIRTUAL.get(real_path)

def _msp_vfs_sameopenfile(fd1, fd2):
    virtual_path1 = _msp_vfs_virtual_path_for_fd(fd1)
    virtual_path2 = _msp_vfs_virtual_path_for_fd(fd2)
    if virtual_path1 is not None and virtual_path2 is not None:
        return _msp_vfs_os.path.normpath(virtual_path1) == _msp_vfs_os.path.normpath(virtual_path2)
    if _MSP_VFS_REAL_PATH_SAMEOPENFILE is not None:
        return _MSP_VFS_REAL_PATH_SAMEOPENFILE(fd1, fd2)
    raise OSError(_msp_vfs_errno.EBADF, "Bad file descriptor")
"""#
}
