enum MSPPythonVFSBootstrapPathlibSource {
    static let source = #"""
def _msp_vfs_pathlib_virtual_str(self):
    raw = _MSP_VFS_REAL_PUREPATH_STR(self)
    if not _msp_vfs_os.path.isabs(raw):
        return raw
    return _msp_vfs_virtualize_real_path(raw)

def _msp_vfs_pathlib_pattern_text(pattern):
    raw = _msp_vfs_os.fspath(pattern)
    if isinstance(raw, bytes):
        raise TypeError("argument should be a str or an os.PathLike object where __fspath__ returns a str, not 'bytes'")
    if _msp_vfs_os.path.isabs(raw):
        raise NotImplementedError("Non-relative patterns are unsupported")
    return raw

def _msp_vfs_pathlib_pattern_parts(pattern):
    text = _msp_vfs_pathlib_pattern_text(pattern)
    if text in ("", "."):
        raise ValueError("Unacceptable pattern: PosixPath('.')")
    directory_only = text.endswith("/")
    parts = [part for part in _msp_vfs_pathlib.PurePosixPath(text).parts if part not in ("", ".")]
    return parts, directory_only

def _msp_vfs_pathlib_glob_options(args, kwargs, method_name):
    if args:
        raise TypeError("Path.%s() takes 2 positional arguments but %d were given" % (method_name, len(args) + 2))
    allowed = {"case_sensitive", "recurse_symlinks"}
    for key in kwargs:
        if key not in allowed:
            raise TypeError("Path.%s() got an unexpected keyword argument '%s'" % (method_name, key))
    case_sensitive = kwargs.get("case_sensitive", None)
    if case_sensitive is not None:
        case_sensitive = bool(case_sensitive)
    recurse_symlinks = bool(kwargs.get("recurse_symlinks", False))
    return case_sensitive, recurse_symlinks

def _msp_vfs_pathlib_name_matches(name, pattern, case_sensitive):
    if case_sensitive is False:
        return _msp_vfs_fnmatch.fnmatchcase(name.casefold(), pattern.casefold())
    return _msp_vfs_fnmatch.fnmatchcase(name, pattern)

def _msp_vfs_pathlib_scan(path):
    try:
        with _msp_vfs_os.scandir(path) as iterator:
            return list(iterator)
    except OSError:
        return []

def _msp_vfs_pathlib_should_descend(entry, recurse_symlinks):
    try:
        if recurse_symlinks:
            return entry.is_dir()
        return entry.is_dir(follow_symlinks=False)
    except OSError:
        return False

def _msp_vfs_pathlib_can_descend_explicit(entry):
    try:
        return entry.is_dir()
    except OSError:
        return False

def _msp_vfs_pathlib_walk_final_recursive(current_path, directory_only, recurse_symlinks):
    yield current_path
    for entry in _msp_vfs_pathlib_scan(current_path):
        should_descend = _msp_vfs_pathlib_should_descend(entry, recurse_symlinks)
        if directory_only:
            if should_descend:
                yield from _msp_vfs_pathlib_walk_final_recursive(
                    entry.path,
                    directory_only,
                    recurse_symlinks
                )
            continue
        if should_descend:
            yield from _msp_vfs_pathlib_walk_final_recursive(
                entry.path,
                directory_only,
                recurse_symlinks
            )
        else:
            yield entry.path

def _msp_vfs_pathlib_walk(current_path, parts, index, case_sensitive, recurse_symlinks, directory_only):
    if index >= len(parts):
        yield current_path
        return
    part = parts[index]
    if part == "**":
        if index == len(parts) - 1:
            yield from _msp_vfs_pathlib_walk_final_recursive(
                current_path,
                directory_only,
                recurse_symlinks
            )
            return
        else:
            yield from _msp_vfs_pathlib_walk(
                current_path,
                parts,
                index + 1,
                case_sensitive,
                recurse_symlinks,
                directory_only
            )
        for entry in _msp_vfs_pathlib_scan(current_path):
            if _msp_vfs_pathlib_should_descend(entry, recurse_symlinks):
                yield from _msp_vfs_pathlib_walk(
                    entry.path,
                    parts,
                    index,
                    case_sensitive,
                    recurse_symlinks,
                    directory_only
                )
        return
    for entry in _msp_vfs_pathlib_scan(current_path):
        if not _msp_vfs_pathlib_name_matches(entry.name, part, case_sensitive):
            continue
        if index == len(parts) - 1:
            if not directory_only or _msp_vfs_pathlib_can_descend_explicit(entry):
                yield entry.path
        elif _msp_vfs_pathlib_can_descend_explicit(entry):
            yield from _msp_vfs_pathlib_walk(
                entry.path,
                parts,
                index + 1,
                case_sensitive,
                recurse_symlinks,
                directory_only
            )

def _msp_vfs_pathlib_glob(self, pattern, *args, **kwargs):
    raw_self = _MSP_VFS_REAL_PUREPATH_STR(self)
    relative_self = not _msp_vfs_os.path.isabs(raw_self)
    parts, directory_only = _msp_vfs_pathlib_pattern_parts(pattern)
    case_sensitive, recurse_symlinks = _msp_vfs_pathlib_glob_options(args, kwargs, "glob")
    base_virtual = _msp_vfs_absolute_virtual_path(raw_self)
    for match in _msp_vfs_pathlib_walk(
        _msp_vfs_os.fspath(self),
        parts,
        0,
        case_sensitive,
        recurse_symlinks,
        directory_only
    ):
        raw_match = _msp_vfs_os.fspath(match)
        if relative_self and not _msp_vfs_os.path.isabs(raw_match):
            yield _msp_vfs_pathlib.Path(raw_match)
            continue
        virtual = _msp_vfs_virtualize_real_path(raw_match)
        if relative_self and isinstance(virtual, str):
            try:
                yield _msp_vfs_pathlib.Path(_msp_vfs_raw_relpath(virtual, base_virtual))
            except Exception:
                yield _msp_vfs_pathlib.Path(virtual)
        else:
            yield _msp_vfs_pathlib.Path(virtual)

def _msp_vfs_pathlib_rglob(self, pattern, *args, **kwargs):
    case_sensitive, recurse_symlinks = _msp_vfs_pathlib_glob_options(args, kwargs, "rglob")
    pattern_text = _msp_vfs_pathlib_pattern_text(pattern)
    yield from _msp_vfs_pathlib_glob(
        self,
        _msp_vfs_os.path.join("**", pattern_text),
        case_sensitive=case_sensitive,
        recurse_symlinks=recurse_symlinks
    )

def _msp_vfs_pathlib_walk_arguments(args, kwargs):
    if len(args) > 3:
        raise TypeError("Path.walk() takes from 1 to 4 positional arguments but %d were given" % (len(args) + 1))
    names = ("top_down", "on_error", "follow_symlinks")
    values = [True, None, False]
    for index, value in enumerate(args):
        values[index] = value
    for key, value in kwargs.items():
        if key not in names:
            raise TypeError("Path.walk() got an unexpected keyword argument '%s'" % key)
        index = names.index(key)
        if index < len(args):
            raise TypeError("Path.walk() got multiple values for argument '%s'" % key)
        values[index] = value
    return bool(values[0]), values[1], bool(values[2])

def _msp_vfs_pathlib_walk_scan(path, on_error):
    try:
        with _msp_vfs_os.scandir(path) as iterator:
            return list(iterator)
    except OSError as error:
        if on_error is not None:
            on_error(error)
        return None

def _msp_vfs_pathlib_walk_rows(path, top_down, on_error, follow_symlinks):
    entries = _msp_vfs_pathlib_walk_scan(path, on_error)
    if entries is None:
        return
    dirnames = []
    filenames = []
    for entry in entries:
        try:
            is_dir = entry.is_dir(follow_symlinks=follow_symlinks)
        except OSError:
            is_dir = False
        if is_dir:
            dirnames.append(entry.name)
        else:
            filenames.append(entry.name)
    if top_down:
        yield path, dirnames, filenames
    for name in dirnames:
        yield from _msp_vfs_pathlib_walk_rows(
            path / name,
            top_down,
            on_error,
            follow_symlinks
        )
    if not top_down:
        yield path, dirnames, filenames

def _msp_vfs_pathlib_walk_method(self, *args, **kwargs):
    top_down, on_error, follow_symlinks = _msp_vfs_pathlib_walk_arguments(args, kwargs)
    yield from _msp_vfs_pathlib_walk_rows(self, top_down, on_error, follow_symlinks)

def _msp_vfs_pathlib_home(cls):
    return cls(_msp_vfs_virtual_home())

def _msp_vfs_pathlib_expanduser(self):
    raw = _MSP_VFS_REAL_PUREPATH_STR(self)
    expanded = _msp_vfs_expanduser(raw)
    if expanded == raw and isinstance(raw, str) and raw.startswith("~"):
        raise RuntimeError("Could not determine home directory.")
    return self.__class__(expanded)

def _msp_vfs_pathlib_resolve(self, strict=False):
    raw = _MSP_VFS_REAL_PUREPATH_STR(self)
    resolved = _msp_vfs_realpath(raw, strict=strict)
    return _msp_vfs_pathlib.Path(resolved)

def _msp_vfs_pathlib_stat(self, *args, **kwargs):
    return _msp_vfs_stat_call(self, *args, **kwargs)

def _msp_vfs_pathlib_lstat(self, *args, **kwargs):
    if args:
        raise TypeError("Path.lstat() takes 1 positional argument but %d were given" % (len(args) + 1))
    if kwargs:
        key = next(iter(kwargs))
        raise TypeError("Path.lstat() got an unexpected keyword argument '%s'" % key)
    return _msp_vfs_lstat_call(self)

def _msp_vfs_pathlib_chmod(self, mode, *args, **kwargs):
    if args:
        raise TypeError("Path.chmod() takes 2 positional arguments but %d were given" % (len(args) + 2))
    allowed = {"follow_symlinks"}
    for key in kwargs:
        if key not in allowed:
            raise TypeError("Path.chmod() got an unexpected keyword argument '%s'" % key)
    return _msp_vfs_chmod(self, mode)

def _msp_vfs_pathlib_touch(self, mode=0o666, exist_ok=True):
    virtual_path = _msp_vfs_absolute_virtual_path(self)
    try:
        _msp_vfs_stat_call(self)
    except FileNotFoundError:
        try:
            _msp_vfs_request(
                "write_file",
                path=virtual_path,
                data_b64="",
                overwrite=False,
                creation_mode=_msp_vfs_apply_umask(mode)
            )
            return None
        except OSError as error:
            _msp_vfs_reraise_path_error(error, self, force=True)
    if not exist_ok:
        raise FileExistsError(_msp_vfs_errno.EEXIST, "File exists", virtual_path)
    _msp_vfs_request("utime", path=virtual_path, modification_time=None)
    return None
"""#
}
