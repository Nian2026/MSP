enum MSPPythonVFSBootstrapRuntimeEnvironmentSource {
    static let source = #"""
def _msp_vfs_norm_or_empty(value):
    return _msp_vfs_os.path.normpath(value) if value else ""

_msp_vfs_payload = globals().get("_msp_payload", {}) if isinstance(globals().get("_msp_payload", {}), dict) else {}
_MSP_VFS_WORKSPACE_ROOT = _msp_vfs_norm_or_empty(
    _msp_vfs_payload.get("workspace_root_path")
    or _msp_vfs_os.environ.get("MSP_PYTHON_WORKSPACE_ROOT", "")
)
_MSP_VFS_BROKER_DIR = _msp_vfs_norm_or_empty(
    _msp_vfs_payload.get("vfs_broker_dir")
    or _msp_vfs_os.environ.get("MSP_PYTHON_VFS_BROKER_DIR", "")
)
_MSP_VFS_MATERIALIZED_DIR = _msp_vfs_norm_or_empty(
    _msp_vfs_payload.get("vfs_materialized_dir")
    or _msp_vfs_os.environ.get("MSP_PYTHON_VFS_MATERIALIZED_DIR", "")
)
_MSP_VFS_SUBPROCESS_BROKER_DIR = _msp_vfs_norm_or_empty(
    _msp_vfs_payload.get("subprocess_broker_dir")
    or _msp_vfs_os.environ.get("MSP_PYTHON_SUBPROCESS_BROKER_DIR", "")
)
_MSP_VFS_RESULT_PATH = _msp_vfs_norm_or_empty(_msp_vfs_payload.get("result_path") or "")
_MSP_VFS_VIRTUAL_CWD = _msp_vfs_os.path.normpath(
    _msp_vfs_payload.get("virtual_cwd")
    or _msp_vfs_os.environ.get("MSP_PYTHON_VIRTUAL_CWD", "/")
    or "/"
)
if not _MSP_VFS_VIRTUAL_CWD.startswith("/"):
    _MSP_VFS_VIRTUAL_CWD = "/"

_MSP_VFS_BLOCKED_PACKAGE_INSTALL_MODULES = {"pip", "ensurepip", "venv"}
_MSP_VFS_BLOCKED_RUNTIME_MODULES = {"multiprocessing"}
_MSP_VFS_AUDIT_INSTALLED_NAME = "__msp_python_vfs_audit_hook_installed__"

_MSP_VFS_REAL_TO_VIRTUAL = {}
_MSP_VFS_RUNTIME_REAL_TO_VIRTUAL = {}
_MSP_VFS_WRITEBACKS = {}
_MSP_VFS_FD_WRITEBACKS = {}
_MSP_VFS_FD_REAL_PATHS = {}
_MSP_VFS_SUBPROCESS_STREAM_WRITEBACK_HOLDS = {}
_MSP_VFS_DIR_FDS = {}
_MSP_VFS_OPEN_FILE_WRAPPERS = _msp_vfs_weakref.WeakSet()
_MSP_VFS_OPENER_LABEL_PATHS = set()
_MSP_VFS_REQUEST_COUNTER = 0

def _msp_vfs_next_id(prefix):
    global _MSP_VFS_REQUEST_COUNTER
    _MSP_VFS_REQUEST_COUNTER += 1
    return "%s-%x-%x" % (prefix, int(_msp_vfs_time.time() * 1000000000), _MSP_VFS_REQUEST_COUNTER)

def _msp_vfs_initial_umask():
    value = _msp_vfs_payload.get("file_creation_mask")
    if value is None:
        value = _msp_vfs_os.environ.get("MSP_PYTHON_FILE_CREATION_MASK")
    if value is None or value == "":
        return 0o022
    if isinstance(value, int):
        return value & 0o777
    text = str(value).strip()
    try:
        return int(text, 8) & 0o777
    except Exception:
        try:
            return int(text) & 0o777
        except Exception:
            return 0o022

_MSP_VFS_FILE_CREATION_MASK = _msp_vfs_initial_umask()

def _msp_vfs_json_from_env_b64(name, default):
    encoded = _msp_vfs_os.environ.get(name, "")
    if not encoded:
        return default
    try:
        return _msp_vfs_json.loads(_msp_vfs_base64.b64decode(encoded).decode("utf-8"))
    except Exception:
        return default

def _msp_vfs_string_list(value):
    if not isinstance(value, (list, tuple, set)):
        return []
    return [item for item in value if isinstance(item, str) and item]

def _msp_vfs_command_lookup_paths(value):
    if not isinstance(value, dict):
        return {}
    result = {}
    for name, paths in value.items():
        if not isinstance(name, str) or not name:
            continue
        clean_paths = []
        for path in _msp_vfs_string_list(paths):
            if not path.startswith("/"):
                continue
            clean_paths.append(_msp_vfs_os.path.normpath(path))
        if clean_paths:
            result[name] = clean_paths
    return result

_MSP_VFS_AVAILABLE_COMMAND_NAMES = set(_msp_vfs_string_list(
    _msp_vfs_payload.get("available_command_names")
    or _msp_vfs_json_from_env_b64("MSP_PYTHON_AVAILABLE_COMMANDS_B64", [])
))
_MSP_VFS_COMMAND_LOOKUP_PATHS = _msp_vfs_command_lookup_paths(
    _msp_vfs_payload.get("command_lookup_paths")
    or _msp_vfs_json_from_env_b64("MSP_PYTHON_COMMAND_LOOKUP_PATHS_B64", {})
)
_MSP_VFS_SHELL_ONLY_COMMAND_NAMES = {
    ".", ":", "[[", "alias", "break", "builtin", "cd", "command", "continue",
    "declare", "eval", "exec", "exit", "export", "local", "mapfile", "read",
    "readarray", "readonly", "return", "set", "shift", "shopt", "source",
    "trap", "type", "typeset", "umask", "unalias", "unset",
}

def _msp_vfs_command_paths_for_name(name):
    paths = _MSP_VFS_COMMAND_LOOKUP_PATHS.get(name)
    if paths:
        return list(paths)
    if name in _MSP_VFS_AVAILABLE_COMMAND_NAMES and name not in _MSP_VFS_SHELL_ONLY_COMMAND_NAMES:
        return ["/usr/bin/" + name, "/bin/" + name]
    return []

def _msp_vfs_build_command_path_indexes():
    path_to_name = {}
    dir_entries = {}
    for name in sorted(_MSP_VFS_AVAILABLE_COMMAND_NAMES):
        for path in _msp_vfs_command_paths_for_name(name):
            normalized = _msp_vfs_os.path.normpath(path)
            if not normalized.startswith("/"):
                continue
            path_to_name[normalized] = name
            parent = _msp_vfs_os.path.dirname(normalized) or "/"
            basename = _msp_vfs_os.path.basename(normalized)
            dir_entries.setdefault(parent, {})[basename] = {
                "name": basename,
                "info": {
                    "type": "regularFile",
                    "permissions": 0o755,
                    "size": 0,
                    "modification_time": 0,
                    "virtual_path": normalized,
                    "file_identity": "msp-command:" + name,
                },
            }
            current = parent
            while current and current != "/":
                ancestor = _msp_vfs_os.path.dirname(current) or "/"
                directory_name = _msp_vfs_os.path.basename(current)
                dir_entries.setdefault(ancestor, {})[directory_name] = {
                    "name": directory_name,
                    "info": {
                        "type": "directory",
                        "permissions": 0o755,
                        "size": 0,
                        "modification_time": 0,
                        "virtual_path": current,
                        "file_identity": "msp-command-dir:" + current,
                    },
                }
                current = ancestor
    return path_to_name, dir_entries

_MSP_VFS_COMMAND_PATHS, _MSP_VFS_COMMAND_DIR_ENTRIES = _msp_vfs_build_command_path_indexes()
"""#
}
