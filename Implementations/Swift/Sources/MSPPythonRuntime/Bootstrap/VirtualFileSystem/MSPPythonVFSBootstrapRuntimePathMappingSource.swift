enum MSPPythonVFSBootstrapRuntimePathMappingSource {
    static let source = #"""
def _msp_vfs_register_runtime_virtual_path(real_path, virtual_path):
    if not real_path or not virtual_path:
        return
    try:
        normalized = _msp_vfs_os.path.normpath(_MSP_VFS_REAL_PATH_ABSPATH(real_path))
    except Exception:
        return
    if normalized in ("/", "."):
        return
    _MSP_VFS_RUNTIME_REAL_TO_VIRTUAL[normalized] = virtual_path
    try:
        resolved = _msp_vfs_os.path.normpath(_MSP_VFS_REAL_PATH_REALPATH(real_path))
    except Exception:
        resolved = ""
    if resolved and resolved not in ("/", "."):
        _MSP_VFS_RUNTIME_REAL_TO_VIRTUAL[resolved] = virtual_path

def _msp_vfs_seed_runtime_virtual_paths():
    version = "python%d.%d" % (_msp_vfs_sys.version_info.major, _msp_vfs_sys.version_info.minor)
    virtual_stdlib = "/usr/lib/" + version
    try:
        stdlib_file = getattr(_msp_vfs_os, "__file__", "") or ""
        if stdlib_file:
            _msp_vfs_register_runtime_virtual_path(_msp_vfs_os.path.dirname(stdlib_file), virtual_stdlib)
    except Exception:
        pass
    for search_path in list(getattr(_msp_vfs_sys, "path", []) or []):
        if not isinstance(search_path, str) or not search_path:
            continue
        try:
            normalized = _msp_vfs_os.path.normpath(_MSP_VFS_REAL_PATH_ABSPATH(search_path))
        except Exception:
            continue
        marker = _msp_vfs_os.sep + version
        index = normalized.find(marker)
        if index >= 0:
            _msp_vfs_register_runtime_virtual_path(
                normalized[:index + len(marker)],
                virtual_stdlib
            )
    for prefix in (
        getattr(_msp_vfs_sys, "prefix", ""),
        getattr(_msp_vfs_sys, "base_prefix", ""),
        getattr(_msp_vfs_sys, "exec_prefix", ""),
        getattr(_msp_vfs_sys, "base_exec_prefix", ""),
    ):
        if prefix:
            _msp_vfs_register_runtime_virtual_path(prefix, "/usr")
    executable = getattr(_msp_vfs_sys, "executable", "")
    if executable:
        _msp_vfs_register_runtime_virtual_path(executable, "/usr/bin/python3")
        _msp_vfs_register_runtime_virtual_path(_msp_vfs_os.path.dirname(executable), "/usr/bin")

_msp_vfs_seed_runtime_virtual_paths()

def _msp_vfs_apply_umask(mode):
    return (int(mode) & ~_MSP_VFS_FILE_CREATION_MASK) & 0o777
"""#
}
