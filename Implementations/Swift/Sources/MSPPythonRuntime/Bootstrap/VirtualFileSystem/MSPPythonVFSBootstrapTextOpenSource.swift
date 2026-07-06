enum MSPPythonVFSBootstrapTextOpenSource {
    static let source = #"""
def _msp_vfs_mode_writes(mode):
    text = "r" if mode is None else str(mode)
    return any(marker in text for marker in ("w", "a", "x", "+"))

def _msp_vfs_mode_is_text(mode):
    return "b" not in str("r" if mode is None else mode)

def _msp_vfs_is_default_text_encoding(encoding):
    if encoding is None:
        return True
    try:
        return str(encoding).lower() == "locale"
    except Exception:
        return False

def _msp_vfs_text_open_args(args, kwargs):
    mode = kwargs.get("mode")
    if mode is None and args:
        mode = args[0]
    mode = "r" if mode is None else mode
    if not _msp_vfs_mode_is_text(mode):
        return args, kwargs
    if "encoding" in kwargs:
        if _msp_vfs_is_default_text_encoding(kwargs.get("encoding")):
            kwargs = dict(kwargs)
            kwargs["encoding"] = "utf-8"
        return args, kwargs
    if len(args) >= 3:
        if _msp_vfs_is_default_text_encoding(args[2]):
            updated_args = list(args)
            updated_args[2] = "utf-8"
            return tuple(updated_args), kwargs
        return args, kwargs
    kwargs = dict(kwargs)
    kwargs["encoding"] = "utf-8"
    return args, kwargs

def _msp_vfs_flags_write(flags):
    try:
        value = int(flags)
    except Exception:
        return False
    write_mask = _msp_vfs_os.O_WRONLY | _msp_vfs_os.O_RDWR | _msp_vfs_os.O_CREAT | _msp_vfs_os.O_TRUNC | _msp_vfs_os.O_APPEND
    return (value & write_mask) != 0

def _msp_vfs_audit_open_write(args):
    if len(args) > 2 and isinstance(args[2], int):
        return _msp_vfs_flags_write(args[2])
    if len(args) > 1:
        mode_or_flags = args[1]
        if isinstance(mode_or_flags, int):
            return _msp_vfs_flags_write(mode_or_flags)
        return _msp_vfs_mode_writes(mode_or_flags)
    return False
"""#
}
