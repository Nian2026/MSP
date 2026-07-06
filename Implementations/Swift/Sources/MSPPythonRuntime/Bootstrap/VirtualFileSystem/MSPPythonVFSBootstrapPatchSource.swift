enum MSPPythonVFSBootstrapPatchSource {
    static let source = #"""
_MSP_VFS_PREVIOUS_PATCHES = {}

def _msp_vfs_capture_patch(name, getter):
    try:
        _MSP_VFS_PREVIOUS_PATCHES[name] = getter()
    except BaseException:
        _MSP_VFS_PREVIOUS_PATCHES[name] = None

def _msp_vfs_restore_value(target, attribute, patches, key):
    if key not in patches:
        return
    value = patches.get(key)
    if value is None:
        return
    try:
        setattr(target, attribute, value)
    except Exception:
        pass

def _msp_install_python_vfs():
    global _MSP_VFS_PREVIOUS_PATCHES
    _MSP_VFS_PREVIOUS_PATCHES = {}
    _msp_vfs_capture_patch("builtins_import", lambda: _msp_vfs_builtins.__import__)
    _msp_vfs_capture_patch("builtins_open", lambda: _msp_vfs_builtins.open)
    _msp_vfs_capture_patch("importlib_import_module", lambda: _msp_vfs_importlib.import_module)
    _msp_vfs_capture_patch("io_open", lambda: _msp_vfs_io.open)
    _msp_vfs_capture_patch("io_open_code", lambda: getattr(_msp_vfs_io, "open_code", None))
    _msp_vfs_capture_patch("os_getcwd", lambda: _msp_vfs_os.getcwd)
    _msp_vfs_capture_patch("os_getcwdb", lambda: getattr(_msp_vfs_os, "getcwdb", None))
    _msp_vfs_capture_patch("os_chdir", lambda: _msp_vfs_os.chdir)
    _msp_vfs_capture_patch("os_listdir", lambda: _msp_vfs_os.listdir)
    _msp_vfs_capture_patch("os_scandir", lambda: _msp_vfs_os.scandir)
    _msp_vfs_capture_patch("os_fwalk", lambda: getattr(_msp_vfs_os, "fwalk", None))
    _msp_vfs_capture_patch("os_stat", lambda: _msp_vfs_os.stat)
    _msp_vfs_capture_patch("os_lstat", lambda: _msp_vfs_os.lstat)
    _msp_vfs_capture_patch("os_fstat", lambda: getattr(_msp_vfs_os, "fstat", None))
    _msp_vfs_capture_patch("os_statvfs", lambda: getattr(_msp_vfs_os, "statvfs", None))
    _msp_vfs_capture_patch("os_fstatvfs", lambda: getattr(_msp_vfs_os, "fstatvfs", None))
    _msp_vfs_capture_patch("os_pathconf", lambda: getattr(_msp_vfs_os, "pathconf", None))
    _msp_vfs_capture_patch("os_fpathconf", lambda: getattr(_msp_vfs_os, "fpathconf", None))
    _msp_vfs_capture_patch("os_mkdir", lambda: _msp_vfs_os.mkdir)
    _msp_vfs_capture_patch("os_makedirs", lambda: _msp_vfs_os.makedirs)
    _msp_vfs_capture_patch("os_remove", lambda: _msp_vfs_os.remove)
    _msp_vfs_capture_patch("os_unlink", lambda: _msp_vfs_os.unlink)
    _msp_vfs_capture_patch("os_symlink", lambda: getattr(_msp_vfs_os, "symlink", None))
    _msp_vfs_capture_patch("os_link", lambda: getattr(_msp_vfs_os, "link", None))
    _msp_vfs_capture_patch("os_rmdir", lambda: _msp_vfs_os.rmdir)
    _msp_vfs_capture_patch("os_rename", lambda: _msp_vfs_os.rename)
    _msp_vfs_capture_patch("os_replace", lambda: _msp_vfs_os.replace)
    _msp_vfs_capture_patch("os_chmod", lambda: _msp_vfs_os.chmod)
    _msp_vfs_capture_patch("os_chflags", lambda: getattr(_msp_vfs_os, "chflags", None))
    _msp_vfs_capture_patch("os_utime", lambda: _msp_vfs_os.utime)
    _msp_vfs_capture_patch("os_truncate", lambda: _msp_vfs_os.truncate)
    _msp_vfs_capture_patch("os_ftruncate", lambda: getattr(_msp_vfs_os, "ftruncate", None))
    _msp_vfs_capture_patch("os_readlink", lambda: _msp_vfs_os.readlink)
    _msp_vfs_capture_patch("os_access", lambda: _msp_vfs_os.access)
    _msp_vfs_capture_patch("os_open", lambda: getattr(_msp_vfs_os, "open", None))
    _msp_vfs_capture_patch("os_close", lambda: getattr(_msp_vfs_os, "close", None))
    _msp_vfs_capture_patch("os_fdopen", lambda: getattr(_msp_vfs_os, "fdopen", None))
    _msp_vfs_capture_patch("os_dup", lambda: getattr(_msp_vfs_os, "dup", None))
    _msp_vfs_capture_patch("os_dup2", lambda: getattr(_msp_vfs_os, "dup2", None))
    _msp_vfs_capture_patch("os_umask", lambda: getattr(_msp_vfs_os, "umask", None))
    _msp_vfs_capture_patch("os_path_exists", lambda: _msp_vfs_os.path.exists)
    _msp_vfs_capture_patch("os_path_lexists", lambda: _msp_vfs_os.path.lexists)
    _msp_vfs_capture_patch("os_path_isdir", lambda: _msp_vfs_os.path.isdir)
    _msp_vfs_capture_patch("os_path_isfile", lambda: _msp_vfs_os.path.isfile)
    _msp_vfs_capture_patch("os_path_islink", lambda: _msp_vfs_os.path.islink)
    _msp_vfs_capture_patch("os_path_ismount", lambda: _msp_vfs_os.path.ismount)
    _msp_vfs_capture_patch("os_path_abspath", lambda: _msp_vfs_os.path.abspath)
    _msp_vfs_capture_patch("os_path_realpath", lambda: _msp_vfs_os.path.realpath)
    _msp_vfs_capture_patch("os_path_relpath", lambda: _msp_vfs_os.path.relpath)
    _msp_vfs_capture_patch("os_path_expanduser", lambda: _msp_vfs_os.path.expanduser)
    _msp_vfs_capture_patch("os_path_samefile", lambda: getattr(_msp_vfs_os.path, "samefile", None))
    _msp_vfs_capture_patch("os_path_sameopenfile", lambda: getattr(_msp_vfs_os.path, "sameopenfile", None))
    _msp_vfs_capture_patch("os_path_samestat", lambda: getattr(_msp_vfs_os.path, "samestat", None))
    _msp_vfs_capture_patch("shutil_copyfile", lambda: _msp_vfs_shutil.copyfile)
    _msp_vfs_capture_patch("shutil_copy", lambda: _msp_vfs_shutil.copy)
    _msp_vfs_capture_patch("shutil_copy2", lambda: _msp_vfs_shutil.copy2)
    _msp_vfs_capture_patch("shutil_copytree", lambda: _msp_vfs_shutil.copytree)
    _msp_vfs_capture_patch("shutil_move", lambda: _msp_vfs_shutil.move)
    _msp_vfs_capture_patch("shutil_rmtree", lambda: _msp_vfs_shutil.rmtree)
    _msp_vfs_capture_patch("path_glob", lambda: _msp_vfs_pathlib.Path.glob)
    _msp_vfs_capture_patch("path_rglob", lambda: _msp_vfs_pathlib.Path.rglob)
    _msp_vfs_capture_patch("path_walk", lambda: getattr(_msp_vfs_pathlib.Path, "walk", None))
    _msp_vfs_capture_patch("path_walk_present", lambda: hasattr(_msp_vfs_pathlib.Path, "walk"))
    _msp_vfs_capture_patch("path_resolve", lambda: _msp_vfs_pathlib.Path.resolve)
    _msp_vfs_capture_patch("path_stat", lambda: _msp_vfs_pathlib.Path.stat)
    _msp_vfs_capture_patch("path_lstat", lambda: _msp_vfs_pathlib.Path.lstat)
    _msp_vfs_capture_patch("path_chmod", lambda: _msp_vfs_pathlib.Path.chmod)
    _msp_vfs_capture_patch("path_touch", lambda: _msp_vfs_pathlib.Path.touch)
    _msp_vfs_capture_patch("purepath_str", lambda: _msp_vfs_pathlib.PurePath.__str__)
    _msp_vfs_capture_patch("purepath_fspath", lambda: _msp_vfs_pathlib.PurePath.__fspath__)
    _msp_vfs_capture_patch("path_cwd", lambda: vars(_msp_vfs_pathlib.Path).get("cwd"))
    _msp_vfs_capture_patch("path_home", lambda: vars(_msp_vfs_pathlib.Path).get("home"))
    _msp_vfs_capture_patch("path_expanduser", lambda: vars(_msp_vfs_pathlib.Path).get("expanduser"))
    _msp_vfs_capture_patch("posix_path_cwd", lambda: vars(getattr(_msp_vfs_pathlib, "PosixPath", object)).get("cwd"))
    _msp_vfs_capture_patch("posix_path_home", lambda: vars(getattr(_msp_vfs_pathlib, "PosixPath", object)).get("home"))
    _msp_vfs_capture_patch("posix_path_expanduser", lambda: vars(getattr(_msp_vfs_pathlib, "PosixPath", object)).get("expanduser"))
    _msp_vfs_capture_patch("windows_path_cwd", lambda: vars(getattr(_msp_vfs_pathlib, "WindowsPath", object)).get("cwd"))
    _msp_vfs_capture_patch("windows_path_home", lambda: vars(getattr(_msp_vfs_pathlib, "WindowsPath", object)).get("home"))
    _msp_vfs_capture_patch("windows_path_expanduser", lambda: vars(getattr(_msp_vfs_pathlib, "WindowsPath", object)).get("expanduser"))
    _msp_vfs_capture_patch("sys_stdout", lambda: _msp_vfs_sys.stdout)
    _msp_vfs_capture_patch("sys_stderr", lambda: _msp_vfs_sys.stderr)
    _msp_vfs_capture_patch("subprocess_popen", lambda: getattr(_msp_vfs_subprocess, "Popen", None))
    _msp_vfs_capture_patch("subprocess_run", lambda: getattr(_msp_vfs_subprocess, "run", None))
    _msp_vfs_capture_patch("subprocess_check_output", lambda: getattr(_msp_vfs_subprocess, "check_output", None))
    _msp_vfs_capture_patch("subprocess_call", lambda: getattr(_msp_vfs_subprocess, "call", None))
    _msp_vfs_capture_patch("subprocess_check_call", lambda: getattr(_msp_vfs_subprocess, "check_call", None))
    _msp_vfs_capture_patch("os_system", lambda: getattr(_msp_vfs_os, "system", None))
    _msp_vfs_capture_patch("os_popen", lambda: getattr(_msp_vfs_os, "popen", None))
    _msp_vfs_capture_patch("traceback_format_exception", lambda: _msp_vfs_traceback.format_exception)
    _msp_vfs_capture_patch("traceback_format_exception_only", lambda: _msp_vfs_traceback.format_exception_only)
    _msp_vfs_capture_patch("traceback_format_exc", lambda: _msp_vfs_traceback.format_exc)
    _msp_vfs_capture_patch("traceback_format_list", lambda: _msp_vfs_traceback.format_list)
    _msp_vfs_capture_patch("traceback_format_stack", lambda: _msp_vfs_traceback.format_stack)
    _msp_vfs_capture_patch("traceback_format_tb", lambda: _msp_vfs_traceback.format_tb)
    _msp_vfs_builtins.__import__ = _msp_vfs_guarded_import
    _msp_vfs_builtins.open = _msp_vfs_open
    _msp_vfs_importlib.import_module = _msp_vfs_guarded_import_module
    _msp_vfs_io.open = _msp_vfs_io_open
    if _MSP_VFS_REAL_IO_OPEN_CODE is not None:
        _msp_vfs_io.open_code = _msp_vfs_io_open_code
    _msp_vfs_os.getcwd = lambda: _MSP_VFS_VIRTUAL_CWD
    if _MSP_VFS_REAL_GETCWDB is not None:
        _msp_vfs_os.getcwdb = _msp_vfs_getcwdb
    _msp_vfs_os.chdir = _msp_vfs_chdir
    _msp_vfs_os.listdir = _msp_vfs_listdir
    _msp_vfs_os.scandir = _msp_vfs_scandir
    if _MSP_VFS_REAL_FWALK is not None:
        _msp_vfs_os.fwalk = _msp_vfs_fwalk
    _msp_vfs_os.stat = _msp_vfs_stat_call
    _msp_vfs_os.lstat = _msp_vfs_lstat_call
    if _MSP_VFS_REAL_FSTAT is not None:
        _msp_vfs_os.fstat = _msp_vfs_fstat_call
    if _MSP_VFS_REAL_STATVFS is not None:
        _msp_vfs_os.statvfs = _msp_vfs_statvfs_call
    if _MSP_VFS_REAL_FSTATVFS is not None:
        _msp_vfs_os.fstatvfs = _msp_vfs_fstatvfs_call
    if _MSP_VFS_REAL_PATHCONF is not None:
        _msp_vfs_os.pathconf = _msp_vfs_pathconf_call
    if _MSP_VFS_REAL_FPATHCONF is not None:
        _msp_vfs_os.fpathconf = _msp_vfs_fpathconf_call
    _msp_vfs_os.mkdir = _msp_vfs_mkdir
    _msp_vfs_os.makedirs = _msp_vfs_makedirs
    _msp_vfs_os.remove = _msp_vfs_remove
    _msp_vfs_os.unlink = _msp_vfs_remove
    if _MSP_VFS_REAL_SYMLINK is not None:
        _msp_vfs_os.symlink = _msp_vfs_operation_blocked
    if _MSP_VFS_REAL_LINK is not None:
        _msp_vfs_os.link = _msp_vfs_operation_blocked
    _msp_vfs_os.rmdir = _msp_vfs_rmdir
    _msp_vfs_os.rename = _msp_vfs_rename
    _msp_vfs_os.replace = _msp_vfs_replace
    _msp_vfs_os.chmod = _msp_vfs_chmod
    if _MSP_VFS_REAL_CHFLAGS is not None:
        _msp_vfs_os.chflags = _msp_vfs_chflags
    _msp_vfs_os.utime = _msp_vfs_utime
    _msp_vfs_os.truncate = _msp_vfs_truncate
    if _MSP_VFS_REAL_FTRUNCATE is not None:
        _msp_vfs_os.ftruncate = _msp_vfs_ftruncate
    _msp_vfs_os.readlink = _msp_vfs_readlink
    _msp_vfs_os.access = _msp_vfs_access
    if _MSP_VFS_REAL_OPEN_FD is not None:
        _msp_vfs_os.open = _msp_vfs_os_open
    if _MSP_VFS_REAL_CLOSE_FD is not None:
        _msp_vfs_os.close = _msp_vfs_os_close
    if _MSP_VFS_REAL_FDOPEN is not None:
        _msp_vfs_os.fdopen = _msp_vfs_fdopen
    if _MSP_VFS_REAL_DUP is not None:
        _msp_vfs_os.dup = _msp_vfs_os_dup
    if _MSP_VFS_REAL_DUP2 is not None:
        _msp_vfs_os.dup2 = _msp_vfs_os_dup2
    if _MSP_VFS_REAL_UMASK is not None:
        _msp_vfs_os.umask = _msp_vfs_umask
    _msp_vfs_os.path.exists = _msp_vfs_exists
    _msp_vfs_os.path.lexists = _msp_vfs_lexists
    _msp_vfs_os.path.isdir = _msp_vfs_isdir
    _msp_vfs_os.path.isfile = _msp_vfs_isfile
    _msp_vfs_os.path.islink = _msp_vfs_islink
    _msp_vfs_os.path.ismount = _msp_vfs_ismount
    _msp_vfs_os.path.abspath = _msp_vfs_abspath
    _msp_vfs_os.path.realpath = _msp_vfs_realpath
    _msp_vfs_os.path.relpath = _msp_vfs_relpath
    _msp_vfs_os.path.expanduser = _msp_vfs_expanduser
    if _MSP_VFS_REAL_PATH_SAMEFILE is not None:
        _msp_vfs_os.path.samefile = _msp_vfs_samefile
    if _MSP_VFS_REAL_PATH_SAMEOPENFILE is not None:
        _msp_vfs_os.path.sameopenfile = _msp_vfs_sameopenfile
    if _MSP_VFS_REAL_PATH_SAMESTAT is not None:
        _msp_vfs_os.path.samestat = _msp_vfs_samestat
    _msp_vfs_shutil.copyfile = _msp_vfs_copyfile
    _msp_vfs_shutil.copy = _msp_vfs_copy
    _msp_vfs_shutil.copy2 = _msp_vfs_copy2
    _msp_vfs_shutil.copytree = _msp_vfs_copytree
    _msp_vfs_shutil.move = _msp_vfs_move
    _msp_vfs_shutil.rmtree = _msp_vfs_rmtree
    _msp_vfs_pathlib.Path.glob = _msp_vfs_pathlib_glob
    _msp_vfs_pathlib.Path.rglob = _msp_vfs_pathlib_rglob
    _msp_vfs_pathlib.Path.walk = _msp_vfs_pathlib_walk_method
    _msp_vfs_pathlib.Path.resolve = _msp_vfs_pathlib_resolve
    _msp_vfs_pathlib.Path.stat = _msp_vfs_pathlib_stat
    _msp_vfs_pathlib.Path.lstat = _msp_vfs_pathlib_lstat
    _msp_vfs_pathlib.Path.chmod = _msp_vfs_pathlib_chmod
    _msp_vfs_pathlib.Path.touch = _msp_vfs_pathlib_touch
    _msp_vfs_pathlib.PurePath.__str__ = _msp_vfs_pathlib_virtual_str
    _msp_vfs_pathlib.PurePath.__fspath__ = _msp_vfs_pathlib_virtual_str
    try:
        _msp_vfs_pathlib.Path(".")._accessor.open = _msp_vfs_os_open
        _msp_vfs_pathlib.Path(".")._accessor.stat = _msp_vfs_stat_call
        _msp_vfs_pathlib.Path(".")._accessor.lstat = _msp_vfs_lstat_call
        _msp_vfs_pathlib.Path(".")._accessor.listdir = _msp_vfs_listdir
        _msp_vfs_pathlib.Path(".")._accessor.scandir = _msp_vfs_scandir
        _msp_vfs_pathlib.Path(".")._accessor.mkdir = _msp_vfs_mkdir
        _msp_vfs_pathlib.Path(".")._accessor.unlink = _msp_vfs_remove
        _msp_vfs_pathlib.Path(".")._accessor.rmdir = _msp_vfs_rmdir
        _msp_vfs_pathlib.Path(".")._accessor.rename = _msp_vfs_rename
        _msp_vfs_pathlib.Path(".")._accessor.replace = _msp_vfs_replace
        _msp_vfs_pathlib.Path(".")._accessor.chmod = _msp_vfs_chmod
    except Exception:
        pass
    for _msp_vfs_path_class_name in ("Path", "PosixPath", "WindowsPath"):
        _msp_vfs_path_class = getattr(_msp_vfs_pathlib, _msp_vfs_path_class_name, None)
        if _msp_vfs_path_class is not None:
            try:
                _msp_vfs_path_class.cwd = classmethod(lambda cls: cls(_msp_vfs_os.getcwd()))
            except Exception:
                pass
            try:
                _msp_vfs_path_class.home = classmethod(_msp_vfs_pathlib_home)
            except Exception:
                pass
            try:
                _msp_vfs_path_class.expanduser = _msp_vfs_pathlib_expanduser
            except Exception:
                pass
    if not isinstance(_msp_vfs_sys.stdout, _MSPVirtualizingTextWriter):
        _msp_vfs_sys.stdout = _MSPVirtualizingTextWriter(_msp_vfs_sys.stdout)
    if not isinstance(_msp_vfs_sys.stderr, _MSPVirtualizingTextWriter):
        _msp_vfs_sys.stderr = _MSPVirtualizingTextWriter(_msp_vfs_sys.stderr)
    _msp_vfs_subprocess.Popen = _MSPPythonPopen
    _msp_vfs_subprocess.run = _msp_vfs_subprocess_run
    _msp_vfs_subprocess.check_output = _msp_vfs_subprocess_check_output
    _msp_vfs_subprocess.call = _msp_vfs_subprocess_call
    _msp_vfs_subprocess.check_call = _msp_vfs_subprocess_check_call
    _msp_vfs_os.system = _msp_vfs_os_system
    _msp_vfs_os.popen = _msp_vfs_os_popen
    _msp_vfs_traceback.format_exception = _msp_vfs_traceback_format_exception
    _msp_vfs_traceback.format_exception_only = _msp_vfs_traceback_format_exception_only
    _msp_vfs_traceback.format_exc = _msp_vfs_traceback_format_exc
    _msp_vfs_traceback.format_list = _msp_vfs_traceback_format_list
    _msp_vfs_traceback.format_stack = _msp_vfs_traceback_format_stack
    _msp_vfs_traceback.format_tb = _msp_vfs_traceback_format_tb
    _msp_vfs_os.environ["HOME"] = _msp_vfs_os.environ.get("MSP_PYTHON_VIRTUAL_HOME", "/") or "/"
    _msp_vfs_os.environ["TMPDIR"] = _msp_vfs_os.environ.get("MSP_PYTHON_VIRTUAL_TMPDIR", "/tmp") or "/tmp"
    _msp_vfs_os.environ["PATH"] = _msp_vfs_os.environ.get("MSP_PYTHON_VIRTUAL_PATH", "/usr/bin:/bin") or "/usr/bin:/bin"
    _msp_vfs_os.environ["PWD"] = _MSP_VFS_VIRTUAL_CWD
    for _msp_vfs_internal_env_name in (
        "MSP_PYTHON_WORKSPACE_ROOT",
        "MSP_PYTHON_VIRTUAL_CWD",
        "MSP_PYTHON_VIRTUAL_HOME",
        "MSP_PYTHON_VIRTUAL_TMPDIR",
        "MSP_PYTHON_VIRTUAL_PATH",
        "MSP_PYTHON_AVAILABLE_COMMANDS_B64",
        "MSP_PYTHON_COMMAND_LOOKUP_PATHS_B64",
        "MSP_PYTHON_VFS_BROKER_DIR",
        "MSP_PYTHON_VFS_MATERIALIZED_DIR",
        "MSP_PYTHON_SUBPROCESS_BROKER_DIR",
        "MSP_PYTHON_FILE_CREATION_MASK",
    ):
        _msp_vfs_os.environ.pop(_msp_vfs_internal_env_name, None)
    if _msp_vfs_sys.argv and isinstance(_msp_vfs_sys.argv[0], str):
        _msp_vfs_sys.argv[0] = _msp_vfs_virtualize_real_path(_msp_vfs_sys.argv[0])
    _msp_vfs_install_audit_hook()

def _msp_restore_python_vfs():
    patches = globals().get("_MSP_VFS_PREVIOUS_PATCHES") or {}
    if not patches:
        return
    _msp_vfs_restore_value(_msp_vfs_builtins, "__import__", patches, "builtins_import")
    _msp_vfs_restore_value(_msp_vfs_builtins, "open", patches, "builtins_open")
    _msp_vfs_restore_value(_msp_vfs_importlib, "import_module", patches, "importlib_import_module")
    _msp_vfs_restore_value(_msp_vfs_io, "open", patches, "io_open")
    _msp_vfs_restore_value(_msp_vfs_io, "open_code", patches, "io_open_code")
    _msp_vfs_restore_value(_msp_vfs_os, "getcwd", patches, "os_getcwd")
    _msp_vfs_restore_value(_msp_vfs_os, "getcwdb", patches, "os_getcwdb")
    _msp_vfs_restore_value(_msp_vfs_os, "chdir", patches, "os_chdir")
    _msp_vfs_restore_value(_msp_vfs_os, "listdir", patches, "os_listdir")
    _msp_vfs_restore_value(_msp_vfs_os, "scandir", patches, "os_scandir")
    _msp_vfs_restore_value(_msp_vfs_os, "fwalk", patches, "os_fwalk")
    _msp_vfs_restore_value(_msp_vfs_os, "stat", patches, "os_stat")
    _msp_vfs_restore_value(_msp_vfs_os, "lstat", patches, "os_lstat")
    _msp_vfs_restore_value(_msp_vfs_os, "fstat", patches, "os_fstat")
    _msp_vfs_restore_value(_msp_vfs_os, "statvfs", patches, "os_statvfs")
    _msp_vfs_restore_value(_msp_vfs_os, "fstatvfs", patches, "os_fstatvfs")
    _msp_vfs_restore_value(_msp_vfs_os, "pathconf", patches, "os_pathconf")
    _msp_vfs_restore_value(_msp_vfs_os, "fpathconf", patches, "os_fpathconf")
    _msp_vfs_restore_value(_msp_vfs_os, "mkdir", patches, "os_mkdir")
    _msp_vfs_restore_value(_msp_vfs_os, "makedirs", patches, "os_makedirs")
    _msp_vfs_restore_value(_msp_vfs_os, "remove", patches, "os_remove")
    _msp_vfs_restore_value(_msp_vfs_os, "unlink", patches, "os_unlink")
    _msp_vfs_restore_value(_msp_vfs_os, "symlink", patches, "os_symlink")
    _msp_vfs_restore_value(_msp_vfs_os, "link", patches, "os_link")
    _msp_vfs_restore_value(_msp_vfs_os, "rmdir", patches, "os_rmdir")
    _msp_vfs_restore_value(_msp_vfs_os, "rename", patches, "os_rename")
    _msp_vfs_restore_value(_msp_vfs_os, "replace", patches, "os_replace")
    _msp_vfs_restore_value(_msp_vfs_os, "chmod", patches, "os_chmod")
    _msp_vfs_restore_value(_msp_vfs_os, "chflags", patches, "os_chflags")
    _msp_vfs_restore_value(_msp_vfs_os, "utime", patches, "os_utime")
    _msp_vfs_restore_value(_msp_vfs_os, "truncate", patches, "os_truncate")
    _msp_vfs_restore_value(_msp_vfs_os, "ftruncate", patches, "os_ftruncate")
    _msp_vfs_restore_value(_msp_vfs_os, "readlink", patches, "os_readlink")
    _msp_vfs_restore_value(_msp_vfs_os, "access", patches, "os_access")
    _msp_vfs_restore_value(_msp_vfs_os, "open", patches, "os_open")
    _msp_vfs_restore_value(_msp_vfs_os, "close", patches, "os_close")
    _msp_vfs_restore_value(_msp_vfs_os, "fdopen", patches, "os_fdopen")
    _msp_vfs_restore_value(_msp_vfs_os, "dup", patches, "os_dup")
    _msp_vfs_restore_value(_msp_vfs_os, "dup2", patches, "os_dup2")
    _msp_vfs_restore_value(_msp_vfs_os, "umask", patches, "os_umask")
    _msp_vfs_restore_value(_msp_vfs_os.path, "exists", patches, "os_path_exists")
    _msp_vfs_restore_value(_msp_vfs_os.path, "lexists", patches, "os_path_lexists")
    _msp_vfs_restore_value(_msp_vfs_os.path, "isdir", patches, "os_path_isdir")
    _msp_vfs_restore_value(_msp_vfs_os.path, "isfile", patches, "os_path_isfile")
    _msp_vfs_restore_value(_msp_vfs_os.path, "islink", patches, "os_path_islink")
    _msp_vfs_restore_value(_msp_vfs_os.path, "ismount", patches, "os_path_ismount")
    _msp_vfs_restore_value(_msp_vfs_os.path, "abspath", patches, "os_path_abspath")
    _msp_vfs_restore_value(_msp_vfs_os.path, "realpath", patches, "os_path_realpath")
    _msp_vfs_restore_value(_msp_vfs_os.path, "relpath", patches, "os_path_relpath")
    _msp_vfs_restore_value(_msp_vfs_os.path, "expanduser", patches, "os_path_expanduser")
    _msp_vfs_restore_value(_msp_vfs_os.path, "samefile", patches, "os_path_samefile")
    _msp_vfs_restore_value(_msp_vfs_os.path, "sameopenfile", patches, "os_path_sameopenfile")
    _msp_vfs_restore_value(_msp_vfs_os.path, "samestat", patches, "os_path_samestat")
    _msp_vfs_restore_value(_msp_vfs_shutil, "copyfile", patches, "shutil_copyfile")
    _msp_vfs_restore_value(_msp_vfs_shutil, "copy", patches, "shutil_copy")
    _msp_vfs_restore_value(_msp_vfs_shutil, "copy2", patches, "shutil_copy2")
    _msp_vfs_restore_value(_msp_vfs_shutil, "copytree", patches, "shutil_copytree")
    _msp_vfs_restore_value(_msp_vfs_shutil, "move", patches, "shutil_move")
    _msp_vfs_restore_value(_msp_vfs_shutil, "rmtree", patches, "shutil_rmtree")
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "glob", patches, "path_glob")
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "rglob", patches, "path_rglob")
    if patches.get("path_walk_present"):
        _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "walk", patches, "path_walk")
    else:
        try:
            delattr(_msp_vfs_pathlib.Path, "walk")
        except Exception:
            pass
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "resolve", patches, "path_resolve")
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "stat", patches, "path_stat")
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "lstat", patches, "path_lstat")
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "chmod", patches, "path_chmod")
    _msp_vfs_restore_value(_msp_vfs_pathlib.Path, "touch", patches, "path_touch")
    _msp_vfs_restore_value(_msp_vfs_pathlib.PurePath, "__str__", patches, "purepath_str")
    _msp_vfs_restore_value(_msp_vfs_pathlib.PurePath, "__fspath__", patches, "purepath_fspath")
    for _msp_restore_class_name, _msp_restore_key in (
        ("Path", "path_cwd"),
        ("PosixPath", "posix_path_cwd"),
        ("WindowsPath", "windows_path_cwd"),
    ):
        _msp_restore_class = getattr(_msp_vfs_pathlib, _msp_restore_class_name, None)
        _msp_restore_value = patches.get(_msp_restore_key)
        if _msp_restore_class is not None and _msp_restore_value is not None:
            try:
                setattr(_msp_restore_class, "cwd", _msp_restore_value)
            except Exception:
                pass
    for _msp_restore_class_name, _msp_restore_home_key, _msp_restore_expanduser_key in (
        ("Path", "path_home", "path_expanduser"),
        ("PosixPath", "posix_path_home", "posix_path_expanduser"),
        ("WindowsPath", "windows_path_home", "windows_path_expanduser"),
    ):
        _msp_restore_class = getattr(_msp_vfs_pathlib, _msp_restore_class_name, None)
        if _msp_restore_class is None:
            continue
        _msp_restore_home = patches.get(_msp_restore_home_key)
        if _msp_restore_home is not None:
            try:
                setattr(_msp_restore_class, "home", _msp_restore_home)
            except Exception:
                pass
        _msp_restore_expanduser = patches.get(_msp_restore_expanduser_key)
        if _msp_restore_expanduser is not None:
            try:
                setattr(_msp_restore_class, "expanduser", _msp_restore_expanduser)
            except Exception:
                pass
    _msp_vfs_restore_value(_msp_vfs_sys, "stdout", patches, "sys_stdout")
    _msp_vfs_restore_value(_msp_vfs_sys, "stderr", patches, "sys_stderr")
    _msp_vfs_restore_value(_msp_vfs_subprocess, "Popen", patches, "subprocess_popen")
    _msp_vfs_restore_value(_msp_vfs_subprocess, "run", patches, "subprocess_run")
    _msp_vfs_restore_value(_msp_vfs_subprocess, "check_output", patches, "subprocess_check_output")
    _msp_vfs_restore_value(_msp_vfs_subprocess, "call", patches, "subprocess_call")
    _msp_vfs_restore_value(_msp_vfs_subprocess, "check_call", patches, "subprocess_check_call")
    _msp_vfs_restore_value(_msp_vfs_os, "system", patches, "os_system")
    _msp_vfs_restore_value(_msp_vfs_os, "popen", patches, "os_popen")
    _msp_vfs_restore_value(_msp_vfs_traceback, "format_exception", patches, "traceback_format_exception")
    _msp_vfs_restore_value(_msp_vfs_traceback, "format_exception_only", patches, "traceback_format_exception_only")
    _msp_vfs_restore_value(_msp_vfs_traceback, "format_exc", patches, "traceback_format_exc")
    _msp_vfs_restore_value(_msp_vfs_traceback, "format_list", patches, "traceback_format_list")
    _msp_vfs_restore_value(_msp_vfs_traceback, "format_stack", patches, "traceback_format_stack")
    _msp_vfs_restore_value(_msp_vfs_traceback, "format_tb", patches, "traceback_format_tb")
    _MSP_VFS_PREVIOUS_PATCHES.clear()

_msp_vfs_atexit.register(_msp_vfs_flush_pending_writebacks)
_msp_install_python_vfs()
"""#
}
