import Foundation
import MSPCore

public struct MSPTeeCommand: MSPStreamingCommand {
    public var name: String { "tee" }
    public var summary: String? { "Copy standard input to files and standard output." }

    private let spec = MSPPOSIXCommandSpec(
        name: "tee",
        allowedShortOptions: ["a", "i", "p"],
        allowedLongOptions: ["append", "ignore-interrupts", "help", "version"],
        longOptionsWithOptionalValue: ["output-error"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = Self.standardOptionResult(arguments: invocation.arguments) {
            return standardOption
        }
        let parsed = try spec.parse(invocation.arguments)
        let append = parsed.options.contains { $0.matches(short: "a", long: "append") }
        let outputErrorPolicy = try MSPTeeOutputErrorPolicy.parse(parsed.options)

        var fileSystem: (any MSPWorkspaceFileSystem)?
        var stdoutData = context.standardInput
        var stderrData = Data()
        var exitCode: Int32 = 0
        for operand in parsed.operands {
            let normalized = MSPWorkspacePathResolver.normalize(operand, from: context.currentDirectory)
            if normalized == "/dev/null" {
                continue
            }
            if normalized == "/dev/stdout" {
                stdoutData.append(context.standardInput)
                continue
            }
            if normalized == "/dev/stderr" {
                stderrData.append(context.standardInput)
                continue
            }
            do {
                if fileSystem == nil {
                    fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                }
                if append {
                    try fileSystem!.appendFile(
                        operand,
                        data: context.standardInput,
                        from: context.currentDirectory,
                        options: [.createParentDirectories],
                        creationMode: context.regularFileCreationMode
                    )
                } else {
                    try fileSystem!.writeFile(
                        operand,
                        data: context.standardInput,
                        from: context.currentDirectory,
                        options: [.overwriteExisting, .createParentDirectories],
                        creationMode: context.regularFileCreationMode
                    )
                }
            } catch {
                stderrData.append(contentsOf: "tee: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n".utf8)
                exitCode = 1
                if outputErrorPolicy.exitsOnNonPipeError {
                    return MSPCommandResult(
                        stdoutData: Data(),
                        stderrData: stderrData,
                        exitCode: exitCode
                    )
                }
            }
        }
        return MSPCommandResult(
            stdoutData: stdoutData,
            stderrData: stderrData,
            exitCode: exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = Self.standardOptionResult(arguments: invocation.arguments) {
            return standardOption
        }
        let parsed = try spec.parse(invocation.arguments)
        let outputErrorPolicy = try MSPTeeOutputErrorPolicy.parse(parsed.options)
        guard let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        let append = parsed.options.contains { $0.matches(short: "a", long: "append") }
        var regularFileOperands: [String] = []
        var stdoutMirrors = 0
        var stderrMirrors = 0

        for operand in parsed.operands {
            let normalized = MSPWorkspacePathResolver.normalize(operand, from: context.currentDirectory)
            switch normalized {
            case "/dev/null":
                continue
            case "/dev/stdout":
                stdoutMirrors += 1
            case "/dev/stderr":
                stderrMirrors += 1
            default:
                regularFileOperands.append(operand)
            }
        }

        var stderrMirrorData = Data()
        var fileSystem: (any MSPWorkspaceFileSystem)?
        var activeFileOperands: [String] = []
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        if !regularFileOperands.isEmpty {
            do {
                fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            } catch {
                diagnostics.append("tee: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                exitCode = 1
            }
        }

        if let fileSystem {
            for operand in regularFileOperands {
                do {
                    if append {
                        try fileSystem.appendFile(
                            operand,
                            data: Data(),
                            from: context.currentDirectory,
                            options: [.createParentDirectories],
                            creationMode: context.regularFileCreationMode
                        )
                    } else {
                        try fileSystem.writeFile(
                            operand,
                            data: Data(),
                            from: context.currentDirectory,
                            options: [.overwriteExisting, .createParentDirectories],
                            creationMode: context.regularFileCreationMode
                        )
                    }
                    activeFileOperands.append(operand)
                } catch {
                    diagnostics.append(
                        "tee: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                    )
                    exitCode = 1
                    if outputErrorPolicy.exitsOnNonPipeError {
                        return MSPCommandResult(
                            stderr: diagnostics.joined(separator: "\n") + "\n",
                            exitCode: exitCode
                        )
                    }
                }
            }
        }

        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                try await standardOutput.write(chunk)
                for _ in 0..<stdoutMirrors {
                    try await standardOutput.write(chunk)
                }
                if stderrMirrors > 0 {
                    if let standardError = context.standardErrorStream {
                        for _ in 0..<stderrMirrors {
                            try await standardError.write(chunk)
                        }
                    } else {
                        for _ in 0..<stderrMirrors {
                            stderrMirrorData.append(chunk)
                        }
                    }
                }
                if let fileSystem, !activeFileOperands.isEmpty {
                    var stillActive: [String] = []
                    for operand in activeFileOperands {
                        do {
                            try fileSystem.appendFile(
                                operand,
                                data: chunk,
                                from: context.currentDirectory,
                                options: [.createParentDirectories],
                                creationMode: context.regularFileCreationMode
                            )
                            stillActive.append(operand)
                        } catch {
                            diagnostics.append(
                                "tee: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                            )
                            exitCode = 1
                            if outputErrorPolicy.exitsOnNonPipeError {
                                var stderrData = stderrMirrorData
                                stderrData.append(contentsOf: (diagnostics.joined(separator: "\n") + "\n").utf8)
                                return MSPCommandResult(stdoutData: Data(), stderrData: stderrData, exitCode: exitCode)
                            }
                        }
                    }
                    activeFileOperands = stillActive
                }
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }

        var stderrData = stderrMirrorData
        if !diagnostics.isEmpty {
            stderrData.append(contentsOf: (diagnostics.joined(separator: "\n") + "\n").utf8)
        }
        return MSPCommandResult(stdoutData: Data(), stderrData: stderrData, exitCode: exitCode)
    }

    private static func standardOptionResult(arguments: [String]) -> MSPCommandResult? {
        if arguments.contains("--help") {
            return .success(stdout: helpText)
        }
        if arguments.contains("--version") {
            return .success(stdout: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: "tee"))
        }
        return nil
    }

    private static let helpText = """
    Usage: tee [OPTION]... [FILE]...
    Copy standard input to each FILE, and also to standard output.

      -a, --append              append to the given FILEs, do not overwrite
      -i, --ignore-interrupts   ignore interrupt signals
      -p                        diagnose errors writing to non pipes
          --output-error[=MODE] set behavior on write error
          --help     display this help and exit
          --version  output version information and exit
    """
}

private enum MSPTeeOutputErrorPolicy {
    case sigpipe
    case warn
    case warnNoPipe
    case exit
    case exitNoPipe

    var exitsOnNonPipeError: Bool {
        switch self {
        case .exit, .exitNoPipe:
            return true
        case .sigpipe, .warn, .warnNoPipe:
            return false
        }
    }

    static func parse(_ options: [MSPPOSIXOption]) throws -> MSPTeeOutputErrorPolicy {
        var policy: MSPTeeOutputErrorPolicy = .sigpipe
        for option in options where option.matches(short: "p", long: "output-error") {
            guard let value = option.value else {
                policy = .warnNoPipe
                continue
            }
            switch value {
            case "warn":
                policy = .warn
            case "warn-nopipe":
                policy = .warnNoPipe
            case "exit":
                policy = .exit
            case "exit-nopipe":
                policy = .exitNoPipe
            default:
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: """
                    tee: invalid argument \(MSPPOSIXCommandSupport.gnuQuote(value)) for \(MSPPOSIXCommandSupport.gnuQuote("--output-error"))
                    Valid arguments are:
                      - \(MSPPOSIXCommandSupport.gnuQuote("warn"))
                      - \(MSPPOSIXCommandSupport.gnuQuote("warn-nopipe"))
                      - \(MSPPOSIXCommandSupport.gnuQuote("exit"))
                      - \(MSPPOSIXCommandSupport.gnuQuote("exit-nopipe"))
                    Try 'tee --help' for more information.

                    """
                ))
            }
        }
        return policy
    }
}
