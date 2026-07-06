import MSPCore

public struct MSPBasenameCommand: MSPCommand {
    public let name = "basename"
    public let summary: String? = "Strip directory and suffix from file names."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: Self.helpText)
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "basename (MSP coreutils-compatible) 9.1\n")
        }
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["a", "z"],
            allowedLongOptions: ["multiple", "zero"],
            shortOptionsRequiringValue: ["s"],
            longOptionsRequiringValue: ["suffix"]
        )
        let parsed = try MSPPathCommandDiagnostics.parse(
            spec,
            arguments: invocation.arguments,
            stopAtFirstOperand: true
        )
        var suffix: String?
        var multiple = false
        var useNUL = false

        for option in parsed.options {
            switch option.name {
            case .short("a"), .long("multiple"):
                multiple = true
            case .short("s"), .long("suffix"):
                suffix = option.value ?? ""
                multiple = true
            case .short("z"), .long("zero"):
                useNUL = true
            default:
                continue
            }
        }

        guard !parsed.operands.isEmpty else {
            throw MSPPathCommandDiagnostics.missingOperand(name)
        }

        let paths: [String]
        if multiple {
            paths = parsed.operands
        } else {
            guard parsed.operands.count <= 2 else {
                throw MSPPathCommandDiagnostics.extraOperand(name, parsed.operands[2])
            }
            paths = [parsed.operands[0]]
            if parsed.operands.count == 2 {
                suffix = parsed.operands[1]
            }
        }

        let delimiter = useNUL ? "\0" : "\n"
        let output = paths
            .map { Self.basename($0, removingSuffix: suffix) }
            .joined(separator: delimiter) + delimiter
        return .success(stdout: output)
    }

    private static func basename(_ rawPath: String, removingSuffix suffix: String?) -> String {
        guard !rawPath.isEmpty else {
            return ""
        }
        let trimmed = rawPath.trimmingTrailingSlashesPreservingRoot()
        let base: String
        if trimmed.allSatisfy({ $0 == "/" }) {
            base = "/"
        } else if let slash = trimmed.lastIndex(of: "/") {
            base = String(trimmed[trimmed.index(after: slash)...])
        } else {
            base = trimmed
        }

        guard let suffix,
              !suffix.isEmpty,
              base != suffix,
              base != "/",
              base.hasSuffix(suffix)
        else {
            return base
        }
        return String(base.dropLast(suffix.count))
    }

    private static let helpText = """
    Usage: basename NAME [SUFFIX]
      or:  basename OPTION... NAME...
    Print NAME with any leading directory components removed.
    If specified, also remove a trailing SUFFIX.

      -a, --multiple       support multiple arguments and treat each as a NAME
      -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a
      -z, --zero           end each output line with NUL, not newline
          --help           display this help and exit
          --version        output version information and exit

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
