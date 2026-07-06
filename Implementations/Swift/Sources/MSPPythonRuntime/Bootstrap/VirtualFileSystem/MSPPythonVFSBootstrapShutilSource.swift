enum MSPPythonVFSBootstrapShutilSource {
    static let source = #"""
def _msp_vfs_copyfile(src, dst, *args, **kwargs):
    source_virtual_path = _msp_vfs_virtual_path(src)
    destination_virtual_path = _msp_vfs_virtual_path(dst)
    if _msp_vfs_os.path.normpath(source_virtual_path) == _msp_vfs_os.path.normpath(destination_virtual_path):
        raise _msp_vfs_shutil.SameFileError("%r and %r are the same file" % (src, dst))
    try:
        if _msp_vfs_os.path.samefile(src, dst):
            raise _msp_vfs_shutil.SameFileError("%r and %r are the same file" % (src, dst))
    except OSError:
        pass
    with _msp_vfs_open(src, "rb") as source_file:
        data = source_file.read()
    with _msp_vfs_open(dst, "wb") as destination_file:
        destination_file.write(data)
    return dst

def _msp_vfs_shutil_destination(src, dst):
    source_path = _msp_vfs_os.fspath(src)
    destination_path = _msp_vfs_os.fspath(dst)
    if _msp_vfs_isdir(destination_path):
        destination = _msp_vfs_os.path.join(destination_path, _msp_vfs_os.path.basename(source_path))
        return destination, destination
    return destination_path, dst

def _msp_vfs_copymode(src, dst, follow_symlinks=True):
    source_mode = _msp_vfs_stat.S_IMODE(_msp_vfs_os.stat(src, follow_symlinks=follow_symlinks).st_mode)
    _msp_vfs_os.chmod(dst, source_mode, follow_symlinks=follow_symlinks)

def _msp_vfs_copy(src, dst, *args, **kwargs):
    follow_symlinks = kwargs.get("follow_symlinks", True)
    destination, result = _msp_vfs_shutil_destination(src, dst)
    _msp_vfs_copyfile(src, destination, *args, **kwargs)
    _msp_vfs_copymode(src, destination, follow_symlinks=follow_symlinks)
    return result

def _msp_vfs_copy2(src, dst, *args, **kwargs):
    follow_symlinks = kwargs.get("follow_symlinks", True)
    destination, result = _msp_vfs_shutil_destination(src, dst)
    _msp_vfs_copyfile(src, destination, *args, **kwargs)
    _msp_vfs_shutil.copystat(src, destination, follow_symlinks=follow_symlinks)
    return result

def _msp_vfs_copytree(src, dst, symlinks=False, ignore=None, copy_function=None, ignore_dangling_symlinks=False, dirs_exist_ok=False):
    source_path = _msp_vfs_os.fspath(src)
    destination_path = _msp_vfs_os.fspath(dst)
    names = _msp_vfs_listdir(source_path)
    ignored_names = set(ignore(source_path, names)) if ignore is not None else set()
    _msp_vfs_makedirs(destination_path, exist_ok=dirs_exist_ok)
    copier = copy_function or _msp_vfs_copy2
    errors = []
    for name in names:
        if name in ignored_names:
            continue
        source_entry = _msp_vfs_os.path.join(source_path, name)
        destination_entry = _msp_vfs_os.path.join(destination_path, name)
        try:
            if _msp_vfs_isdir(source_entry):
                _msp_vfs_copytree(
                    source_entry,
                    destination_entry,
                    symlinks=symlinks,
                    ignore=ignore,
                    copy_function=copier,
                    ignore_dangling_symlinks=ignore_dangling_symlinks,
                    dirs_exist_ok=dirs_exist_ok,
                )
            else:
                copier(source_entry, destination_entry)
        except _msp_vfs_shutil.Error as error:
            errors.extend(error.args[0] if error.args else [str(error)])
        except OSError as error:
            errors.append((source_entry, destination_entry, str(error)))
    if errors:
        raise _msp_vfs_shutil.Error(errors)
    return dst

def _msp_vfs_move(src, dst, *args, **kwargs):
    source_virtual_path = _msp_vfs_absolute_virtual_path(src)
    destination_root_virtual_path = _msp_vfs_absolute_virtual_path(dst)
    if _msp_vfs_isdir(src):
        try:
            common_path = _msp_vfs_os.path.commonpath([source_virtual_path, destination_root_virtual_path])
        except ValueError:
            common_path = None
        if common_path == source_virtual_path and destination_root_virtual_path != source_virtual_path:
            raise _msp_vfs_shutil.Error(
                "Cannot move a directory '%s' into itself '%s'."
                % (_msp_vfs_os.fspath(src), _msp_vfs_os.fspath(dst))
            )
    destination, result = _msp_vfs_shutil_destination(src, dst)
    if destination != _msp_vfs_os.fspath(dst) and _msp_vfs_exists(destination):
        raise _msp_vfs_shutil.Error("Destination path '%s' already exists" % destination)
    _msp_vfs_replace(src, destination)
    return result

def _msp_vfs_rmtree(path, *args, **kwargs):
    ignore_errors = False
    if args:
        ignore_errors = bool(args[0])
    if "ignore_errors" in kwargs:
        ignore_errors = bool(kwargs["ignore_errors"])
    onerror = args[1] if len(args) > 1 else None
    if "onerror" in kwargs:
        onerror = kwargs["onerror"]
    onexc = kwargs.get("onexc", None)
    dir_fd = kwargs.get("dir_fd", None)

    def _msp_vfs_rmtree_error(function, error):
        if ignore_errors:
            return
        if onexc is not None:
            onexc(function, path, error)
            return
        if onerror is not None:
            onerror(function, path, (type(error), error, error.__traceback__))
            return
        _msp_vfs_reraise_path_error(error, path)

    try:
        virtual_path = _msp_vfs_virtual_path(path, dir_fd=dir_fd)
        info = _msp_vfs_lstat_call(path, dir_fd=dir_fd)
        if not _msp_vfs_stat.S_ISDIR(info.st_mode):
            raise NotADirectoryError(_msp_vfs_errno.ENOTDIR, "Not a directory", path)
    except OSError as error:
        _msp_vfs_rmtree_error(_msp_vfs_os.lstat, error)
        return

    try:
        _msp_vfs_request("remove", path=virtual_path, recursive=True)
    except OSError as error:
        _msp_vfs_rmtree_error(_msp_vfs_os.scandir, error)
"""#
}
