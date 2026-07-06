enum MSPPythonVFSBootstrapFileMetadataSource {
    static let source = #"""
def _msp_vfs_info_mode(info):
    kind = info.get("type")
    permissions = int(info.get("permissions") or 0o777)
    if kind == "directory":
        return _msp_vfs_stat.S_IFDIR | permissions
    if kind == "symbolicLink":
        return _msp_vfs_stat.S_IFLNK | permissions
    return _msp_vfs_stat.S_IFREG | permissions

def _msp_vfs_inode_for_path(path):
    text = _msp_vfs_os.path.normpath(str(path or ""))
    value = 1469598103934665603
    for char in text:
        value ^= ord(char)
        value = (value * 1099511628211) & 0x7fffffffffffffff
    return value or 1

def _msp_vfs_inode_for_info(info):
    identity = info.get("file_identity")
    return _msp_vfs_inode_for_path(identity if identity else info.get("virtual_path", ""))

def _msp_vfs_stat_result(info):
    size = int(info.get("size") or 0)
    mtime = float(info.get("modification_time") or 0)
    mode = _msp_vfs_info_mode(info)
    inode = _msp_vfs_inode_for_info(info)
    return _msp_vfs_stat_result_with_platform_fields((mode, inode, 1, 1, 0, 0, size, mtime, mtime, mtime))

def _msp_vfs_stat_result_from_real_stat(real_stat, virtual_path, file_identity=None):
    return _msp_vfs_stat_result_with_platform_fields((
        real_stat.st_mode,
        _msp_vfs_inode_for_path(file_identity if file_identity else virtual_path),
        1,
        getattr(real_stat, "st_nlink", 1),
        getattr(real_stat, "st_uid", 0),
        getattr(real_stat, "st_gid", 0),
        real_stat.st_size,
        real_stat.st_atime,
        real_stat.st_mtime,
        real_stat.st_ctime,
    ))

def _msp_vfs_stat_result_with_platform_fields(base_fields):
    values = tuple(base_fields)
    result = _msp_vfs_os.stat_result(values)
    platform_fields = {}
    if hasattr(result, "st_atime_ns"):
        platform_fields["st_atime_ns"] = int(float(values[7]) * 1000000000)
    if hasattr(result, "st_mtime_ns"):
        platform_fields["st_mtime_ns"] = int(float(values[8]) * 1000000000)
    if hasattr(result, "st_ctime_ns"):
        platform_fields["st_ctime_ns"] = int(float(values[9]) * 1000000000)
    if hasattr(result, "st_flags"):
        platform_fields["st_flags"] = 0
    if hasattr(result, "st_birthtime"):
        platform_fields["st_birthtime"] = 0
    if not platform_fields:
        return result
    try:
        return _msp_vfs_os.stat_result(values, platform_fields)
    except TypeError:
        return result

def _msp_vfs_info_type_for_mode(mode):
    if _msp_vfs_stat.S_ISDIR(mode):
        return "directory"
    if _msp_vfs_stat.S_ISLNK(mode):
        return "symbolicLink"
    return "regularFile"

def _msp_vfs_pending_entry_for_real_path(real_path, virtual_path):
    try:
        real_stat = _MSP_VFS_REAL_STAT(real_path)
    except OSError:
        return None
    name = _msp_vfs_os.path.basename(_msp_vfs_os.path.normpath(virtual_path))
    if not name:
        return None
    return {
        "name": name,
        "info": {
            "type": _msp_vfs_info_type_for_mode(real_stat.st_mode),
            "permissions": _msp_vfs_stat.S_IMODE(real_stat.st_mode),
            "size": int(real_stat.st_size),
            "modification_time": float(real_stat.st_mtime),
            "virtual_path": virtual_path,
        },
    }

def _msp_vfs_entries_with_pending_writebacks(virtual_dir, entries):
    virtual_dir = _msp_vfs_os.path.normpath(virtual_dir)
    merged = {}
    ordered_entries = []
    for entry in entries:
        name = entry.get("name", "")
        if name not in merged:
            ordered_entries.append(name)
        merged[name] = entry
    for real_path, writeback_entry in list(_MSP_VFS_WRITEBACKS.items()):
        try:
            virtual_path = _msp_vfs_os.path.normpath(writeback_entry[0])
            parent = _msp_vfs_os.path.normpath(_msp_vfs_os.path.dirname(virtual_path))
            if parent != virtual_dir:
                continue
            pending_entry = _msp_vfs_pending_entry_for_real_path(real_path, virtual_path)
            if pending_entry is None:
                continue
            name = pending_entry.get("name", "")
            if name not in merged:
                ordered_entries.append(name)
            merged[name] = pending_entry
        except Exception:
            pass
    for name, entry in sorted((_MSP_VFS_COMMAND_DIR_ENTRIES.get(virtual_dir) or {}).items()):
        if name not in merged:
            ordered_entries.append(name)
            merged[name] = entry
    return [merged[name] for name in ordered_entries if name in merged]

def _msp_vfs_virtual_command_info(virtual_path):
    normalized = _msp_vfs_os.path.normpath(str(virtual_path or "/"))
    command_name = _MSP_VFS_COMMAND_PATHS.get(normalized)
    if command_name is not None:
        return {
            "type": "regularFile",
            "permissions": 0o755,
            "size": 0,
            "modification_time": 0,
            "virtual_path": normalized,
            "file_identity": "msp-command:" + command_name,
        }
    if normalized != "/" and normalized in _MSP_VFS_COMMAND_DIR_ENTRIES:
        return {
            "type": "directory",
            "permissions": 0o755,
            "size": 0,
            "modification_time": 0,
            "virtual_path": normalized,
            "file_identity": "msp-command-dir:" + normalized,
        }
    return None

def _msp_vfs_virtual_command_directory_entries(virtual_path):
    normalized = _msp_vfs_os.path.normpath(str(virtual_path or "/"))
    entries = _MSP_VFS_COMMAND_DIR_ENTRIES.get(normalized)
    if entries is None:
        return None
    return [entry for _, entry in sorted(entries.items())]

def _msp_vfs_virtual_command_access(virtual_path, mode):
    info = _msp_vfs_virtual_command_info(virtual_path)
    if info is None:
        return None
    mode = int(mode)
    if mode & getattr(_msp_vfs_os, "W_OK", 2):
        return False
    if mode & getattr(_msp_vfs_os, "X_OK", 1):
        return bool(int(info.get("permissions") or 0) & 0o111)
    return True

def _msp_vfs_stat_call(path, *args, **kwargs):
    dir_fd = kwargs.get("dir_fd")
    follow_symlinks = kwargs.get("follow_symlinks", True)
    if isinstance(path, int) and path in _MSP_VFS_DIR_FDS:
        response = _msp_vfs_request("stat", path=_MSP_VFS_DIR_FDS[path])
        return _msp_vfs_stat_result(response.get("info") or {})
    if isinstance(path, int):
        return _msp_vfs_fstat_call(path)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_STAT(path, *args, **kwargs)
    if not follow_symlinks:
        lstat_kwargs = dict(kwargs)
        lstat_kwargs.pop("follow_symlinks", None)
        return _msp_vfs_lstat_call(path, *args, **lstat_kwargs)
    try:
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
        if real_path is not None:
            return _msp_vfs_stat_result_from_real_stat(_MSP_VFS_REAL_STAT(real_path), virtual_path)
        try:
            response = _msp_vfs_request("stat", path=virtual_path)
            return _msp_vfs_stat_result(response.get("info") or {})
        except OSError as error:
            command_info = _msp_vfs_virtual_command_info(virtual_path)
            if command_info is not None:
                return _msp_vfs_stat_result(command_info)
            raise error
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path, force=dir_fd is not None)

def _msp_vfs_lstat_call(path, *args, **kwargs):
    dir_fd = kwargs.get("dir_fd")
    if isinstance(path, int) or _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_LSTAT(path, *args, **kwargs)
    try:
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
        if real_path is not None:
            return _msp_vfs_stat_result_from_real_stat(_MSP_VFS_REAL_LSTAT(real_path), virtual_path)
        try:
            response = _msp_vfs_request("lstat", path=virtual_path)
            return _msp_vfs_stat_result(response.get("info") or {})
        except OSError as error:
            command_info = _msp_vfs_virtual_command_info(virtual_path)
            if command_info is not None:
                return _msp_vfs_stat_result(command_info)
            raise error
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path, force=dir_fd is not None)

def _msp_vfs_fstat_call(fd):
    if _MSP_VFS_REAL_FSTAT is None:
        raise PermissionError("os.fstat is unavailable")
    real_stat = _MSP_VFS_REAL_FSTAT(fd)
    virtual_path = _msp_vfs_virtual_path_for_fd(fd)
    if virtual_path is not None:
        file_identity = None
        try:
            response = _msp_vfs_request("stat", path=virtual_path)
            file_identity = (response.get("info") or {}).get("file_identity")
        except OSError:
            pass
        return _msp_vfs_stat_result_from_real_stat(real_stat, virtual_path, file_identity=file_identity)
    return real_stat

def _msp_vfs_statvfs_backing_path(virtual_path):
    real_path = _msp_vfs_pending_real_path_for_virtual_path(virtual_path)
    if real_path is not None:
        return real_path
    if _MSP_VFS_WORKSPACE_ROOT:
        return _MSP_VFS_WORKSPACE_ROOT
    if _MSP_VFS_MATERIALIZED_DIR:
        return _MSP_VFS_MATERIALIZED_DIR
    if _MSP_VFS_BROKER_DIR:
        return _MSP_VFS_BROKER_DIR
    raise PermissionError("MSP Python workspace statvfs backing path is unavailable")

def _msp_vfs_statvfs_call(path):
    if _MSP_VFS_REAL_STATVFS is None:
        raise PermissionError("os.statvfs is unavailable")
    if isinstance(path, int):
        return _msp_vfs_fstatvfs_call(path)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_STATVFS(path)
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(path)
        _msp_vfs_stat_call(path)
        return _MSP_VFS_REAL_STATVFS(_msp_vfs_statvfs_backing_path(virtual_path))
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_fstatvfs_call(fd):
    if _MSP_VFS_REAL_FSTATVFS is None:
        raise PermissionError("os.fstatvfs is unavailable")
    return _MSP_VFS_REAL_FSTATVFS(fd)

def _msp_vfs_validate_pathconf_name(name):
    if isinstance(name, str):
        if name not in _msp_vfs_os.pathconf_names:
            raise ValueError("unrecognized configuration name")
        return
    if not isinstance(name, int):
        raise TypeError("configuration names must be strings or integers")

def _msp_vfs_pathconf_call(path, name):
    if _MSP_VFS_REAL_PATHCONF is None:
        raise PermissionError("os.pathconf is unavailable")
    _msp_vfs_validate_pathconf_name(name)
    if isinstance(path, int):
        return _MSP_VFS_REAL_PATHCONF(path, name)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_PATHCONF(path, name)
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(path)
        _msp_vfs_stat_call(path)
        return _MSP_VFS_REAL_PATHCONF(_msp_vfs_statvfs_backing_path(virtual_path), name)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)

def _msp_vfs_fpathconf_call(fd, name):
    if _MSP_VFS_REAL_FPATHCONF is None:
        raise PermissionError("os.fpathconf is unavailable")
    _msp_vfs_validate_pathconf_name(name)
    return _MSP_VFS_REAL_FPATHCONF(fd, name)

def _msp_vfs_listdir(path="."):
    if isinstance(path, int) and path in _MSP_VFS_DIR_FDS:
        virtual_path = _MSP_VFS_DIR_FDS[path]
        response = _msp_vfs_request("listdir", path=virtual_path)
        entries = _msp_vfs_entries_with_pending_writebacks(virtual_path, response.get("entries") or [])
        return [entry.get("name", "") for entry in entries]
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_LISTDIR(path)
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(path)
        try:
            response = _msp_vfs_request("listdir", path=virtual_path)
            entries = _msp_vfs_entries_with_pending_writebacks(virtual_path, response.get("entries") or [])
        except OSError as error:
            entries = _msp_vfs_virtual_command_directory_entries(virtual_path)
            if entries is None:
                raise error
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)
    if _msp_vfs_is_bytes_path(path):
        return [_msp_vfs_os.fsencode(entry.get("name", "")) for entry in entries]
    return [entry.get("name", "") for entry in entries]

class _MSPPythonVFSDirEntry:
    def __init__(self, entry, display_base, bytes_mode=False):
        raw_name = entry.get("name", "")
        self.name = _msp_vfs_os.fsencode(raw_name) if bytes_mode else raw_name
        self._info = entry.get("info") or {}
        self._stat_cache = None
        self._lstat_cache = None
        if display_base is None:
            self.path = self.name
        else:
            self.path = _msp_vfs_os.path.join(display_base, self.name)
        self._stat_path = self._info.get("virtual_path", self.path)

    def _follow_symlinks(self, args, kwargs, method_name):
        if args:
            raise TypeError("%s() takes no positional arguments" % method_name)
        for key in kwargs:
            if key != "follow_symlinks":
                raise TypeError("'%s' is an invalid keyword argument for %s()" % (key, method_name))
        return bool(kwargs.get("follow_symlinks", True))

    def _entry_stat(self, follow_symlinks):
        if not follow_symlinks:
            if self._lstat_cache is None:
                self._lstat_cache = _msp_vfs_stat_result(self._info)
            return self._lstat_cache
        if self._info.get("type") != "symbolicLink":
            if self._stat_cache is None:
                self._stat_cache = _msp_vfs_stat_result(self._info)
            return self._stat_cache
        if self._stat_cache is None:
            try:
                self._stat_cache = _msp_vfs_stat_call(self._stat_path)
            except OSError as error:
                _msp_vfs_reraise_path_error(error, self.path, force=True)
        return self._stat_cache

    def stat(self, *args, **kwargs):
        return self._entry_stat(self._follow_symlinks(args, kwargs, "stat"))

    def is_dir(self, *args, **kwargs):
        try:
            return _msp_vfs_stat.S_ISDIR(self._entry_stat(self._follow_symlinks(args, kwargs, "is_dir")).st_mode)
        except OSError:
            return False

    def is_file(self, *args, **kwargs):
        try:
            return _msp_vfs_stat.S_ISREG(self._entry_stat(self._follow_symlinks(args, kwargs, "is_file")).st_mode)
        except OSError:
            return False

    def is_symlink(self):
        return self._info.get("type") == "symbolicLink"

    def inode(self):
        return _msp_vfs_inode_for_info(self._info)

    def __fspath__(self):
        return self.path

    def __repr__(self):
        return "<DirEntry %r>" % self.name

class _MSPPythonVFSScandir:
    def __init__(self, entries, display_base, bytes_mode=False):
        self._entries = [_MSPPythonVFSDirEntry(entry, display_base, bytes_mode=bytes_mode) for entry in entries]
        self._index = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._index >= len(self._entries):
            raise StopIteration
        value = self._entries[self._index]
        self._index += 1
        return value

    def close(self):
        self._index = len(self._entries)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False

def _msp_vfs_scandir(path="."):
    if isinstance(path, int) and path in _MSP_VFS_DIR_FDS:
        virtual_path = _MSP_VFS_DIR_FDS[path]
        response = _msp_vfs_request("listdir", path=virtual_path)
        entries = _msp_vfs_entries_with_pending_writebacks(virtual_path, response.get("entries") or [])
        return _MSPPythonVFSScandir(entries, None)
    if _msp_vfs_is_internal_real_path(path):
        return _MSP_VFS_REAL_SCANDIR(path)
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(path)
        try:
            response = _msp_vfs_request("listdir", path=virtual_path)
            entries = _msp_vfs_entries_with_pending_writebacks(virtual_path, response.get("entries") or [])
        except OSError as error:
            entries = _msp_vfs_virtual_command_directory_entries(virtual_path)
            if entries is None:
                raise error
    except OSError as error:
        _msp_vfs_reraise_path_error(error, path)
    display_base = _msp_vfs_os.fspath(path)
    bytes_mode = isinstance(display_base, bytes)
    if bytes_mode:
        display_base_text = _msp_vfs_os.fsdecode(display_base)
        if _msp_vfs_os.path.isabs(display_base_text):
            display_base_text = _msp_vfs_virtualize_real_path(display_base_text)
        display_base = _msp_vfs_os.fsencode(display_base_text)
    elif isinstance(display_base, str) and _msp_vfs_os.path.isabs(display_base):
        display_base = _msp_vfs_virtualize_real_path(display_base)
    return _MSPPythonVFSScandir(entries, display_base, bytes_mode=bytes_mode)

def _msp_vfs_fwalk_display_name(name, bytes_mode):
    return _msp_vfs_os.fsencode(name) if bytes_mode else name

def _msp_vfs_fwalk_open_dir(path, dir_fd=None):
    flags = getattr(_msp_vfs_os, "O_RDONLY", 0)
    flags |= getattr(_msp_vfs_os, "O_NONBLOCK", 0)
    if dir_fd is None:
        return _msp_vfs_os_open(path, flags)
    return _msp_vfs_os_open(path, flags, dir_fd=dir_fd)

def _msp_vfs_fwalk_child_is_symlink(name, dir_fd):
    try:
        return _msp_vfs_stat.S_ISLNK(_msp_vfs_lstat_call(name, dir_fd=dir_fd).st_mode)
    except OSError:
        return False

def _msp_vfs_fwalk_rows(display_path, open_path, parent_fd, is_root, topdown, onerror, follow_symlinks, bytes_mode):
    fd = None
    try:
        if not follow_symlinks:
            original_stat = _msp_vfs_lstat_call(open_path, dir_fd=parent_fd)
            if not _msp_vfs_stat.S_ISDIR(original_stat.st_mode):
                return
        fd = _msp_vfs_fwalk_open_dir(open_path, dir_fd=parent_fd)
    except OSError as error:
        if is_root:
            raise
        if onerror is not None:
            onerror(error)
        return
    try:
        entries = list(_msp_vfs_scandir(fd))
        dirnames = []
        filenames = []
        recurse_entries = {}
        for entry in entries:
            name = entry.name
            display_name = _msp_vfs_fwalk_display_name(name, bytes_mode)
            try:
                is_dir = entry.is_dir()
            except OSError:
                is_dir = False
            if is_dir:
                dirnames.append(display_name)
                if follow_symlinks or not _msp_vfs_fwalk_child_is_symlink(name, fd):
                    recurse_entries[display_name] = name
            else:
                filenames.append(display_name)
        if topdown:
            yield display_path, dirnames, filenames, fd
        for display_name in list(dirnames):
            child_name = recurse_entries.get(display_name)
            if child_name is None:
                continue
            child_display_path = _msp_vfs_os.path.join(display_path, display_name)
            yield from _msp_vfs_fwalk_rows(
                child_display_path,
                child_name,
                fd,
                False,
                topdown,
                onerror,
                follow_symlinks,
                bytes_mode
            )
        if not topdown:
            yield display_path, dirnames, filenames, fd
    finally:
        if fd is not None:
            _msp_vfs_os_close(fd)

def _msp_vfs_fwalk(top=".", topdown=True, onerror=None, *, follow_symlinks=False, dir_fd=None):
    if _MSP_VFS_REAL_OPEN_FD is None:
        raise PermissionError("os.open is unavailable")
    _msp_vfs_sys.audit("os.fwalk", top, topdown, onerror, follow_symlinks, dir_fd)
    raw_top = _msp_vfs_os.fspath(top)
    bytes_mode = isinstance(raw_top, bytes)
    yield from _msp_vfs_fwalk_rows(
        raw_top,
        raw_top,
        dir_fd,
        True,
        bool(topdown),
        onerror,
        bool(follow_symlinks),
        bytes_mode
    )
"""#
}
