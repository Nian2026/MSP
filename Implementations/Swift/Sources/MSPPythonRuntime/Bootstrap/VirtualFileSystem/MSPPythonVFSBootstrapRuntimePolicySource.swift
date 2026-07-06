enum MSPPythonVFSBootstrapRuntimePolicySource {
    static let source = #"""
def _msp_vfs_under(path, prefix):
    if not path or not prefix:
        return False
    path = _msp_vfs_os.path.normpath(path)
    prefix = _msp_vfs_os.path.normpath(prefix)
    return path == prefix or path.startswith(prefix.rstrip(_msp_vfs_os.sep) + _msp_vfs_os.sep)

def _msp_vfs_blocked_import_root(name):
    text = str(name or "")
    return text.split(".", 1)[0]

def _msp_vfs_blocked_import_error(name):
    root = _msp_vfs_blocked_import_root(name)
    if root in _MSP_VFS_BLOCKED_PACKAGE_INSTALL_MODULES:
        return PermissionError("package installation is not supported in MSP Python runtime")
    if root in _MSP_VFS_BLOCKED_RUNTIME_MODULES:
        return PermissionError(root + " is not allowed in MSP Python runtime")
    return None

def _msp_vfs_guarded_import(name, globals=None, locals=None, fromlist=(), level=0):
    blocked_error = _msp_vfs_blocked_import_error(name) if level == 0 else None
    if blocked_error is not None:
        raise blocked_error
    return _MSP_VFS_REAL_IMPORT(name, globals, locals, fromlist, level)

def _msp_vfs_guarded_import_module(name, package=None):
    blocked_error = _msp_vfs_blocked_import_error(name)
    if blocked_error is not None:
        raise blocked_error
    return _MSP_VFS_REAL_IMPORT_MODULE(name, package)

def _msp_vfs_operation_blocked(*args, **kwargs):
    raise PermissionError("operation is not allowed in MSP Python runtime")

def _msp_vfs_internal_write_prefixes():
    prefixes = [
        _MSP_VFS_BROKER_DIR,
        _MSP_VFS_MATERIALIZED_DIR,
        _MSP_VFS_SUBPROCESS_BROKER_DIR,
        _MSP_VFS_RESULT_PATH,
    ]
    return [_msp_vfs_os.path.normpath(p) for p in prefixes if p]

def _msp_vfs_runtime_read_prefixes():
    executable_dir = _msp_vfs_os.path.dirname(getattr(_msp_vfs_sys, "executable", "") or "")
    prefixes = [
        getattr(_msp_vfs_sys, "prefix", ""),
        getattr(_msp_vfs_sys, "exec_prefix", ""),
        executable_dir,
        _msp_vfs_os.path.dirname(executable_dir) if executable_dir else "",
    ]
    return (
        [_msp_vfs_os.path.normpath(p) for p in prefixes if p]
        + list(_MSP_VFS_RUNTIME_REAL_TO_VIRTUAL.keys())
    )

def _msp_vfs_runtime_prefixes():
    return _msp_vfs_internal_write_prefixes() + _msp_vfs_runtime_read_prefixes()

def _msp_vfs_is_internal_real_path(value):
    try:
        raw = _msp_vfs_path_text(value)
    except TypeError:
        return False
    if not isinstance(raw, str) or not _msp_vfs_os.path.isabs(raw):
        return False
    absolute = _msp_vfs_os.path.normpath(_MSP_VFS_REAL_PATH_ABSPATH(raw))
    if any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_internal_write_prefixes()):
        return True
    if _MSP_VFS_WORKSPACE_ROOT and _msp_vfs_under(absolute, _MSP_VFS_WORKSPACE_ROOT):
        return False
    return any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_runtime_read_prefixes())

def _msp_vfs_real_path_allowed(value, write=False, allow_chdir=False):
    try:
        raw = _msp_vfs_path_text(value)
    except TypeError:
        return True
    if isinstance(raw, int) or raw is None:
        return True
    if not isinstance(raw, str) or raw == "":
        return True
    if raw in {_msp_vfs_os.devnull, "/dev/random", "/dev/urandom"}:
        return True
    absolute = _msp_vfs_os.path.normpath(_MSP_VFS_REAL_PATH_ABSPATH(raw))
    if any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_internal_write_prefixes()):
        return True
    if _MSP_VFS_WORKSPACE_ROOT and _msp_vfs_under(absolute, _MSP_VFS_WORKSPACE_ROOT):
        return False
    if not write and not allow_chdir:
        return any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_runtime_read_prefixes())
    return False

def _msp_vfs_audit_real_path(value, write=False, allow_chdir=False):
    if _msp_vfs_real_path_allowed(value, write=write, allow_chdir=allow_chdir):
        return
    raise PermissionError("path escapes MSP Python virtual filesystem")
"""#
}
