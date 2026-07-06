enum MSPPythonVFSBootstrapOriginalsSource {
    static let source = #"""
_MSP_VFS_ORIGINALS_NAME = "__msp_python_vfs_originals__"
_MSP_VFS_ORIGINALS = getattr(_msp_vfs_sys, _MSP_VFS_ORIGINALS_NAME, None)
if not isinstance(_MSP_VFS_ORIGINALS, dict):
    _MSP_VFS_ORIGINALS = {
        "builtins_import": _msp_vfs_builtins.__import__,
        "builtins_open": _msp_vfs_builtins.open,
        "importlib_import_module": _msp_vfs_importlib.import_module,
        "io_open": _msp_vfs_io.open,
        "io_open_code": getattr(_msp_vfs_io, "open_code", None),
        "os_getcwd": _msp_vfs_os.getcwd,
        "os_getcwdb": getattr(_msp_vfs_os, "getcwdb", None),
        "os_chdir": _msp_vfs_os.chdir,
        "os_listdir": _msp_vfs_os.listdir,
        "os_scandir": _msp_vfs_os.scandir,
        "os_fwalk": getattr(_msp_vfs_os, "fwalk", None),
        "os_stat": _msp_vfs_os.stat,
        "os_lstat": _msp_vfs_os.lstat,
        "os_fstat": getattr(_msp_vfs_os, "fstat", None),
        "os_statvfs": getattr(_msp_vfs_os, "statvfs", None),
        "os_fstatvfs": getattr(_msp_vfs_os, "fstatvfs", None),
        "os_pathconf": getattr(_msp_vfs_os, "pathconf", None),
        "os_fpathconf": getattr(_msp_vfs_os, "fpathconf", None),
        "os_open": getattr(_msp_vfs_os, "open", None),
        "os_close": getattr(_msp_vfs_os, "close", None),
        "os_fdopen": getattr(_msp_vfs_os, "fdopen", None),
        "os_dup": getattr(_msp_vfs_os, "dup", None),
        "os_dup2": getattr(_msp_vfs_os, "dup2", None),
        "os_umask": getattr(_msp_vfs_os, "umask", None),
        "os_mkdir": _msp_vfs_os.mkdir,
        "os_replace": _msp_vfs_os.replace,
        "os_chmod": _msp_vfs_os.chmod,
        "os_chflags": getattr(_msp_vfs_os, "chflags", None),
        "os_utime": _msp_vfs_os.utime,
        "os_truncate": _msp_vfs_os.truncate,
        "os_ftruncate": getattr(_msp_vfs_os, "ftruncate", None),
        "os_makedirs": _msp_vfs_os.makedirs,
        "os_remove": _msp_vfs_os.remove,
        "os_symlink": getattr(_msp_vfs_os, "symlink", None),
        "os_link": getattr(_msp_vfs_os, "link", None),
        "os_access": _msp_vfs_os.access,
        "os_path_exists": _msp_vfs_os.path.exists,
        "os_path_lexists": _msp_vfs_os.path.lexists,
        "os_path_abspath": _msp_vfs_os.path.abspath,
        "os_path_realpath": _msp_vfs_os.path.realpath,
        "os_path_relpath": _msp_vfs_os.path.relpath,
        "os_path_ismount": _msp_vfs_os.path.ismount,
        "os_path_samefile": getattr(_msp_vfs_os.path, "samefile", None),
        "os_path_sameopenfile": getattr(_msp_vfs_os.path, "sameopenfile", None),
        "os_path_samestat": getattr(_msp_vfs_os.path, "samestat", None),
        "purepath_str": _msp_vfs_pathlib.PurePath.__str__,
        "purepath_fspath": _msp_vfs_pathlib.PurePath.__fspath__,
        "shutil_copyfile": _msp_vfs_shutil.copyfile,
        "shutil_copy": _msp_vfs_shutil.copy,
        "shutil_copy2": _msp_vfs_shutil.copy2,
        "shutil_copytree": _msp_vfs_shutil.copytree,
        "shutil_move": _msp_vfs_shutil.move,
        "shutil_rmtree": _msp_vfs_shutil.rmtree,
        "traceback_format_exception": _msp_vfs_traceback.format_exception,
        "traceback_format_exception_only": _msp_vfs_traceback.format_exception_only,
        "traceback_format_exc": _msp_vfs_traceback.format_exc,
        "traceback_format_list": _msp_vfs_traceback.format_list,
        "traceback_format_stack": _msp_vfs_traceback.format_stack,
        "traceback_format_tb": _msp_vfs_traceback.format_tb,
    }
    setattr(_msp_vfs_sys, _MSP_VFS_ORIGINALS_NAME, _MSP_VFS_ORIGINALS)
if "builtins_import" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["builtins_import"] = _msp_vfs_builtins.__import__
if "importlib_import_module" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["importlib_import_module"] = _msp_vfs_importlib.import_module
if "os_getcwdb" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_getcwdb"] = getattr(_msp_vfs_os, "getcwdb", None)
if "os_fwalk" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_fwalk"] = getattr(_msp_vfs_os, "fwalk", None)
if "purepath_str" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["purepath_str"] = _msp_vfs_pathlib.PurePath.__str__
if "purepath_fspath" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["purepath_fspath"] = _msp_vfs_pathlib.PurePath.__fspath__
if "os_umask" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_umask"] = getattr(_msp_vfs_os, "umask", None)
if "os_mkdir" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_mkdir"] = _msp_vfs_os.mkdir
if "os_symlink" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_symlink"] = getattr(_msp_vfs_os, "symlink", None)
if "os_link" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_link"] = getattr(_msp_vfs_os, "link", None)
if "os_chmod" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_chmod"] = _msp_vfs_os.chmod
if "os_chflags" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_chflags"] = getattr(_msp_vfs_os, "chflags", None)
if "os_utime" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_utime"] = _msp_vfs_os.utime
if "os_truncate" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_truncate"] = _msp_vfs_os.truncate
if "os_ftruncate" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_ftruncate"] = getattr(_msp_vfs_os, "ftruncate", None)
if "os_access" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_access"] = _msp_vfs_os.access
if "os_fstat" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_fstat"] = getattr(_msp_vfs_os, "fstat", None)
if "os_statvfs" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_statvfs"] = getattr(_msp_vfs_os, "statvfs", None)
if "os_fstatvfs" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_fstatvfs"] = getattr(_msp_vfs_os, "fstatvfs", None)
if "os_pathconf" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_pathconf"] = getattr(_msp_vfs_os, "pathconf", None)
if "os_fpathconf" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_fpathconf"] = getattr(_msp_vfs_os, "fpathconf", None)
if "os_fdopen" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_fdopen"] = getattr(_msp_vfs_os, "fdopen", None)
if "os_dup" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_dup"] = getattr(_msp_vfs_os, "dup", None)
if "os_dup2" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_dup2"] = getattr(_msp_vfs_os, "dup2", None)
if "os_path_abspath" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_abspath"] = _msp_vfs_os.path.abspath
if "os_path_lexists" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_lexists"] = _msp_vfs_os.path.lexists
if "os_path_realpath" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_realpath"] = _msp_vfs_os.path.realpath
if "os_path_relpath" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_relpath"] = _msp_vfs_os.path.relpath
if "os_path_ismount" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_ismount"] = _msp_vfs_os.path.ismount
if "os_path_samefile" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_samefile"] = getattr(_msp_vfs_os.path, "samefile", None)
if "os_path_sameopenfile" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_sameopenfile"] = getattr(_msp_vfs_os.path, "sameopenfile", None)
if "os_path_samestat" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["os_path_samestat"] = getattr(_msp_vfs_os.path, "samestat", None)
if "traceback_format_exception" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["traceback_format_exception"] = _msp_vfs_traceback.format_exception
if "traceback_format_exception_only" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["traceback_format_exception_only"] = _msp_vfs_traceback.format_exception_only
if "traceback_format_exc" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["traceback_format_exc"] = _msp_vfs_traceback.format_exc
if "traceback_format_list" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["traceback_format_list"] = _msp_vfs_traceback.format_list
if "traceback_format_stack" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["traceback_format_stack"] = _msp_vfs_traceback.format_stack
if "traceback_format_tb" not in _MSP_VFS_ORIGINALS:
    _MSP_VFS_ORIGINALS["traceback_format_tb"] = _msp_vfs_traceback.format_tb

_MSP_VFS_REAL_IMPORT = _MSP_VFS_ORIGINALS["builtins_import"]
_MSP_VFS_REAL_OPEN = _MSP_VFS_ORIGINALS["builtins_open"]
_MSP_VFS_REAL_IMPORT_MODULE = _MSP_VFS_ORIGINALS["importlib_import_module"]
_MSP_VFS_REAL_IO_OPEN = _MSP_VFS_ORIGINALS["io_open"]
_MSP_VFS_REAL_IO_OPEN_CODE = _MSP_VFS_ORIGINALS["io_open_code"]
_MSP_VFS_REAL_GETCWD = _MSP_VFS_ORIGINALS["os_getcwd"]
_MSP_VFS_REAL_GETCWDB = _MSP_VFS_ORIGINALS["os_getcwdb"]
_MSP_VFS_REAL_CHDIR = _MSP_VFS_ORIGINALS["os_chdir"]
_MSP_VFS_REAL_LISTDIR = _MSP_VFS_ORIGINALS["os_listdir"]
_MSP_VFS_REAL_SCANDIR = _MSP_VFS_ORIGINALS["os_scandir"]
_MSP_VFS_REAL_FWALK = _MSP_VFS_ORIGINALS["os_fwalk"]
_MSP_VFS_REAL_STAT = _MSP_VFS_ORIGINALS["os_stat"]
_MSP_VFS_REAL_LSTAT = _MSP_VFS_ORIGINALS["os_lstat"]
_MSP_VFS_REAL_FSTAT = _MSP_VFS_ORIGINALS["os_fstat"]
_MSP_VFS_REAL_STATVFS = _MSP_VFS_ORIGINALS["os_statvfs"]
_MSP_VFS_REAL_FSTATVFS = _MSP_VFS_ORIGINALS["os_fstatvfs"]
_MSP_VFS_REAL_PATHCONF = _MSP_VFS_ORIGINALS["os_pathconf"]
_MSP_VFS_REAL_FPATHCONF = _MSP_VFS_ORIGINALS["os_fpathconf"]
_MSP_VFS_REAL_OPEN_FD = _MSP_VFS_ORIGINALS["os_open"]
_MSP_VFS_REAL_CLOSE_FD = _MSP_VFS_ORIGINALS["os_close"]
_MSP_VFS_REAL_FDOPEN = _MSP_VFS_ORIGINALS["os_fdopen"]
_MSP_VFS_REAL_DUP = _MSP_VFS_ORIGINALS["os_dup"]
_MSP_VFS_REAL_DUP2 = _MSP_VFS_ORIGINALS["os_dup2"]
_MSP_VFS_REAL_UMASK = _MSP_VFS_ORIGINALS["os_umask"]
_MSP_VFS_REAL_MKDIR = _MSP_VFS_ORIGINALS["os_mkdir"]
_MSP_VFS_REAL_REPLACE = _MSP_VFS_ORIGINALS["os_replace"]
_MSP_VFS_REAL_CHMOD = _MSP_VFS_ORIGINALS["os_chmod"]
_MSP_VFS_REAL_CHFLAGS = _MSP_VFS_ORIGINALS["os_chflags"]
_MSP_VFS_REAL_UTIME = _MSP_VFS_ORIGINALS["os_utime"]
_MSP_VFS_REAL_TRUNCATE = _MSP_VFS_ORIGINALS["os_truncate"]
_MSP_VFS_REAL_FTRUNCATE = _MSP_VFS_ORIGINALS["os_ftruncate"]
_MSP_VFS_REAL_MAKEDIRS = _MSP_VFS_ORIGINALS["os_makedirs"]
_MSP_VFS_REAL_REMOVE = _MSP_VFS_ORIGINALS["os_remove"]
_MSP_VFS_REAL_ACCESS = _MSP_VFS_ORIGINALS["os_access"]
_MSP_VFS_REAL_SYMLINK = _MSP_VFS_ORIGINALS["os_symlink"]
_MSP_VFS_REAL_LINK = _MSP_VFS_ORIGINALS["os_link"]
_MSP_VFS_REAL_PATH_EXISTS = _MSP_VFS_ORIGINALS["os_path_exists"]
_MSP_VFS_REAL_PATH_LEXISTS = _MSP_VFS_ORIGINALS["os_path_lexists"]
_MSP_VFS_REAL_PATH_ABSPATH = _MSP_VFS_ORIGINALS["os_path_abspath"]
_MSP_VFS_REAL_PATH_REALPATH = _MSP_VFS_ORIGINALS["os_path_realpath"]
_MSP_VFS_REAL_PATH_RELPATH = _MSP_VFS_ORIGINALS["os_path_relpath"]
_MSP_VFS_REAL_PATH_ISMOUNT = _MSP_VFS_ORIGINALS["os_path_ismount"]
_MSP_VFS_REAL_PATH_SAMEFILE = _MSP_VFS_ORIGINALS["os_path_samefile"]
_MSP_VFS_REAL_PATH_SAMEOPENFILE = _MSP_VFS_ORIGINALS["os_path_sameopenfile"]
_MSP_VFS_REAL_PATH_SAMESTAT = _MSP_VFS_ORIGINALS["os_path_samestat"]
_MSP_VFS_REAL_PUREPATH_STR = _MSP_VFS_ORIGINALS["purepath_str"]
_MSP_VFS_REAL_SHUTIL_COPYFILE = _MSP_VFS_ORIGINALS["shutil_copyfile"]
_MSP_VFS_REAL_SHUTIL_COPY = _MSP_VFS_ORIGINALS["shutil_copy"]
_MSP_VFS_REAL_SHUTIL_COPY2 = _MSP_VFS_ORIGINALS["shutil_copy2"]
_MSP_VFS_REAL_SHUTIL_COPYTREE = _MSP_VFS_ORIGINALS["shutil_copytree"]
_MSP_VFS_REAL_SHUTIL_MOVE = _MSP_VFS_ORIGINALS["shutil_move"]
_MSP_VFS_REAL_SHUTIL_RMTREE = _MSP_VFS_ORIGINALS["shutil_rmtree"]
_MSP_VFS_REAL_TRACEBACK_FORMAT_EXCEPTION = _MSP_VFS_ORIGINALS["traceback_format_exception"]
_MSP_VFS_REAL_TRACEBACK_FORMAT_EXCEPTION_ONLY = _MSP_VFS_ORIGINALS["traceback_format_exception_only"]
_MSP_VFS_REAL_TRACEBACK_FORMAT_EXC = _MSP_VFS_ORIGINALS["traceback_format_exc"]
_MSP_VFS_REAL_TRACEBACK_FORMAT_LIST = _MSP_VFS_ORIGINALS["traceback_format_list"]
_MSP_VFS_REAL_TRACEBACK_FORMAT_STACK = _MSP_VFS_ORIGINALS["traceback_format_stack"]
_MSP_VFS_REAL_TRACEBACK_FORMAT_TB = _MSP_VFS_ORIGINALS["traceback_format_tb"]
"""#
}
