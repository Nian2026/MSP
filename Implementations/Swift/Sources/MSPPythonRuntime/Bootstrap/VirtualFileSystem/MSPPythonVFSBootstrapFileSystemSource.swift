enum MSPPythonVFSBootstrapFileSystemSource {
    static let source = [
        MSPPythonVFSBootstrapFileMaterializationSource.source,
        MSPPythonVFSBootstrapFileOpenSource.source,
        MSPPythonVFSBootstrapFileMetadataSource.source,
        MSPPythonVFSBootstrapFileOperationsSource.source,
        MSPPythonVFSBootstrapPathQuerySource.source,
        MSPPythonVFSBootstrapShutilSource.source,
        MSPPythonVFSBootstrapPathlibSource.source,
        MSPPythonVFSBootstrapOutputVirtualizationSource.source,
    ].joined(separator: "\n\n")
}
