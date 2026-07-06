import MSPCore

public struct MSPReadlinkCommand: MSPCommand {
    public let name = "readlink"
    public let summary: String? = "Print resolved symbolic link targets."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspReadlinkUsage())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "readlink (GNU coreutils) 9.1\n")
        }
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["z", "n", "f", "e", "m", "q", "s", "v"],
            allowedLongOptions: [
                "canonicalize",
                "canonicalize-existing",
                "canonicalize-missing",
                "no-newline",
                "quiet",
                "silent",
                "verbose",
                "zero"
            ]
        )
        let parsed = try MSPPathCommandDiagnostics.parse(spec, arguments: invocation.arguments)
        var zeroTerminated = false
        var omitTrailingNewline = false
        var mode: MSPPOSIXCanonicalPathMode?
        var verbose = false

        for option in parsed.options {
            switch option.name {
            case .short("z"), .long("zero"):
                zeroTerminated = true
            case .short("n"), .long("no-newline"):
                omitTrailingNewline = true
            case .short("f"), .long("canonicalize"):
                mode = .missingFinalAllowed
            case .short("e"), .long("canonicalize-existing"):
                mode = .existingOnly
            case .short("m"), .long("canonicalize-missing"):
                mode = .missingAllowed
            case .short("q"), .short("s"), .long("quiet"), .long("silent"):
                verbose = false
            case .short("v"), .long("verbose"):
                verbose = true
                continue
            default:
                continue
            }
        }

        guard !parsed.operands.isEmpty else {
            throw MSPPathCommandDiagnostics.missingOperand(name)
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let delimiter = zeroTerminated ? "\0" : "\n"

        if let mode {
            var paths: [String] = []
            var stderr = ""
            var exitCode: Int32 = 0
            for operand in parsed.operands {
                do {
                    paths.append(try MSPPOSIXCommandSupport.canonicalVirtualPath(
                        operand,
                        command: name,
                        mode: mode,
                        fileSystem: fileSystem,
                        currentDirectory: context.currentDirectory
                    ))
                } catch let failure as MSPCommandFailure {
                    exitCode = 1
                    if verbose {
                        stderr += failure.result.stderr
                    }
                } catch {
                    exitCode = 1
                    if verbose {
                        stderr += "\(name): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                    }
                }
            }
            let output = paths.joined(separator: delimiter)
            return MSPCommandResult(
                stdout: output + (paths.isEmpty || (!zeroTerminated && omitTrailingNewline) ? "" : delimiter),
                stderr: stderr,
                exitCode: exitCode
            )
        }

        var targets: [String] = []
        var stderr = ""
        var exitCode: Int32 = 0
        for operand in parsed.operands {
            if let virtualTarget = mspPOSIXVirtualReadlinkTarget(operand) {
                targets.append(virtualTarget)
                continue
            }
            do {
                targets.append(try fileSystem.readSymbolicLink(operand, from: context.currentDirectory))
            } catch {
                exitCode = 1
                if verbose {
                    stderr += "\(name): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                }
            }
        }

        let output = targets.joined(separator: delimiter)
        return MSPCommandResult(
            stdout: output + (targets.isEmpty || (!zeroTerminated && omitTrailingNewline) ? "" : delimiter),
            stderr: stderr,
            exitCode: exitCode
        )
    }
}

private func mspPOSIXVirtualReadlinkTarget(_ operand: String) -> String? {
    switch MSPWorkspacePathResolver.normalize(operand) {
    case "/bin/sh":
        return "dash"
    default:
        return nil
    }
}

private func mspReadlinkUsage() -> String {
    """
    Usage: readlink [OPTION]... FILE...
    Print symbolic link values or canonical file names inside the virtual workspace.

    """
}
