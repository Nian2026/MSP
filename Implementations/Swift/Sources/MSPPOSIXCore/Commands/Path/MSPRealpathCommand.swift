import MSPCore

public struct MSPRealpathCommand: MSPCommand {
    public let name = "realpath"
    public let summary: String? = "Print canonicalized workspace paths."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspRealpathUsage())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "realpath (GNU coreutils) 9.1\n")
        }
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["z", "m", "e", "q", "P", "L", "s"],
            allowedLongOptions: [
                "zero",
                "canonicalize-missing",
                "canonicalize-existing",
                "quiet",
                "logical",
                "no-symlinks",
                "physical",
                "strip",
                "canonicalize"
            ],
            longOptionsRequiringValue: ["relative-to", "relative-base"]
        )
        let parsed = try MSPPathCommandDiagnostics.parse(spec, arguments: invocation.arguments)
        var zeroTerminated = false
        var mode: MSPPOSIXCanonicalPathMode = .missingFinalAllowed
        var quiet = false
        var noSymlinks = false
        var relativeTo: String?
        var relativeBase: String?

        for option in parsed.options {
            switch option.name {
            case .short("z"), .long("zero"):
                zeroTerminated = true
            case .short("m"), .long("canonicalize-missing"):
                mode = .missingAllowed
            case .short("e"), .long("canonicalize-existing"), .long("canonicalize"):
                mode = .existingOnly
            case .short("q"), .long("quiet"):
                quiet = true
            case .short("s"), .long("strip"), .long("no-symlinks"):
                noSymlinks = true
            case .short("P"), .short("L"), .long("physical"), .long("logical"):
                continue
            case .long("relative-to"):
                relativeTo = option.value
            case .long("relative-base"):
                relativeBase = option.value
            default:
                continue
            }
        }

        guard !parsed.operands.isEmpty else {
            throw MSPPathCommandDiagnostics.missingOperand(name)
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        if relativeBase != nil, relativeTo == nil {
            relativeTo = relativeBase
        }

        let canonicalRelativeTo: String?
        let canonicalRelativeBase: String?
        do {
            canonicalRelativeTo = try relativeTo.map {
                try canonicalPath(
                    $0,
                    mode: mode,
                    noSymlinks: noSymlinks,
                    fileSystem: fileSystem,
                    currentDirectory: context.currentDirectory
                )
            }
            if relativeBase == relativeTo {
                canonicalRelativeBase = canonicalRelativeTo
            } else {
                canonicalRelativeBase = try relativeBase.map {
                    try canonicalPath(
                        $0,
                        mode: mode,
                        noSymlinks: noSymlinks,
                        fileSystem: fileSystem,
                        currentDirectory: context.currentDirectory
                    )
                }
            }
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            let operand = relativeTo ?? relativeBase ?? ""
            return .failure(
                stderr: "\(name): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            )
        }

        var paths: [String] = []
        var stderr = ""
        var exitCode: Int32 = 0
        for operand in parsed.operands {
            do {
                let path = try canonicalPath(
                    operand,
                    mode: mode,
                    noSymlinks: noSymlinks,
                    fileSystem: fileSystem,
                    currentDirectory: context.currentDirectory
                )
                paths.append(Self.outputPath(
                    path,
                    relativeTo: canonicalRelativeTo,
                    relativeBase: canonicalRelativeBase
                ))
            } catch let failure as MSPCommandFailure {
                exitCode = 1
                if !quiet {
                    stderr += failure.result.stderr
                }
            } catch {
                exitCode = 1
                if !quiet {
                    stderr += "\(name): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                }
            }
        }
        let delimiter = zeroTerminated ? "\0" : "\n"
        return MSPCommandResult(
            stdout: paths.isEmpty ? "" : paths.joined(separator: delimiter) + delimiter,
            stderr: stderr,
            exitCode: exitCode
        )
    }

    private func canonicalPath(
        _ operand: String,
        mode: MSPPOSIXCanonicalPathMode,
        noSymlinks: Bool,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> String {
        noSymlinks
            ? try Self.pathWithoutExpandingSymlinks(
                operand,
                command: name,
                mode: mode,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory
            )
            : try MSPPOSIXCommandSupport.canonicalVirtualPath(
                operand,
                command: name,
                mode: mode,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory
            )
    }

    private static func outputPath(
        _ path: String,
        relativeTo: String?,
        relativeBase: String?
    ) -> String {
        guard let relativeTo else {
            return path
        }
        if let relativeBase, !pathPrefix(relativeBase, path) {
            return path
        }
        return relativePath(from: relativeTo, to: path) ?? path
    }

    private static func pathWithoutExpandingSymlinks(
        _ rawPath: String,
        command: String,
        mode: MSPPOSIXCanonicalPathMode,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> String {
        let resolved: String
        do {
            resolved = try fileSystem.resolve(rawPath, from: currentDirectory).virtualPath
        } catch {
            throw MSPCommandFailure(
                result: .failure(
                    stderr: "\(command): \(MSPPOSIXCommandSupport.displayPath(rawPath)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                )
            )
        }

        guard mode == .existingOnly else {
            return resolved
        }
        do {
            _ = try fileSystem.stat(resolved, from: "/")
            return resolved
        } catch {
            throw MSPCommandFailure(
                result: .failure(
                    stderr: "\(command): \(MSPPOSIXCommandSupport.displayPath(rawPath)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                )
            )
        }
    }

    private static func pathPrefix(_ prefix: String, _ path: String) -> Bool {
        if prefix == "/" {
            return path.hasPrefix("/")
        }
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func relativePath(from base: String, to path: String) -> String? {
        let baseComponents = MSPWorkspacePathResolver.components(in: base)
        let pathComponents = MSPWorkspacePathResolver.components(in: path)
        var shared = 0
        while shared < baseComponents.count,
              shared < pathComponents.count,
              baseComponents[shared] == pathComponents[shared] {
            shared += 1
        }
        let upComponents = Array(repeating: "..", count: baseComponents.count - shared)
        let downComponents = Array(pathComponents.dropFirst(shared))
        let resultComponents = upComponents + downComponents
        return resultComponents.isEmpty ? "." : resultComponents.joined(separator: "/")
    }
}

private func mspRealpathUsage() -> String {
    """
    Usage: realpath [OPTION]... FILE...
    Print resolved virtual workspace paths.

    """
}
