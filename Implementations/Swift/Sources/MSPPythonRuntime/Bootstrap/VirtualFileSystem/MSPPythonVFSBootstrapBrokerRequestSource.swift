enum MSPPythonVFSBootstrapBrokerRequestSource {
    static let source = #"""
def _msp_vfs_error(response):
    error = response.get("error") or {}
    error_type = error.get("type") or "OSError"
    path = error.get("path")
    message = error.get("message") or error_type
    if error_type == "FileNotFoundError":
        raise FileNotFoundError(_msp_vfs_errno.ENOENT, "No such file or directory", path)
    if error_type == "FileExistsError":
        raise FileExistsError(_msp_vfs_errno.EEXIST, "File exists", path)
    if error_type == "NotADirectoryError":
        raise NotADirectoryError(_msp_vfs_errno.ENOTDIR, "Not a directory", path)
    if error_type == "IsADirectoryError":
        raise IsADirectoryError(_msp_vfs_errno.EISDIR, "Is a directory", path)
    if error_type == "DirectoryNotEmptyError":
        raise OSError(_msp_vfs_errno.ENOTEMPTY, "Directory not empty", path)
    if error_type == "PermissionError":
        raise PermissionError(_msp_vfs_errno.EACCES, "Permission denied", path)
    if error_type == "ValueError":
        raise ValueError(message)
    raise OSError(message)

def _msp_vfs_request(action, **payload):
    if not _MSP_VFS_BROKER_DIR:
        raise PermissionError("MSP Python virtual filesystem is unavailable")
    request_id = _msp_vfs_next_id("request")
    request_path = _msp_vfs_os.path.join(_MSP_VFS_BROKER_DIR, "vfs-request-" + request_id + ".json")
    request_tmp_path = request_path + ".tmp"
    response_path = _msp_vfs_os.path.join(_MSP_VFS_BROKER_DIR, "vfs-response-" + request_id + ".json")
    request = {"id": request_id, "action": action, "cwd": _MSP_VFS_VIRTUAL_CWD}
    request.update(payload)
    try:
        with _MSP_VFS_REAL_OPEN(request_tmp_path, "w", encoding="utf-8") as request_file:
            _msp_vfs_json.dump(request, request_file, separators=(",", ":"), allow_nan=False)
        _MSP_VFS_REAL_REPLACE(request_tmp_path, request_path)
    except Exception:
        try:
            _MSP_VFS_REAL_REMOVE(request_tmp_path)
        except Exception:
            pass
        raise
    started_at = _msp_vfs_time.monotonic()
    while not _MSP_VFS_REAL_PATH_EXISTS(response_path):
        if _msp_vfs_time.monotonic() - started_at > 30:
            raise TimeoutError("MSP Python virtual filesystem request timed out")
        _msp_vfs_time.sleep(0.002)
    with _MSP_VFS_REAL_OPEN(response_path, "r", encoding="utf-8") as response_file:
        response = _msp_vfs_json.load(response_file)
    try:
        _MSP_VFS_REAL_REMOVE(response_path)
    except Exception:
        pass
    if not response.get("ok"):
        _msp_vfs_error(response)
    return response
"""#
}
