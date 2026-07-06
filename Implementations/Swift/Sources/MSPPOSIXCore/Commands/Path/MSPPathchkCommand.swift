import Foundation
import MSPCore

public struct MSPPathchkCommand: MSPCommand {
    public let name = "pathchk"
    public let summary: String? = "Check whether path names are valid and portable."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspPathchkUsage())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "pathchk (GNU coreutils) 9.1\n")
        }
        let parsed = mspPathchkParse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard !parsed.operands.isEmpty else {
            return .failure(stderr: "pathchk: missing operand\nTry 'pathchk --help' for more information.\n")
        }

        var stderr = ""
        var ok = true
        let fileSystem = try? MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        for operand in parsed.operands {
            if let diagnostic = mspPathchkDiagnostic(
                operand,
                checkBasicPortability: parsed.checkBasicPortability,
                checkExtraPortability: parsed.checkExtraPortability,
                fileSystem: fileSystem,
                currentDirectory: context.currentDirectory
            ) {
                stderr += diagnostic + "\n"
                ok = false
            }
        }
        return MSPCommandResult(stderr: stderr, exitCode: ok ? 0 : 1)
    }
}

private struct MSPPathchkOptions {
    var checkBasicPortability = false
    var checkExtraPortability = false
    var operands: [String] = []
    var result: MSPCommandResult?
}

private func mspPathchkParse(_ arguments: [String]) -> MSPPathchkOptions {
    var parsed = MSPPathchkOptions()
    var parsingOptions = true
    for argument in arguments {
        if parsingOptions, argument == "--" {
            parsingOptions = false
            continue
        }
        if parsingOptions, argument == "--portability" {
            parsed.checkBasicPortability = true
            parsed.checkExtraPortability = true
            continue
        }
        if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
            parsed.result = .failure(stderr: "pathchk: unrecognized option '\(argument)'\nTry 'pathchk --help' for more information.\n")
            return parsed
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            for option in argument.dropFirst() {
                switch option {
                case "p":
                    parsed.checkBasicPortability = true
                case "P":
                    parsed.checkExtraPortability = true
                default:
                    parsed.result = .failure(stderr: "pathchk: invalid option -- '\(option)'\nTry 'pathchk --help' for more information.\n")
                    return parsed
                }
            }
            continue
        }
        parsed.operands.append(argument)
    }
    return parsed
}

private func mspPathchkDiagnostic(
    _ path: String,
    checkBasicPortability: Bool,
    checkExtraPortability: Bool,
    fileSystem: (any MSPWorkspaceFileSystem)?,
    currentDirectory: String
) -> String? {
    let length = path.utf8.count
    if checkExtraPortability, mspPathchkHasLeadingHyphenComponent(path) {
        return "pathchk: leading '-' in a component of file name '\(path)'"
    }
    if (checkBasicPortability || checkExtraPortability), path.isEmpty {
        return "pathchk: empty file name"
    }
    if !checkBasicPortability, path.isEmpty {
        return "pathchk: '': No such file or directory"
    }
    if !checkBasicPortability,
       let fileSystem,
       let diagnostic = mspPathchkDefaultModeDiagnostic(
        path,
        fileSystem: fileSystem,
        currentDirectory: currentDirectory
       ) {
        return diagnostic
    }
    if checkBasicPortability {
        if let invalid = path.unicodeScalars.first(where: { !mspPathchkPortableScalars.contains($0) }) {
            return "pathchk: nonportable character '\(String(invalid))' in file name '\(path)'"
        }
        if length >= 256 {
            return "pathchk: limit 255 exceeded by length \(length) of file name '\(path)'"
        }
        if let longComponent = mspPathchkComponents(path).first(where: { $0.utf8.count > 14 }) {
            return "pathchk: limit 14 exceeded by length \(longComponent.utf8.count) of file name component '\(longComponent)'"
        }
    }
    return nil
}

private func mspPathchkDefaultModeDiagnostic(
    _ path: String,
    fileSystem: any MSPWorkspaceFileSystem,
    currentDirectory: String
) -> String? {
    guard MSPWorkspacePathResolver.isSyntacticallyValid(path) else {
        return "pathchk: \(MSPPOSIXCommandSupport.gnuQuote(path)): Invalid argument"
    }
    let normalized = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
    let components = MSPWorkspacePathResolver.components(in: normalized)
    guard components.count > 1 else {
        return nil
    }
    let displayComponents = mspPathchkComponents(path)
    let displayIsAbsolute = path.hasPrefix("/")
    var prefix = normalized.hasPrefix("/") ? "" : currentDirectory
    for (offset, component) in components.dropLast().enumerated() {
        prefix += "/" + component
        let displayPrefix = mspPathchkDisplayPrefix(
            components: displayComponents,
            offset: offset,
            isAbsolute: displayIsAbsolute,
            fallback: MSPPOSIXCommandSupport.displayPath(prefix)
        )
        do {
            let info = try fileSystem.stat(prefix, from: "/")
            guard info.type == .directory else {
                return "pathchk: \(MSPPOSIXCommandSupport.gnuQuote(displayPrefix)): Not a directory"
            }
        } catch MSPWorkspaceFileSystemError.notFound {
            return nil
        } catch {
            return "pathchk: \(MSPPOSIXCommandSupport.gnuQuote(displayPrefix)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
        }
    }
    return nil
}

private func mspPathchkDisplayPrefix(
    components: [String],
    offset: Int,
    isAbsolute: Bool,
    fallback: String
) -> String {
    guard offset < components.count else {
        return fallback
    }
    let prefix = components.prefix(offset + 1).joined(separator: "/")
    return isAbsolute ? "/" + prefix : prefix
}

private let mspPathchkPortableScalars = Set(
    "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars
)

private func mspPathchkComponents(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

private func mspPathchkHasLeadingHyphenComponent(_ path: String) -> Bool {
    mspPathchkComponents(path).contains { $0.hasPrefix("-") }
}

private func mspPathchkUsage() -> String {
    """
    Usage: pathchk [OPTION]... NAME...
    Diagnose invalid or non-portable path names in the virtual workspace.

    """
}
