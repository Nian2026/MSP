import MSPCore

enum MSPPOSIXCanonicalPathMode {
    case existingOnly
    case missingAllowed
    case missingFinalAllowed
}

extension MSPPOSIXCommandSupport {
    static func canonicalVirtualPath(
        _ rawPath: String,
        command: String,
        mode: MSPPOSIXCanonicalPathMode,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> String {
        let normalizedPath: String
        do {
            normalizedPath = try fileSystem.resolve(rawPath, from: currentDirectory).virtualPath
        } catch {
            throw canonicalizationFailure(command: command, rawPath: rawPath, error: error)
        }

        return try canonicalizeResolvedPath(
            normalizedPath,
            command: command,
            rawPath: rawPath,
            mode: mode,
            fileSystem: fileSystem
        )
    }

    private static func canonicalizeResolvedPath(
        _ path: String,
        command: String,
        rawPath: String,
        mode: MSPPOSIXCanonicalPathMode,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws -> String {
        var pending = MSPWorkspacePathResolver.components(in: path)
        var resolvedComponents: [String] = []
        var symlinkHops = 0

        while !pending.isEmpty {
            let component = pending.removeFirst()
            let candidateComponents = resolvedComponents + [component]
            let candidate = "/" + candidateComponents.joined(separator: "/")
            let isFinalComponent = pending.isEmpty

            if let target = try symbolicLinkTargetIfPresent(candidate, fileSystem: fileSystem) {
                symlinkHops += 1
                guard symlinkHops <= 40 else {
                    throw MSPCommandFailure(
                        result: .failure(
                            stderr: "\(command): \(rawPath): Too many levels of symbolic links\n"
                        )
                    )
                }

                let parent = resolvedComponents.isEmpty ? "/" : "/" + resolvedComponents.joined(separator: "/")
                let targetPath = target.hasPrefix("/")
                    ? MSPWorkspacePathResolver.normalize(target)
                    : MSPWorkspacePathResolver.normalize(target, from: parent)
                pending = MSPWorkspacePathResolver.components(in: targetPath) + pending
                resolvedComponents.removeAll()
                continue
            }

            do {
                let info = try fileSystem.stat(candidate, from: "/")
                if !isFinalComponent, info.type != .directory {
                    throw MSPWorkspaceFileSystemError.notDirectory(candidate)
                }
                resolvedComponents.append(component)
            } catch MSPWorkspaceFileSystemError.notFound {
                switch mode {
                case .existingOnly:
                    throw MSPCommandFailure(
                        result: .failure(stderr: "\(command): \(rawPath): No such file or directory\n")
                    )
                case .missingFinalAllowed where !isFinalComponent:
                    throw MSPCommandFailure(
                        result: .failure(stderr: "\(command): \(rawPath): No such file or directory\n")
                    )
                case .missingFinalAllowed, .missingAllowed:
                    resolvedComponents.append(component)
                    resolvedComponents.append(contentsOf: pending)
                    pending.removeAll()
                }
            } catch let error as MSPCommandFailure {
                throw error
            } catch {
                throw canonicalizationFailure(command: command, rawPath: rawPath, error: error)
            }
        }

        guard !resolvedComponents.isEmpty else {
            return "/"
        }
        return "/" + resolvedComponents.joined(separator: "/")
    }

    private static func symbolicLinkTargetIfPresent(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws -> String? {
        do {
            return try fileSystem.readSymbolicLink(path, from: "/")
        } catch MSPWorkspaceFileSystemError.notFound {
            return nil
        } catch MSPWorkspaceFileSystemError.notSymbolicLink {
            return nil
        }
    }

    private static func canonicalizationFailure(
        command: String,
        rawPath: String,
        error: Error
    ) -> MSPCommandFailure {
        MSPCommandFailure(
            result: .failure(
                stderr: "\(command): \(rawPath): \(diagnosticReason(from: error))\n"
            )
        )
    }
}
