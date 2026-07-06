import Foundation
import MSPCore

extension ModelShellProxy {
    func redirectionEnvironment(currentDirectory: String) -> IORedirectionEnvironment {
        IORedirectionEnvironment(
            readInput: { [self] path in
                try readRedirectionInput(path, currentDirectory: currentDirectory)
            },
            openReadWriteFile: { [self] path in
                try openReadWriteFile(path, currentDirectory: currentDirectory)
            },
            makeOutputSink: { [self] path, append in
                try makeOutputSink(path: path, append: append)
            },
            writeFileOutput: { [self] incoming, path, append in
                try writeRedirectionOutput(incoming, to: path, append: append)
            },
            readVirtualPath: { [self] path in
                try workspaceFileSystemForRedirection().readFile(path, from: "/")
            },
            writeVirtualPath: { [self] path, data in
                try workspaceFileSystemForRedirection().writeFile(
                    path,
                    data: data,
                    from: "/",
                    options: [.overwriteExisting],
                    creationMode: regularFileCreationMode()
                )
            },
            diagnosticReason: { [self] error in
                redirectionDiagnosticReason(from: error)
            },
            redirectionFailure: { [self] message in
                redirectionFailure(message)
            },
            commandFailure: { exitCode, stderr in
                MSPCommandFailure(result: .failure(exitCode: exitCode, stderr: stderr))
            }
        )
    }

    func processSubstitutionEnvironment() -> IOProcessSubstitutionEnvironment {
        IOProcessSubstitutionEnvironment(
            ensureTemporaryDirectory: { [self] path in
                let fileSystem = try workspaceFileSystemForRedirection()
                if let info = try? fileSystem.stat(path, from: "/") {
                    guard info.type == .directory else {
                        throw redirectionFailure("<(: process substitution temporary path is not a directory")
                    }
                    return false
                }

                do {
                    try fileSystem.createDirectory(path, from: "/", intermediates: true)
                    return true
                } catch {
                    throw redirectionFailure("<(: failed to create process substitution temporary directory")
                }
            },
            pathExists: { [self] path in
                guard let fileSystem = try? workspaceFileSystemForRedirection() else {
                    return false
                }
                return (try? fileSystem.stat(path, from: "/")) != nil
            },
            writeFile: { [self] path, data in
                let fileSystem = try workspaceFileSystemForRedirection()
                do {
                    try fileSystem.writeFile(
                        path,
                        data: data,
                        from: "/",
                        options: [.overwriteExisting],
                        creationMode: regularFileCreationMode()
                    )
                } catch {
                    throw redirectionFailure("\(path): \(redirectionDiagnosticReason(from: error))")
                }
            },
            readFileIfAvailable: { [self] path in
                let fileSystem = try workspaceFileSystemForRedirection()
                return (try? fileSystem.readFile(path, from: "/")) ?? Data()
            },
            remove: { [self] path, recursive in
                guard let fileSystem = try? workspaceFileSystemForRedirection() else {
                    return
                }
                try? fileSystem.remove(path, from: "/", recursive: recursive)
            },
            isDirectoryEmpty: { [self] path in
                guard let fileSystem = try? workspaceFileSystemForRedirection(),
                      let children = try? fileSystem.listDirectory(path, from: "/") else {
                    return false
                }
                return children.isEmpty
            },
            redirectionFailure: { [self] message in
                redirectionFailure(message)
            }
        )
    }

    func readRedirectionInput(_ path: String, currentDirectory: String) throws -> Data {
        if path == "/dev/null" {
            return Data()
        }
        let fileSystem = try workspaceFileSystemForRedirection()
        do {
            return try fileSystem.readFile(path, from: currentDirectory)
        } catch {
            throw redirectionFailure("\(path): \(redirectionDiagnosticReason(from: error))")
        }
    }

    func openReadWriteFile(_ path: String, currentDirectory: String) throws -> IORedirectionReadWriteFile {
        let fileSystem = try workspaceFileSystemForRedirection()
        do {
            let resolved = try fileSystem.resolve(path, from: currentDirectory)
            let data: Data
            do {
                let info = try fileSystem.stat(resolved.virtualPath, from: "/")
                guard !info.isDirectory else {
                    throw MSPWorkspaceFileSystemError.isDirectory(resolved.virtualPath)
                }
                data = try fileSystem.readFile(resolved.virtualPath, from: "/")
            } catch MSPWorkspaceFileSystemError.notFound {
                try fileSystem.writeFile(
                    resolved.virtualPath,
                    data: Data(),
                    from: "/",
                    options: [.overwriteExisting],
                    creationMode: regularFileCreationMode()
                )
                data = Data()
            }
            return IORedirectionReadWriteFile(data: data, virtualPath: resolved.virtualPath)
        } catch MSPWorkspaceFileSystemError.notFound {
            throw redirectionFailure("\(path): \(redirectionDiagnosticReason(from: MSPWorkspaceFileSystemError.notFound(path)))")
        } catch {
            throw redirectionFailure("\(path): \(redirectionDiagnosticReason(from: error))")
        }
    }

    func makeOutputSink(path: String, append: Bool) throws -> MSPRedirectionFileSink {
        let fileSystem = try workspaceFileSystemForRedirection()
        do {
            let resolved = try fileSystem.resolve(path, from: configuration.currentDirectory)
            if append {
                do {
                    let info = try fileSystem.stat(resolved.virtualPath, from: "/")
                    guard !info.isDirectory else {
                        throw MSPWorkspaceFileSystemError.isDirectory(resolved.virtualPath)
                    }
                } catch MSPWorkspaceFileSystemError.notFound {
                    try fileSystem.writeFile(
                        resolved.virtualPath,
                        data: Data(),
                        from: "/",
                        options: [.overwriteExisting],
                        creationMode: regularFileCreationMode()
                    )
                }
            } else {
                try fileSystem.writeFile(
                    resolved.virtualPath,
                    data: Data(),
                    from: "/",
                    options: [.overwriteExisting],
                    creationMode: regularFileCreationMode()
                )
            }
            return MSPRedirectionFileSink(path: resolved.virtualPath, append: append)
        } catch {
            throw redirectionFailure("\(path): \(redirectionDiagnosticReason(from: error))")
        }
    }

    func writeRedirectionOutput(_ incoming: Data, to path: String, append: Bool) throws {
        let fileSystem = try workspaceFileSystemForRedirection()
        do {
            let resolved = try fileSystem.resolve(path, from: "/")
            if append {
                try fileSystem.appendFile(
                    resolved.virtualPath,
                    data: incoming,
                    from: "/",
                    options: [],
                    creationMode: regularFileCreationMode()
                )
                return
            }
            try fileSystem.writeFile(
                resolved.virtualPath,
                data: incoming,
                from: "/",
                options: [.overwriteExisting],
                creationMode: regularFileCreationMode()
            )
        } catch {
            throw redirectionFailure("\(path): \(redirectionDiagnosticReason(from: error))")
        }
    }

    func workspaceFileSystemForRedirection() throws -> any MSPWorkspaceFileSystem {
        guard let workspace = configuration.workspace else {
            throw redirectionFailure("workspace is required for redirection")
        }
        return workspace.fileSystem
    }

    func regularFileCreationMode() -> UInt16 {
        (0o666 & ~configuration.fileCreationMask) & 0o777
    }

    func redirectionFailure(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(exitCode: 1, stderr: "shell: \(message)\n"))
    }

    func redirectionDiagnosticReason(from error: Error) -> String {
        guard let fileSystemError = error as? MSPWorkspaceFileSystemError else {
            return "\(error)"
        }
        switch fileSystemError {
        case .accessDenied, .hiddenPath:
            return "Permission denied"
        case .invalidPath:
            return "Invalid argument"
        case .notFound:
            return "No such file or directory"
        case .notDirectory:
            return "Not a directory"
        case .isDirectory:
            return "Is a directory"
        case .directoryNotEmpty:
            return "Directory not empty"
        case .notSymbolicLink:
            return "Invalid argument"
        case .alreadyExists:
            return "File exists"
        case .encodingFailed:
            return "Invalid or incomplete multibyte or wide character"
        case .io:
            return "Input/output error"
        }
    }
}
