public enum MSPPythonVirtualFileSystemBootstrapSource {
    public static let source = [
        MSPPythonVFSBootstrapPreludeSource.source,
        MSPPythonVFSBootstrapFileSystemSource.source,
        MSPPythonVFSBootstrapTracebackSource.source,
        MSPPythonVFSBootstrapSubprocessSource.source,
        MSPPythonVFSBootstrapPatchSource.source,
    ].joined(separator: "\n\n")
}
