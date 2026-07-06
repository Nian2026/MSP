enum MSPPythonVFSBootstrapOutputVirtualizationSource {
    static let source = #"""
class _MSPVirtualizingTextWriter:
    def __init__(self, wrapped):
        self._wrapped = wrapped

    def write(self, text):
        return self._wrapped.write(_msp_vfs_virtualize_text(text))

    def writelines(self, lines):
        return self._wrapped.writelines([_msp_vfs_virtualize_text(line) for line in lines])

    def __getattr__(self, name):
        return getattr(self._wrapped, name)
"""#
}
