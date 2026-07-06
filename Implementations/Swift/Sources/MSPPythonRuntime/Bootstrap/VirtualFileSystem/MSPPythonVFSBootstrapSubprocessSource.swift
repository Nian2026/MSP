enum MSPPythonVFSBootstrapSubprocessSource {
    static let source = [
        MSPPythonVFSBootstrapSubprocessCoreSource.source,
        MSPPythonVFSBootstrapSubprocessRunSource.source,
        MSPPythonVFSBootstrapSubprocessPipesSource.source,
        MSPPythonVFSBootstrapSubprocessPopenSource.source,
        MSPPythonVFSBootstrapSubprocessOSSource.source,
    ].joined(separator: "\n\n")
}
