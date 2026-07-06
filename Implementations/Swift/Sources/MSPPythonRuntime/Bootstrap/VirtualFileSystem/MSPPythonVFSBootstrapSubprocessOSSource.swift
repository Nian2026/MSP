enum MSPPythonVFSBootstrapSubprocessOSSource {
    static let source = #"""
def _msp_vfs_os_system(command):
    completed = _msp_vfs_subprocess_run(command, shell=True)
    code = int(completed.returncode)
    return code << 8 if code >= 0 else code

def _msp_vfs_os_popen(command, mode="r", buffering=-1):
    if mode not in ("r", "w"):
        raise ValueError("invalid mode %r" % (mode,))
    if mode == "r":
        process = _MSPPythonPopen(command, shell=True, stdout=_msp_vfs_subprocess.PIPE, text=True)
        return process.stdout
    process = _MSPPythonPopen(command, shell=True, stdin=_msp_vfs_subprocess.PIPE, text=True)
    return process.stdin
"""#
}
