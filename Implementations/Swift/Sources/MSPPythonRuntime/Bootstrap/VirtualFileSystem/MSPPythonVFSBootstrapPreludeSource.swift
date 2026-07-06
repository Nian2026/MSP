enum MSPPythonVFSBootstrapPreludeSource {
    static let source = [
        MSPPythonVFSBootstrapPreludeImportsSource.source,
        MSPPythonVFSBootstrapOriginalsSource.source,
        MSPPythonVFSBootstrapRuntimeEnvironmentSource.source,
        MSPPythonVFSBootstrapRuntimePathMappingSource.source,
        MSPPythonVFSBootstrapRuntimePolicySource.source,
        MSPPythonVFSBootstrapPathConversionSource.source,
        MSPPythonVFSBootstrapBrokerRequestSource.source,
        MSPPythonVFSBootstrapTextOpenSource.source,
        MSPPythonVFSBootstrapAuditHookSource.source,
    ].joined(separator: "\n\n")
}
