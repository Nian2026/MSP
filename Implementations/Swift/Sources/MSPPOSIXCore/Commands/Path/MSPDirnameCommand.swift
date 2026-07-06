import MSPCore

public struct MSPDirnameCommand: MSPCommand {
    public let name = "dirname"
    public let summary: String? = "Strip the last component from file names."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: Self.helpText)
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "dirname (MSP coreutils-compatible) 9.1\n")
        }
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["z"],
            allowedLongOptions: ["zero"]
        )
        let parsed = try MSPPathCommandDiagnostics.parse(spec, arguments: invocation.arguments)
        let useNUL = parsed.options.contains { $0.matches(short: "z") || $0.matches(long: "zero") }
        guard !parsed.operands.isEmpty else {
            throw MSPPathCommandDiagnostics.missingOperand(name)
        }

        let delimiter = useNUL ? "\0" : "\n"
        let output = parsed.operands
            .map(Self.dirname)
            .joined(separator: delimiter) + delimiter
        return .success(stdout: output)
    }

    private static func dirname(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else {
            return "."
        }
        let trimmed = rawPath.trimmingTrailingSlashesPreservingRoot()
        guard !trimmed.allSatisfy({ $0 == "/" }) else {
            return "/"
        }
        guard let slash = trimmed.lastIndex(of: "/") else {
            return "."
        }
        if slash == trimmed.startIndex {
            return "/"
        }

        var result = String(trimmed[..<slash])
        while result.count > 1, result.last == "/" {
            result.removeLast()
        }
        return result.isEmpty ? "/" : result
    }

    private static let helpText = """
    Usage: dirname [OPTION] NAME...
    Output each NAME with its last non-slash component and trailing slashes
    removed; if NAME contains no /'s, output '.'.

      -z, --zero     end each output line with NUL, not newline
          --help     display this help and exit
          --version  output version information and exit

    """
}

private extension String {
    func trimmingTrailingSlashesPreservingRoot() -> String {
        guard !isEmpty else {
            return self
        }
        var result = self
        while result.count > 1, result.last == "/" {
            result.removeLast()
        }
        return result
    }
}
