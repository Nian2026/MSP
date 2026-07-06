import Foundation
import MSPCore

public struct MSPMktempCommand: MSPCommand {
    public var name: String { "mktemp" }
    public var summary: String? { "Create a temporary workspace file or directory." }

    private let spec = MSPPOSIXCommandSpec(
        name: "mktemp",
        allowedShortOptions: ["d", "q", "u", "t"],
        allowedLongOptions: ["directory", "quiet", "dry-run"],
        shortOptionsRequiringValue: ["p"],
        longOptionsRequiringValue: ["suffix"],
        longOptionsWithOptionalValue: ["tmpdir"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try spec.parse(invocation.arguments)
        guard parsed.operands.count <= 1 else {
            return .failure(
                stderr: "mktemp: too many templates\nTry 'mktemp --help' for more information.\n"
            )
        }
        let makeDirectory = parsed.options.contains { $0.matches(short: "d", long: "directory") }
        let dryRun = parsed.options.contains { $0.matches(short: "u", long: "dry-run") }
        let suppressDiagnostics = parsed.options.contains { $0.matches(short: "q", long: "quiet") }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)

        let rawTemplate = parsed.operands.first ?? "tmp.XXXXXXXXXX"
        let displayTemplate = mspPOSIXMktempDisplayTemplate(
            rawTemplate,
            options: parsed.options,
            environment: context.environment
        )
        let suffix = parsed.options.reversed().first { $0.matches(long: "suffix") }?.value ?? ""
        guard !suffix.contains("/") else {
            return .failure(stderr: "mktemp: invalid suffix \(mspPOSIXMktempQuote(suffix)), contains directory separator\n")
        }
        guard suffix.isEmpty || displayTemplate.hasSuffix("X") else {
            return .failure(stderr: "mktemp: with --suffix, template \(mspPOSIXMktempQuote(rawTemplate)) must end in X\n")
        }
        let effectiveTemplate = displayTemplate + suffix
        let suffixLength = suffix.isEmpty
            ? mspPOSIXMktempImplicitSuffixLength(in: effectiveTemplate)
            : suffix.count

        guard mspPOSIXTemporaryPath(from: effectiveTemplate, suffixLength: suffixLength) != nil else {
            return .failure(stderr: "mktemp: too few X's in template \(mspPOSIXMktempQuote(effectiveTemplate))\n")
        }

        for _ in 0..<100 {
            guard let displayCandidate = mspPOSIXTemporaryPath(from: effectiveTemplate, suffixLength: suffixLength) else {
                break
            }
            let virtualCandidate = try fileSystem.resolve(
                displayCandidate,
                from: context.currentDirectory
            ).virtualPath
            if (try? fileSystem.stat(virtualCandidate, from: "/")) != nil {
                continue
            }
            if dryRun {
                return .success(stdout: displayCandidate + "\n")
            }
            if makeDirectory {
                try fileSystem.createDirectory(
                    virtualCandidate,
                    from: "/",
                    intermediates: false,
                    creationMode: 0o700
                )
            } else {
                try fileSystem.writeFile(
                    virtualCandidate,
                    data: Data(),
                    from: "/",
                    options: [],
                    creationMode: 0o600
                )
            }
            return .success(stdout: displayCandidate + "\n")
        }

        guard !suppressDiagnostics else {
            return .failure(stderr: "")
        }
        let kind = makeDirectory ? "directory" : "file"
        return .failure(stderr: "mktemp: failed to create \(kind) via template \(rawTemplate)\n")
    }
}

private func mspPOSIXMktempDisplayTemplate(
    _ template: String,
    options: [MSPPOSIXOption],
    environment: [String: String]
) -> String {
    var useDestinationDirectory = false
    var destinationArgument: String?
    var usesDeprecatedT = false

    for option in options {
        switch option.name {
        case .short("p"):
            useDestinationDirectory = true
            destinationArgument = option.value
        case .long("tmpdir"):
            useDestinationDirectory = true
            destinationArgument = option.value
        case .short("t"):
            useDestinationDirectory = true
            usesDeprecatedT = true
        default:
            continue
        }
    }

    if template == "tmp.XXXXXXXXXX" {
        useDestinationDirectory = true
    }
    guard useDestinationDirectory else {
        return template
    }

    let destinationDirectory: String
    if usesDeprecatedT {
        if let tmpdir = environment["TMPDIR"], !tmpdir.isEmpty {
            destinationDirectory = tmpdir
        } else if let destinationArgument, !destinationArgument.isEmpty {
            destinationDirectory = destinationArgument
        } else {
            destinationDirectory = "/tmp"
        }
    } else if let destinationArgument, !destinationArgument.isEmpty {
        destinationDirectory = destinationArgument
    } else if let tmpdir = environment["TMPDIR"], !tmpdir.isEmpty {
        destinationDirectory = tmpdir
    } else {
        destinationDirectory = "/tmp"
    }

    return MSPWorkspacePathResolver.normalize(template, from: destinationDirectory)
}

private func mspPOSIXMktempImplicitSuffixLength(in template: String) -> Int {
    let characters = Array(template)
    guard let lastX = characters.lastIndex(of: "X") else {
        return 0
    }
    return characters.distance(from: characters.index(after: lastX), to: characters.endIndex)
}

private func mspPOSIXTemporaryPath(from template: String, suffixLength: Int) -> String? {
    let characters = Array(template)
    guard suffixLength >= 0, suffixLength <= characters.count else {
        return nil
    }
    let suffixStart = characters.count - suffixLength
    if suffixLength > 0,
       characters[suffixStart...].contains("/") {
        return nil
    }

    var runStart = suffixStart
    while runStart > 0, characters[runStart - 1] == "X" {
        runStart -= 1
    }

    let runLength = suffixStart - runStart
    guard runLength >= 3 else {
        return nil
    }

    let random = mspPOSIXRandomToken(count: runLength)
    let prefix = String(characters[..<runStart])
    let suffix = String(characters[suffixStart...])
    return prefix + random + suffix
}

private func mspPOSIXRandomToken(count: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return String((0..<count).map { _ in alphabet.randomElement()! })
}

private func mspPOSIXMktempQuote(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}
