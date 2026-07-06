import Foundation
import ModelShellProxy
import MSPApple
import MSPCore
import MSPGit
import MSPPythonEmbeddedRuntime

struct MSPPlaygroundShellRun: Equatable {
    var command: String
    var renderedText: String
    var stdout: String
    var stderr: String
    var stdoutData: Data
    var stderrData: Data
    var exitCode: Int32
}

enum MSPPlaygroundQuickLookError: Error, LocalizedError, Equatable {
    case notRegularFile(String)

    var errorDescription: String? {
        switch self {
        case .notRegularFile(let path):
            return "\(path) is not a previewable file"
        }
    }
}

@MainActor
final class MSPPlaygroundShellRuntime {
    let workspaceURL: URL

    private let workspaceFileSystem: any MSPWorkspaceFileSystem
    private let shell: ModelShellProxy

    init(
        workspaceURL: URL,
        workspaceProfile: MSPPlaygroundWorkspaceProfile = .configured(),
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.workspaceURL = workspaceURL
        let hostWorkspace = try MSPAppleWorkspace(rootURL: workspaceURL)
        let workspace = workspaceProfile.makeWorkspace(hostWorkspace: hostWorkspace)
        self.workspaceFileSystem = workspace.fileSystem
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore)
        if let gitCommandPack = MSPPlaygroundGitRuntimeProvider.commandPackIfRequested(
            arguments: arguments,
            environment: environment
        ) {
            try shell.enable(gitCommandPack)
        }
        if let pythonRuntime = try MSPPlaygroundPythonRuntimeProvider.runtimeIfRequested(
            workspaceURL: workspaceURL,
            arguments: arguments,
            environment: environment
        ) {
            try shell.enable(.python(runtime: pythonRuntime))
        }
        self.shell = shell
    }

    func run(_ command: String) async -> MSPPlaygroundShellRun {
        let result = await shell.run(command)
        return MSPPlaygroundShellRun(
            command: command,
            renderedText: MSPExecCommandRenderer.renderAgentText(from: result),
            stdout: result.stdout,
            stderr: result.stderr,
            stdoutData: result.stdoutData,
            stderrData: result.stderrData,
            exitCode: result.exitCode
        )
    }

    func execCommandBridge() -> MSPExecCommandBridge {
        shell.execCommandBridge()
    }

    func snapshotWorkspace(maxDepth: Int = 4) throws -> [WorkspaceFileNode] {
        try WorkspaceFileNode.loadChildren(
            path: "/",
            fileSystem: workspaceFileSystem,
            remainingDepth: maxDepth
        )
    }

    func quickLookURL(for virtualPath: String) throws -> URL {
        let info = try workspaceFileSystem.stat(virtualPath, from: "/")
        guard info.type == .regularFile else {
            throw MSPPlaygroundQuickLookError.notRegularFile(virtualPath)
        }

        let data = try workspaceFileSystem.readFile(virtualPath, from: "/")
        let previewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPPlaygroundQuickLook", isDirectory: true)
        try FileManager.default.createDirectory(
            at: previewDirectory,
            withIntermediateDirectories: true
        )
        let previewSessionDirectory = previewDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: previewSessionDirectory,
            withIntermediateDirectories: true
        )
        let previewURL = previewSessionDirectory
            .appendingPathComponent(Self.previewFileName(for: virtualPath), isDirectory: false)
        try data.write(to: previewURL, options: .atomic)
        return previewURL
    }

    func readTextFile(_ virtualPath: String) throws -> String {
        let data = try workspaceFileSystem.readFile(virtualPath, from: "/")
        guard let text = String(data: data, encoding: .utf8) else {
            throw MSPWorkspaceFileSystemError.encodingFailed(virtualPath)
        }
        return text
    }

    func writeTextFile(_ virtualPath: String, contents: String) throws {
        try workspaceFileSystem.writeFile(
            virtualPath,
            data: Data(contents.utf8),
            from: "/",
            options: [.overwriteExisting, .createParentDirectories, .atomic]
        )
    }

    func removeFile(_ virtualPath: String) throws {
        try workspaceFileSystem.remove(virtualPath, from: "/", recursive: false)
    }

    static func previewFileName(for virtualPath: String) -> String {
        let fallbackName = "workspace-file.txt"
        let rawName = virtualPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? fallbackName
        let allowedCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._- "))
        let sanitizedName = String(rawName.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "_"
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizedName.isEmpty ? fallbackName : sanitizedName
    }
}

enum MSPPlaygroundGitRuntimeProvider {
    static func commandPackIfRequested(
        arguments: [String],
        environment: [String: String]
    ) -> MSPGitCommandPack? {
        let gitRequested = arguments.contains("--msp-enable-git")
            || environment["MSP_PLAYGROUND_ENABLE_GIT"] == "1"
        guard gitRequested else {
            return nil
        }
        return MSPGitCommandPack(backend: MSPGitLibGit2Backend())
    }
}

enum MSPPlaygroundPythonRuntimeProvider {
    static func runtimeIfRequested(
        workspaceURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (any MSPPythonRuntime)? {
        let pythonDisabled = arguments.contains("--msp-disable-python")
            || environment["MSP_PLAYGROUND_ENABLE_PYTHON"] == "0"
        guard !pythonDisabled else {
            return nil
        }

        let explicitPythonRequested = arguments.contains("--msp-enable-python")
            || environment["MSP_PLAYGROUND_ENABLE_PYTHON"] == "1"
        let rawLibraryPath = argumentValue(
            named: "--msp-cpython-library-path",
            in: arguments
        ) ?? environment["MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH"]
        let explicitLibraryURL = rawLibraryPath.flatMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        let bundledLibraryURL = bundledCPythonLibraryURL()
        let libraryURL = explicitLibraryURL ?? bundledLibraryURL
        let pythonRequested = explicitPythonRequested || libraryURL != nil
        guard pythonRequested else {
            return nil
        }
        guard let libraryURL else {
            return MSPPythonEmbeddedRuntime(
                engine: MSPPlaygroundUnavailablePythonEngine(
                    reason: "CPython library is not configured"
                )
            )
        }
        let rawHomePath = argumentValue(
            named: "--msp-cpython-home",
            in: arguments
        ) ?? environment["MSP_PLAYGROUND_CPYTHON_HOME"]
        let homeURL = rawHomePath.flatMap { rawValue -> URL? in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        let bundledHomeURL = bundledCPythonHomeURL()
        let engine = try MSPCPythonEngine(
            library: .path(libraryURL),
            workspaceRootURL: workspaceURL,
            pythonHomeURL: homeURL ?? bundledHomeURL
        )
        return MSPPythonEmbeddedRuntime(engine: engine)
    }

    private static func bundledCPythonLibraryURL() -> URL? {
        let bundledURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Python.framework")
            .appendingPathComponent("Python")
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else {
            return nil
        }
        return bundledURL
    }

    private static func bundledCPythonHomeURL() -> URL? {
        let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("python")
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else {
            return nil
        }
        return bundledURL
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = name + "="
        if let inline = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }
}

private struct MSPPlaygroundUnavailablePythonEngine: MSPPythonEmbeddedEngine {
    var reason: String

    func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        throw MSPPythonEmbeddedRuntimeError.engineUnavailable(reason)
    }
}
