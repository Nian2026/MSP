enum MSPPythonVFSBootstrapFileOpenSource {
    static let source = #"""
def _msp_vfs_file_display_name(file, virtual_path):
    try:
        raw = _msp_vfs_os.fspath(file)
    except TypeError:
        return virtual_path
    if isinstance(raw, bytes):
        raw_text = _msp_vfs_os.fsdecode(raw)
        virtualized = _msp_vfs_virtualize_real_path(raw_text)
        if isinstance(virtualized, str) and virtualized != raw_text:
            return _msp_vfs_os.fsencode(virtualized)
        if _msp_vfs_os.path.isabs(raw_text):
            return _msp_vfs_os.fsencode(_msp_vfs_os.path.normpath(raw_text))
        return raw
    if not isinstance(raw, str):
        return virtual_path
    virtualized = _msp_vfs_virtualize_real_path(raw)
    if isinstance(virtualized, str) and virtualized != raw:
        return virtualized
    if _msp_vfs_os.path.isabs(raw):
        return _msp_vfs_os.path.normpath(raw)
    return raw

def _msp_vfs_wrap_file_facet(value, display_name):
    try:
        getattr(value, "name")
    except Exception:
        return value
    return _MSPPythonVFSFileFacet(value, display_name)

def _msp_vfs_display_name_value(display_name):
    return display_name[0] if isinstance(display_name, list) else display_name

def _msp_vfs_file_name(value, display_name):
    candidates = [value]
    try:
        candidates.append(getattr(value, "buffer"))
    except Exception:
        pass
    try:
        candidates.append(getattr(candidates[-1], "raw"))
    except Exception:
        pass
    for candidate in candidates:
        try:
            raw_name = getattr(candidate, "name")
        except Exception:
            continue
        if isinstance(raw_name, int):
            return raw_name
    return _msp_vfs_display_name_value(display_name)

def _msp_vfs_update_file_display_name(display_name_ref, value):
    if isinstance(value, int):
        display_name_ref[0] = value
        return
    current = display_name_ref[0]
    if isinstance(current, (bytes, int)):
        return
    virtualized = _msp_vfs_virtualize_real_path(value)
    if not isinstance(current, str) or not isinstance(virtualized, str):
        return
    if not _msp_vfs_os.path.isabs(current):
        return
    current_path = _msp_vfs_os.path.normpath(current)
    virtualized_path = _msp_vfs_os.path.normpath(virtualized)
    if virtualized_path == current_path or virtualized_path.startswith(current_path.rstrip("/") + "/"):
        display_name_ref[0] = virtualized_path

class _MSPPythonVFSFileFacet:
    def __init__(self, value, display_name):
        self._msp_value = value
        self._msp_display_name_ref = display_name if isinstance(display_name, list) else [display_name]

    def __getattr__(self, name):
        attribute = getattr(self._msp_value, name)
        if callable(attribute):
            def _msp_vfs_file_facet_method(*args, **kwargs):
                return _msp_vfs_wrap_file_facet(attribute(*args, **kwargs), self._msp_display_name_ref)
            return _msp_vfs_file_facet_method
        return _msp_vfs_wrap_file_facet(attribute, self._msp_display_name_ref)

    @property
    def name(self):
        return _msp_vfs_file_name(self._msp_value, self._msp_display_name_ref)

    @name.setter
    def name(self, value):
        _msp_vfs_update_file_display_name(self._msp_display_name_ref, value)
        try:
            setattr(self._msp_value, "name", value)
        except Exception:
            pass

    def __repr__(self):
        text = repr(self._msp_value)
        try:
            raw_name = getattr(self._msp_value, "name")
            return text.replace(repr(raw_name), repr(self.name))
        except Exception:
            return _msp_vfs_virtualize_text(text)

    def __iter__(self):
        return iter(self._msp_value)

    def __next__(self):
        return next(self._msp_value)

    def __enter__(self):
        enter = getattr(self._msp_value, "__enter__", None)
        if callable(enter):
            enter()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        exit_method = getattr(self._msp_value, "__exit__", None)
        if callable(exit_method):
            return exit_method(exc_type, exc_value, traceback)
        return False

class _MSPPythonVFSFile:
    def __init__(self, file_object, real_path, display_name, owns_fd=True):
        self._msp_file = file_object
        self._msp_real_path = real_path
        self._msp_display_name_ref = [display_name]
        self._msp_owns_fd = bool(owns_fd)
        _MSP_VFS_OPEN_FILE_WRAPPERS.add(self)
        try:
            _msp_vfs_track_fd_real_path(file_object.fileno(), real_path)
        except Exception:
            pass

    def __getattr__(self, name):
        attribute = getattr(self._msp_file, name)
        if callable(attribute):
            def _msp_vfs_file_method(*args, **kwargs):
                return _msp_vfs_wrap_file_facet(
                    getattr(self._msp_file, name)(*args, **kwargs),
                    self._msp_display_name_ref
                )
            return _msp_vfs_file_method
        return _msp_vfs_wrap_file_facet(attribute, self._msp_display_name_ref)

    @property
    def name(self):
        return _msp_vfs_file_name(self._msp_file, self._msp_display_name_ref)

    @name.setter
    def name(self, value):
        _msp_vfs_update_file_display_name(self._msp_display_name_ref, value)
        try:
            setattr(self._msp_file, "name", value)
        except Exception:
            pass

    def __repr__(self):
        text = repr(self._msp_file)
        try:
            raw_name = getattr(self._msp_file, "name")
            return text.replace(repr(raw_name), repr(self.name))
        except Exception:
            return _msp_vfs_virtualize_text(text)

    def __iter__(self):
        return self

    def __next__(self):
        return next(self._msp_file)

    def __enter__(self):
        self._msp_file.__enter__()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False

    def close(self):
        if not self._msp_file.closed:
            fd = None
            try:
                fd = int(self._msp_file.fileno())
            except Exception:
                pass
            if fd is not None and self._msp_owns_fd:
                _MSP_VFS_FD_REAL_PATHS.pop(fd, None)
                _MSP_VFS_FD_WRITEBACKS.pop(fd, None)
            self._msp_file.flush()
            self._msp_file.close()
            if self._msp_owns_fd:
                _msp_vfs_finalize_writeback(self._msp_real_path)
            else:
                _msp_vfs_writeback_snapshot(self._msp_real_path)
        try:
            _MSP_VFS_OPEN_FILE_WRAPPERS.discard(self)
        except Exception:
            pass

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

def _msp_vfs_open(file, *args, _open=_MSP_VFS_REAL_OPEN, **kwargs):
    if isinstance(file, int):
        args, kwargs = _msp_vfs_text_open_args(args, kwargs)
        real_path = _msp_vfs_tracked_real_path_for_fd(file)
        opened = _open(file, *args, **kwargs)
        if real_path is not None:
            return _MSPPythonVFSFile(
                opened,
                real_path,
                file,
                owns_fd=_msp_vfs_open_owns_fd(args, kwargs)
            )
        return opened
    if _msp_vfs_is_internal_real_path(file):
        args, kwargs = _msp_vfs_text_open_args(args, kwargs)
        return _open(file, *args, **kwargs)
    mode = kwargs.get("mode")
    if mode is None and args:
        mode = args[0]
    mode = "r" if mode is None else mode
    if kwargs.get("opener") is not None and not isinstance(file, _msp_vfs_pathlib.PurePath):
        args, kwargs = _msp_vfs_text_open_args(args, kwargs)
        try:
            opener_label = _msp_vfs_os.fspath(file)
        except TypeError:
            opener_label = None
        if opener_label is not None:
            _MSP_VFS_OPENER_LABEL_PATHS.add(opener_label)
        try:
            opened = _open(file, *args, **kwargs)
        finally:
            if opener_label is not None:
                _MSP_VFS_OPENER_LABEL_PATHS.discard(opener_label)
        if _msp_vfs_mode_writes(mode):
            try:
                fd = opened.fileno()
            except Exception:
                fd = None
            real_path = _MSP_VFS_FD_WRITEBACKS.pop(fd, None) if fd is not None else None
            if real_path is not None:
                return _MSPPythonVFSFile(opened, real_path, opener_label or _msp_vfs_virtualize_real_path(real_path))
        return opened
    try:
        virtual_path = _msp_vfs_absolute_virtual_path(file)
        display_name = _msp_vfs_file_display_name(file, virtual_path)
        real_path = _msp_vfs_materialize(virtual_path, mode=mode)
    except OSError as error:
        _msp_vfs_reraise_path_error(error, file)
    if isinstance(file, _msp_vfs_pathlib.PurePath):
        kwargs.pop("opener", None)
    args, kwargs = _msp_vfs_text_open_args(args, kwargs)
    try:
        opened = _open(real_path, *args, **kwargs)
    except Exception as error:
        _MSP_VFS_WRITEBACKS.pop(real_path, None)
        _MSP_VFS_REAL_TO_VIRTUAL.pop(real_path, None)
        if isinstance(error, OSError):
            _msp_vfs_reraise_path_error(error, file)
        raise
    return _MSPPythonVFSFile(opened, real_path, display_name)

def _msp_vfs_io_open(file, *args, **kwargs):
    return _msp_vfs_open(file, *args, _open=_MSP_VFS_REAL_IO_OPEN, **kwargs)

def _msp_vfs_io_open_code(file, *args, **kwargs):
    if _msp_vfs_is_internal_real_path(file):
        return _MSP_VFS_REAL_IO_OPEN_CODE(file, *args, **kwargs)
    return _msp_vfs_open(file, *args, _open=_MSP_VFS_REAL_IO_OPEN, **kwargs)

def _msp_vfs_fdopen(fd, *args, **kwargs):
    if _MSP_VFS_REAL_FDOPEN is None:
        raise PermissionError("os.fdopen is unavailable")
    args, kwargs = _msp_vfs_text_open_args(args, kwargs)
    real_path = _msp_vfs_tracked_real_path_for_fd(fd)
    opened = _MSP_VFS_REAL_FDOPEN(fd, *args, **kwargs)
    if real_path is not None:
        return _MSPPythonVFSFile(
            opened,
            real_path,
            int(fd),
            owns_fd=_msp_vfs_open_owns_fd(args, kwargs)
        )
    return opened
"""#
}
