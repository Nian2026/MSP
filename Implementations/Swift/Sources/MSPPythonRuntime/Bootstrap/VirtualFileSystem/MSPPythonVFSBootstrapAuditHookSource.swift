enum MSPPythonVFSBootstrapAuditHookSource {
    static let source = #"""
def _msp_vfs_audit_hook(event, args):
    if event == "import" and args:
        blocked_error = _msp_vfs_blocked_import_error(args[0])
        if blocked_error is not None:
            raise blocked_error
        return
    if event == "open" and args:
        try:
            opener_label = _msp_vfs_os.fspath(args[0])
        except TypeError:
            opener_label = None
        if opener_label in _MSP_VFS_OPENER_LABEL_PATHS:
            _MSP_VFS_OPENER_LABEL_PATHS.discard(opener_label)
            return
        _msp_vfs_audit_real_path(args[0], write=_msp_vfs_audit_open_write(args))
        return
    if event == "os.chdir" and args:
        _msp_vfs_audit_real_path(args[0], allow_chdir=True)
        return
    if event in {"os.symlink", "os.link"}:
        raise PermissionError("operation is not allowed in MSP Python runtime")
    if event in {"os.remove", "os.rmdir", "os.mkdir", "os.listdir", "os.scandir", "os.chmod", "os.chflags", "os.utime", "os.truncate", "os.stat"} and args:
        _msp_vfs_audit_real_path(args[0], write=event in {"os.remove", "os.rmdir", "os.mkdir", "os.chmod", "os.chflags", "os.utime", "os.truncate"})
        return
    if event in {"os.rename", "os.replace"} and len(args) >= 2:
        _msp_vfs_audit_real_path(args[0], write=True)
        _msp_vfs_audit_real_path(args[1], write=True)
        return
    if event.startswith("subprocess"):
        raise PermissionError("operation is not allowed in MSP Python runtime")

def _msp_vfs_install_audit_hook():
    if getattr(_msp_vfs_sys, _MSP_VFS_AUDIT_INSTALLED_NAME, False):
        return
    add_audit_hook = getattr(_msp_vfs_sys, "addaudithook", None)
    if callable(add_audit_hook):
        add_audit_hook(_msp_vfs_audit_hook)
        setattr(_msp_vfs_sys, _MSP_VFS_AUDIT_INSTALLED_NAME, True)
"""#
}
