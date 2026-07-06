import Foundation
import MSPCore
import MSPPOSIXCore

extension MSPPOSIXCoreFileOperationCommandTests {
    func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(
                workspace: workspace,
                availableCommandNames: registry.commandNames
            )
        )
    }

    func workerESymlinkDirectoryEntries() -> [String: WorkerEEntry] {
        [
            "/": .directory,
            "/src.txt": .file(Data("source\n".utf8)),
            "/target": .directory,
            "/dirlink": .symlink("/target")
        ]
    }

    final class WorkerEWorkspace: MSPWorkspace, @unchecked Sendable {
        let rootPath = "/"
        let fileSystem: any MSPWorkspaceFileSystem
        let fileSystemBox: WorkerEFileSystem

        init(entries: [String: WorkerEEntry]) {
            let fileSystem = WorkerEFileSystem(entries: entries)
            self.fileSystem = fileSystem
            self.fileSystemBox = fileSystem
        }
    }

    enum WorkerEEntry: Equatable {
        case file(Data)
        case directory
        case symlink(String)
    }

    struct WorkerECopyCall: Equatable {
        var source: String
        var destination: String
        var currentDirectory: String
        var options: MSPFileCopyOptions
    }

    struct WorkerEBatchCopyCall: Equatable {
        var requests: [MSPFileCopyRequest]
        var currentDirectory: String
        var options: MSPFileCopyOptions
    }

    struct WorkerEMoveCall: Equatable {
        var source: String
        var destination: String
        var currentDirectory: String
        var options: MSPFileMoveOptions
    }

    struct WorkerERemoveCall: Equatable {
        var path: String
        var currentDirectory: String
        var recursive: Bool
    }

    struct WorkerEHardLinkCall: Equatable {
        var source: String
        var link: String
        var currentDirectory: String
    }

    struct WorkerESymbolicLinkCall: Equatable {
        var target: String
        var link: String
        var currentDirectory: String
    }

    struct WorkerEWriteFileCall: Equatable {
        var path: String
        var data: Data
        var currentDirectory: String
        var options: MSPFileWriteOptions
    }

    struct WorkerEChmodCall: Equatable {
        var path: String
        var mode: UInt16
        var currentDirectory: String
    }

    struct WorkerECreateDirectoryCall: Equatable {
        var path: String
        var currentDirectory: String
        var intermediates: Bool
        var creationMode: UInt16?
    }

    final class WorkerEFileSystem: MSPWorkspaceBatchCopying, @unchecked Sendable {
        let policy = MSPWorkspaceFileSystemPolicy.default
        var entries: [String: WorkerEEntry]

        var copyCalls: [WorkerECopyCall] = []
        var batchCopyCalls: [WorkerEBatchCopyCall] = []
        var moveCalls: [WorkerEMoveCall] = []
        var removeCalls: [WorkerERemoveCall] = []
        var hardLinkCalls: [WorkerEHardLinkCall] = []
        var symbolicLinkCalls: [WorkerESymbolicLinkCall] = []
        var writeFileCalls: [WorkerEWriteFileCall] = []
        var chmodCalls: [WorkerEChmodCall] = []
        var createDirectoryCalls: [WorkerECreateDirectoryCall] = []
        var listDirectoryCallCount = 0
        var readFileCallCount = 0

        init(entries: [String: WorkerEEntry]) {
            self.entries = entries
        }

        func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
            guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
                  MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
            else {
                throw MSPWorkspaceFileSystemError.invalidPath(path)
            }
            return MSPResolvedPath(
                virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
            )
        }

        func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
            let virtualPath = try resolve(path, from: currentDirectory).virtualPath
            guard let entry = entries[virtualPath] else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            switch entry {
            case .file(let data):
                return MSPFileInfo(
                    virtualPath: virtualPath,
                    type: .regularFile,
                    size: Int64(data.count)
                )
            case .directory:
                return MSPFileInfo(virtualPath: virtualPath, type: .directory)
            case .symlink(let target):
                return MSPFileInfo(
                    virtualPath: virtualPath,
                    type: .symbolicLink,
                    symbolicLinkTarget: target
                )
            }
        }

        func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
            listDirectoryCallCount += 1
            throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
        }

        func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
            let virtualPath = try resolve(path, from: currentDirectory).virtualPath
            guard let entry = entries[virtualPath] else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            guard case .symlink(let target) = entry else {
                throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
            }
            return target
        }

        func readFile(_ path: String, from currentDirectory: String) throws -> Data {
            readFileCallCount += 1
            let virtualPath = try resolve(path, from: currentDirectory).virtualPath
            guard let entry = entries[virtualPath] else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            guard case .file(let data) = entry else {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            return data
        }

        func writeFile(
            _ path: String,
            data: Data,
            from currentDirectory: String,
            options: MSPFileWriteOptions
        ) throws {
            writeFileCalls.append(WorkerEWriteFileCall(
                path: path,
                data: data,
                currentDirectory: currentDirectory,
                options: options
            ))
        }

        func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
            createDirectoryCalls.append(WorkerECreateDirectoryCall(
                path: path,
                currentDirectory: currentDirectory,
                intermediates: intermediates,
                creationMode: nil
            ))
        }

        func createDirectory(
            _ path: String,
            from currentDirectory: String,
            intermediates: Bool,
            creationMode: UInt16?
        ) throws {
            createDirectoryCalls.append(WorkerECreateDirectoryCall(
                path: path,
                currentDirectory: currentDirectory,
                intermediates: intermediates,
                creationMode: creationMode
            ))
        }

        func touch(_ path: String, from currentDirectory: String) throws {}

        func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
            removeCalls.append(WorkerERemoveCall(
                path: path,
                currentDirectory: currentDirectory,
                recursive: recursive
            ))
        }

        func copy(
            _ sourcePath: String,
            to destinationPath: String,
            from currentDirectory: String,
            options: MSPFileCopyOptions
        ) throws {
            copyCalls.append(WorkerECopyCall(
                source: sourcePath,
                destination: destinationPath,
                currentDirectory: currentDirectory,
                options: options
            ))
        }

        func copy(
            _ requests: [MSPFileCopyRequest],
            from currentDirectory: String,
            options: MSPFileCopyOptions
        ) throws {
            batchCopyCalls.append(WorkerEBatchCopyCall(
                requests: requests,
                currentDirectory: currentDirectory,
                options: options
            ))
        }

        func move(
            _ sourcePath: String,
            to destinationPath: String,
            from currentDirectory: String,
            options: MSPFileMoveOptions
        ) throws {
            moveCalls.append(WorkerEMoveCall(
                source: sourcePath,
                destination: destinationPath,
                currentDirectory: currentDirectory,
                options: options
            ))
        }

        func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
            hardLinkCalls.append(WorkerEHardLinkCall(
                source: sourcePath,
                link: linkPath,
                currentDirectory: currentDirectory
            ))
        }

        func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
            symbolicLinkCalls.append(WorkerESymbolicLinkCall(
                target: target,
                link: linkPath,
                currentDirectory: currentDirectory
            ))
        }

        func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
            chmodCalls.append(WorkerEChmodCall(path: path, mode: mode, currentDirectory: currentDirectory))
        }
    }
}
