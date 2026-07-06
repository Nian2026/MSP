import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore
import MSPShell

extension MSPTextLanguageCommandOracleTests {
    func assertCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        stdin: String = "",
        stdout: String = "",
        stdoutPrefix: String? = nil,
        stderr: String = "",
        exitCode: Int32 = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await runCommand(name, arguments, workspace: workspace, standardInput: Data(stdin.utf8))

        if let stdoutPrefix {
            XCTAssertTrue(
                result.stdout.hasPrefix(stdoutPrefix),
                "stdout prefix mismatch for \(name) \(arguments): \(result.stdout)",
                file: file,
                line: line
            )
        } else {
            XCTAssertEqual(result.stdout, stdout, "stdout mismatch for \(name) \(arguments)", file: file, line: line)
        }
        XCTAssertEqual(result.stderr, stderr, "stderr mismatch for \(name) \(arguments)", file: file, line: line)
        XCTAssertEqual(result.exitCode, exitCode, "exit code mismatch for \(name) \(arguments)", file: file, line: line)
    }

    func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        standardInput: Data
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        let subcommandRunner: MSPSubcommandRunner = { invocation, context in
            await executor.run(invocation: invocation, context: context)
        }
        let commandLineRunner: MSPCommandLineRunner = { commandLine, context in
            do {
                let parsed = try MSPShellParser().parseExecutableInvocation(commandLine)
                var childContext = context
                childContext.subcommandRunner = subcommandRunner
                return await executor.run(
                    invocation: MSPCommandInvocation(
                        name: parsed.commandName,
                        arguments: parsed.arguments,
                        rawInput: parsed.rawInput
                    ),
                    context: childContext
                )
            } catch {
                return .failure(exitCode: 2, stderr: "shell: \(error)\n")
            }
        }
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(
                workspace: workspace,
                standardInput: standardInput,
                availableCommandNames: registry.commandNames,
                subcommandRunner: subcommandRunner,
                commandLineRunner: commandLineRunner
            )
        )
    }

    static func externalAwkPath() -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["MSP_AWK_ORACLE"]
        let candidates = [environmentPath, "/usr/bin/awk", "/bin/awk"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func runExternalAwk(
        path: String,
        program: String,
        stdin: String
    ) throws -> AwkExternalOracleResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [program]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try inputPipe.fileHandleForWriting.close()
        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return AwkExternalOracleResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }
}

struct AwkOracleCase {
    var program: String
    var stdin: String
}

struct AwkExternalOracleResult {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
}

final class TextLanguageOracleWorkspace: MSPWorkspace, @unchecked Sendable {
    let rootPath = "/"
    let oracleFileSystem: TextLanguageOracleFileSystem
    var fileSystem: any MSPWorkspaceFileSystem { oracleFileSystem }

    init(files: [String: Data]) {
        self.oracleFileSystem = TextLanguageOracleFileSystem(files: files)
    }
}

final class TextLanguageOracleFileSystem: MSPWorkspaceSequentialFileReading, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]
    private(set) var readFileCallCount = 0
    private(set) var sequentialOpenCount = 0

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if files[virtualPath] != nil {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile)
        }
        if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        let prefix = virtualPath == "/" ? "/" : virtualPath + "/"
        var entriesByName: [String: MSPDirectoryEntry] = [:]
        for filePath in files.keys where filePath.hasPrefix(prefix) {
            let remainder = String(filePath.dropFirst(prefix.count))
            guard let component = remainder.split(separator: "/", maxSplits: 1).first else {
                continue
            }
            let name = String(component)
            let childPath = virtualPath == "/" ? "/" + name : virtualPath + "/" + name
            let isDirectory = files[childPath] == nil && files.keys.contains { $0.hasPrefix(childPath + "/") }
            entriesByName[name] = MSPDirectoryEntry(
                name: name,
                info: MSPFileInfo(virtualPath: childPath, type: isDirectory ? .directory : .regularFile)
            )
        }
        return entriesByName.keys.sorted().compactMap { entriesByName[$0] }
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        readFileCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func openSequentialFileReader(
        _ path: String,
        from currentDirectory: String
    ) throws -> (any MSPWorkspaceSequentialFileReader)? {
        sequentialOpenCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return TextLanguageOracleDataSequentialFileReader(data: data)
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath] = data
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "mkdir")
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath] = files[virtualPath] ?? Data()
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files.removeValue(forKey: virtualPath)
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        let source = try readFile(sourcePath, from: currentDirectory)
        try writeFile(destinationPath, data: source, from: currentDirectory, options: [.overwriteExisting])
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        let source = try readFile(sourcePath, from: currentDirectory)
        try writeFile(destinationPath, data: source, from: currentDirectory, options: [.overwriteExisting])
        try remove(sourcePath, from: currentDirectory, recursive: false)
    }
}

private final class TextLanguageOracleDataSequentialFileReader: MSPWorkspaceSequentialFileReader, @unchecked Sendable {
    private let data: Data
    private var offset = 0
    private var closed = false

    init(data: Data) {
        self.data = data
    }

    func read(upToCount count: Int) throws -> Data? {
        guard !closed, offset < data.count else {
            return nil
        }
        let end = min(data.count, offset + max(1, count))
        let chunk = data.subdata(in: offset..<end)
        offset = end
        return chunk
    }

    func close() throws {
        closed = true
    }
}
