import Foundation
import MSPCore
import MSPPythonRuntime

struct MSPCPythonPreparedExecution {
    var payload: MSPCPythonExecutionPayload
    var resultURL: URL
    var brokerDirectoryURL: URL
    var vfsBrokerDirectoryURL: URL
    var vfsMaterializedDirectoryURL: URL
    var hostCurrentDirectoryURL: URL?
    var virtualCurrentDirectory: String

    init(
        request: MSPPythonEmbeddedExecutionRequest,
        workspaceRootURL: URL?,
        liveIO: MSPCPythonLiveIO? = nil
    ) throws {
        let source = try Self.source(for: request, workspaceRootURL: workspaceRootURL)
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-cpython-\(UUID().uuidString).json")
        let brokerDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-cpython-subprocess-\(UUID().uuidString)", isDirectory: true)
        let vfsBrokerDirectoryURL = brokerDirectoryURL.appendingPathComponent("vfs-broker", isDirectory: true)
        let vfsMaterializedDirectoryURL = brokerDirectoryURL.appendingPathComponent("vfs-materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: brokerDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vfsMaterializedDirectoryURL, withIntermediateDirectories: true)
        self.virtualCurrentDirectory = request.virtualCurrentDirectory
        self.hostCurrentDirectoryURL = workspaceRootURL.map {
            Self.hostURL(forVirtualPath: request.virtualCurrentDirectory, rootURL: $0, isDirectory: true)
        }
        self.resultURL = resultURL
        self.brokerDirectoryURL = brokerDirectoryURL
        self.vfsBrokerDirectoryURL = vfsBrokerDirectoryURL
        self.vfsMaterializedDirectoryURL = vfsMaterializedDirectoryURL
        self.payload = MSPCPythonExecutionPayload(
            mode: source.mode,
            moduleName: source.moduleName,
            sourceB64: source.sourceData.base64EncodedString(),
            filename: source.filename,
            argv: source.argv,
            stdinB64: request.standardInput.base64EncodedString(),
            stdinFD: liveIO?.stdinFileDescriptor,
            stdoutFD: liveIO?.stdoutFileDescriptor,
            stderrFD: liveIO?.stderrFileDescriptor,
            environment: MSPPythonUTF8Environment.applying(to: request.environment),
            fileCreationMask: Int(request.fileCreationMask),
            resultPath: resultURL.path,
            subprocessBrokerDir: brokerDirectoryURL.path,
            vfsBrokerDir: vfsBrokerDirectoryURL.path,
            vfsMaterializedDir: vfsMaterializedDirectoryURL.path,
            workspaceRootPath: workspaceRootURL?.path ?? "",
            virtualCurrentDirectory: request.virtualCurrentDirectory,
            availableCommandNames: request.subprocessContext.availableCommandNames,
            commandLookupPaths: request.subprocessContext.commandLookupPaths
        )
    }

    private static func source(
        for request: MSPPythonEmbeddedExecutionRequest,
        workspaceRootURL: URL?
    ) throws -> MSPCPythonSource {
        switch request.entrypoint {
        case .command(let source, let arguments):
            return MSPCPythonSource(
                mode: "command",
                moduleName: nil,
                sourceData: Data(source.utf8),
                filename: "<string>",
                argv: ["-c"] + arguments
            )
        case .standardInput(let arguments):
            return MSPCPythonSource(
                mode: "stdin",
                moduleName: nil,
                sourceData: request.standardInput,
                filename: "<stdin>",
                argv: ["-"] + arguments
            )
        case .interactive(let arguments):
            return MSPCPythonSource(
                mode: "interactive",
                moduleName: nil,
                sourceData: Data(),
                filename: "<stdin>",
                argv: [""] + arguments
            )
        case .script(let path, let arguments):
            let sourceData = try scriptData(
                virtualPath: path.virtualPath,
                request: request,
                workspaceRootURL: workspaceRootURL
            )
            return MSPCPythonSource(
                mode: "script",
                moduleName: nil,
                sourceData: sourceData,
                filename: path.virtualPath,
                argv: [path.virtualPath] + arguments
            )
        case .module(let name, let arguments):
            return MSPCPythonSource(
                mode: "module",
                moduleName: name,
                sourceData: Data(),
                filename: name,
                argv: [name] + arguments
            )
        }
    }

    private static func scriptData(
        virtualPath: String,
        request: MSPPythonEmbeddedExecutionRequest,
        workspaceRootURL: URL?
    ) throws -> Data {
        if let workspace = request.workspace {
            return try workspace.fileSystem.readFile(virtualPath, from: "/")
        }
        guard let workspaceRootURL else {
            throw MSPPythonEmbeddedRuntimeError.engineUnavailable(
                "script execution requires a workspace or host workspace root"
            )
        }
        return try Data(contentsOf: hostURL(forVirtualPath: virtualPath, rootURL: workspaceRootURL, isDirectory: false))
    }

    private static func hostURL(forVirtualPath virtualPath: String, rootURL: URL, isDirectory: Bool) -> URL {
        let normalized = MSPWorkspacePathResolver.normalize(virtualPath)
        guard normalized != "/" else {
            return rootURL
        }
        return rootURL
            .appendingPathComponent(String(normalized.dropFirst()), isDirectory: isDirectory)
            .standardizedFileURL
    }
}

struct MSPCPythonSource {
    var mode: String
    var moduleName: String?
    var sourceData: Data
    var filename: String
    var argv: [String]
}

struct MSPCPythonExecutionPayload: Encodable {
    var mode: String
    var moduleName: String?
    var sourceB64: String
    var filename: String
    var argv: [String]
    var stdinB64: String
    var stdinFD: Int32?
    var stdoutFD: Int32?
    var stderrFD: Int32?
    var environment: [String: String]
    var fileCreationMask: Int
    var resultPath: String
    var subprocessBrokerDir: String
    var vfsBrokerDir: String
    var vfsMaterializedDir: String
    var workspaceRootPath: String
    var virtualCurrentDirectory: String
    var availableCommandNames: [String]
    var commandLookupPaths: [String: [String]]

    init(
        mode: String,
        moduleName: String?,
        sourceB64: String,
        filename: String,
        argv: [String],
        stdinB64: String,
        stdinFD: Int32? = nil,
        stdoutFD: Int32? = nil,
        stderrFD: Int32? = nil,
        environment: [String: String],
        fileCreationMask: Int,
        resultPath: String,
        subprocessBrokerDir: String,
        vfsBrokerDir: String,
        vfsMaterializedDir: String,
        workspaceRootPath: String,
        virtualCurrentDirectory: String,
        availableCommandNames: [String] = [],
        commandLookupPaths: [String: [String]] = [:]
    ) {
        self.mode = mode
        self.moduleName = moduleName
        self.sourceB64 = sourceB64
        self.filename = filename
        self.argv = argv
        self.stdinB64 = stdinB64
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.environment = environment
        self.fileCreationMask = fileCreationMask
        self.resultPath = resultPath
        self.subprocessBrokerDir = subprocessBrokerDir
        self.vfsBrokerDir = vfsBrokerDir
        self.vfsMaterializedDir = vfsMaterializedDir
        self.workspaceRootPath = workspaceRootPath
        self.virtualCurrentDirectory = virtualCurrentDirectory
        self.availableCommandNames = availableCommandNames
        self.commandLookupPaths = commandLookupPaths
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case moduleName = "module_name"
        case sourceB64 = "source_b64"
        case filename
        case argv
        case stdinB64 = "stdin_b64"
        case stdinFD = "stdin_fd"
        case stdoutFD = "stdout_fd"
        case stderrFD = "stderr_fd"
        case environment
        case fileCreationMask = "file_creation_mask"
        case resultPath = "result_path"
        case subprocessBrokerDir = "subprocess_broker_dir"
        case vfsBrokerDir = "vfs_broker_dir"
        case vfsMaterializedDir = "vfs_materialized_dir"
        case workspaceRootPath = "workspace_root_path"
        case virtualCurrentDirectory = "virtual_cwd"
        case availableCommandNames = "available_command_names"
        case commandLookupPaths = "command_lookup_paths"
    }
}
