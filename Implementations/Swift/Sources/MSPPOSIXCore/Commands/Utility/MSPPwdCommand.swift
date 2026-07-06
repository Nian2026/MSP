import MSPCore

public struct MSPPwdCommand: MSPCommand {
    public let name = "pwd"
    public let summary: String? = "Print the current workspace directory."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: Self.helpText)
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "pwd (MSP coreutils-compatible) 9.1\n")
        }
        var physical = false
        for argument in invocation.arguments {
            if argument == "--" {
                break
            }
            if argument == "--logical" {
                physical = false
                continue
            }
            if argument == "--physical" {
                physical = true
                continue
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                break
            }
            if argument.hasPrefix("--") {
                return .failure(
                    exitCode: 2,
                    stderr: mspPOSIXBashShellDiagnosticStderr(
                        "pwd: --: invalid option\npwd: usage: pwd [-LP]\n",
                        invocation: invocation
                    )
                )
            }
            for option in argument.dropFirst() {
                guard option == "L" || option == "P" else {
                    return .failure(
                        exitCode: 2,
                        stderr: mspPOSIXBashShellDiagnosticStderr(
                            "pwd: -\(option): invalid option\npwd: usage: pwd [-LP]\n",
                            invocation: invocation
                        )
                    )
                }
                physical = option == "P"
            }
        }
        if physical {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            let canonicalPath = try MSPPOSIXCommandSupport.canonicalVirtualPath(
                context.currentDirectory,
                command: name,
                mode: .existingOnly,
                fileSystem: fileSystem,
                currentDirectory: "/"
            )
            return .success(stdout: canonicalPath + "\n")
        }
        return .success(stdout: context.currentDirectory + "\n")
    }

    private static let helpText = """
    Usage: pwd [OPTION]...
    Print the full filename of the current working directory.

      -L, --logical   use PWD from environment, even if it contains symlinks
      -P, --physical  avoid all symlinks
          --help      display this help and exit
          --version   output version information and exit

    """
}
