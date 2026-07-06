import Foundation
import MSPCore

public struct MSPChmodCommand: MSPCommand {
    public let name = "chmod"
    public let summary: String? = "Change file mode bits."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try mspPOSIXParseChmodArguments(invocation.arguments)
        guard !parsed.operands.isEmpty else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "chmod: missing operand\nTry 'chmod --help' for more information.\n"
                )
            )
        }
        guard parsed.referencePath != nil || parsed.operands.count >= 2 else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "chmod: missing operand after \(mspPOSIXChmodQuote(parsed.operands[0]))\nTry 'chmod --help' for more information.\n"
                )
            )
        }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let modeSpec: String?
        let referenceMode: UInt16?
        let targets: [String]
        if let referencePath = parsed.referencePath {
            guard parsed.operands.count >= 1 else {
                throw MSPCommandFailure(
                    result: .failure(
                        exitCode: 1,
                        stderr: "chmod: missing operand\nTry 'chmod --help' for more information.\n"
                    )
                )
            }
            let referenceInfo = try fileSystem.stat(referencePath, from: context.currentDirectory)
            modeSpec = nil
            referenceMode = MSPPOSIXCommandSupport.mode(for: referenceInfo)
            targets = parsed.operands
        } else {
            modeSpec = parsed.operands[0]
            referenceMode = nil
            targets = Array(parsed.operands.dropFirst())
            _ = try mspPOSIXChmodPermissions(
                modeSpec ?? "",
                currentMode: 0o644,
                isDirectory: true
            )
        }

        var diagnostics: [String] = []
        var stdout = ""
        for target in targets {
            if parsed.preserveRoot, parsed.recursive, target == "/" {
                diagnostics.append("chmod: it is dangerous to operate recursively on '/'")
                continue
            }
            try mspPOSIXApplyChmod(
                modeSpec: modeSpec,
                referenceMode: referenceMode,
                path: target,
                currentDirectory: context.currentDirectory,
                displayPath: MSPPOSIXCommandSupport.displayPath(target),
                recursive: parsed.recursive,
                verbosity: parsed.verbosity,
                forceSilent: parsed.forceSilent,
                fileSystem: fileSystem,
                diagnostics: &diagnostics,
                stdout: &stdout
            )
        }
        return MSPCommandResult(
            stdout: stdout,
            stderr: diagnostics.isEmpty ? "" : diagnostics.joined(separator: "\n") + "\n",
            exitCode: diagnostics.isEmpty ? 0 : 1
        )
    }
}

private func mspPOSIXParseChmodArguments(_ arguments: [String]) throws -> ChmodParseResult {
    var result = ChmodParseResult()
    var operands: [String] = []
    var parsingOptions = true
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        if parsingOptions, argument == "--" {
            parsingOptions = false
            index += 1
            continue
        }
        if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
            if argument == "--recursive" {
                result.recursive = true
            } else if argument == "--changes" {
                result.verbosity = .changesOnly
            } else if argument == "--silent" || argument == "--quiet" {
                result.forceSilent = true
            } else if argument == "--verbose" {
                result.verbosity = .verbose
            } else if argument == "--preserve-root" {
                result.preserveRoot = true
            } else if argument == "--no-preserve-root" {
                result.preserveRoot = false
            } else if argument == "--reference" {
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure.usage("chmod: option '--reference' requires an argument\n")
                }
                result.referencePath = arguments[index]
            } else if argument.hasPrefix("--reference=") {
                result.referencePath = String(argument.dropFirst("--reference=".count))
            } else {
                throw MSPCommandFailure.usage("chmod: invalid option -- '\(argument.dropFirst(2).first ?? "?")'\n")
            }
            index += 1
            continue
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            let characters = Array(argument.dropFirst())
            var characterIndex = 0
            while characterIndex < characters.count {
                let option = characters[characterIndex]
                switch option {
                case "R":
                    result.recursive = true
                case "c":
                    result.verbosity = .changesOnly
                case "f":
                    result.forceSilent = true
                case "v":
                    result.verbosity = .verbose
                default:
                    operands.append(contentsOf: arguments[index...])
                    result.operands = operands
                    return result
                }
                characterIndex += 1
            }
            index += 1
            continue
        }
        operands.append(contentsOf: arguments[index...])
        break
    }

    result.operands = operands
    return result
}

private func mspPOSIXApplyChmod(
    modeSpec: String?,
    referenceMode: UInt16?,
    path: String,
    currentDirectory: String,
    displayPath: String,
    recursive: Bool,
    verbosity: ChmodVerbosity,
    forceSilent: Bool,
    fileSystem: any MSPWorkspaceFileSystem,
    diagnostics: inout [String],
    stdout: inout String
) throws {
    do {
        let resolved = try fileSystem.resolve(path, from: currentDirectory)
        let metadata = try fileSystem.stat(resolved.virtualPath, from: "/")
        if metadata.type != .symbolicLink {
            let oldMode = MSPPOSIXCommandSupport.mode(for: metadata)
            let permissions = try mspPOSIXChmodPermissions(
                modeSpec,
                referenceMode: referenceMode,
                currentMode: oldMode,
                isDirectory: metadata.isDirectory
            )
            try fileSystem.chmod(resolved.virtualPath, mode: permissions, from: "/")
            if verbosity == .verbose || (verbosity == .changesOnly && permissions != oldMode) {
                stdout += "mode of '\(displayPath)' changed from \(mspPOSIXChmodOctal(oldMode)) to \(mspPOSIXChmodOctal(permissions))\n"
            }
        }
        guard recursive, metadata.isDirectory else {
            return
        }
        for entry in try fileSystem.listDirectory(resolved.virtualPath, from: "/") {
            try mspPOSIXApplyChmod(
                modeSpec: modeSpec,
                referenceMode: referenceMode,
                path: entry.info.virtualPath,
                currentDirectory: "/",
                displayPath: mspPOSIXJoinDisplayPath(parent: displayPath, child: entry.name),
                recursive: true,
                verbosity: verbosity,
                forceSilent: forceSilent,
                fileSystem: fileSystem,
                diagnostics: &diagnostics,
                stdout: &stdout
            )
        }
    } catch let failure as MSPCommandFailure {
        throw failure
    } catch {
        guard !forceSilent else {
            return
        }
        let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
        diagnostics.append("chmod: cannot access '\(displayPath)': \(reason)")
    }
}

private struct ChmodParseResult {
    var recursive = false
    var forceSilent = false
    var preserveRoot = false
    var verbosity = ChmodVerbosity.normal
    var referencePath: String?
    var operands: [String] = []
}

private enum ChmodVerbosity {
    case normal
    case changesOnly
    case verbose
}

func mspPOSIXChmodPermissions(
    _ rawSpec: String,
    currentMode: UInt16,
    isDirectory: Bool
) throws -> UInt16 {
    try mspPOSIXChmodPermissions(
        Optional(rawSpec),
        referenceMode: nil,
        currentMode: currentMode,
        isDirectory: isDirectory
    )
}

private func mspPOSIXChmodPermissions(
    _ rawSpec: String?,
    referenceMode: UInt16?,
    currentMode: UInt16,
    isDirectory: Bool
) throws -> UInt16 {
    if let referenceMode {
        return referenceMode & 0o777
    }
    guard let rawSpec else {
        throw mspPOSIXChmodInvalidMode("")
    }
    let spec = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spec.isEmpty else {
        throw mspPOSIXChmodInvalidMode(rawSpec)
    }
    if let numericMode = mspPOSIXChmodNumericMode(spec) {
        return numericMode
    }
    return try spec.split(separator: ",", omittingEmptySubsequences: false).reduce(currentMode & 0o777) { mode, rawClause in
        try mspPOSIXChmodSymbolicClause(String(rawClause), currentMode: mode, isDirectory: isDirectory)
    }
}

private func mspPOSIXChmodNumericMode(_ spec: String) -> UInt16? {
    guard spec.allSatisfy({ ("0"..."7").contains($0) }),
          let value = UInt16(spec, radix: 8) else {
        return nil
    }
    return value & 0o777
}

private func mspPOSIXChmodSymbolicClause(
    _ clause: String,
    currentMode: UInt16,
    isDirectory: Bool
) throws -> UInt16 {
    let characters = Array(clause)
    var index = 0
    var who: Set<Character> = []
    while index < characters.count, "ugoa".contains(characters[index]) {
        who.insert(characters[index])
        index += 1
    }
    guard index < characters.count, "+-=".contains(characters[index]) else {
        throw mspPOSIXChmodInvalidMode(clause)
    }
    let operation = characters[index]
    index += 1
    if index == characters.count {
        guard operation == "=" else {
            throw mspPOSIXChmodInvalidMode(clause)
        }
    }

    var permissionMask: UInt16 = 0
    while index < characters.count {
        switch characters[index] {
        case "r":
            permissionMask |= 0o444
        case "w":
            permissionMask |= 0o222
        case "x":
            permissionMask |= 0o111
        case "X":
            if isDirectory || (currentMode & 0o111) != 0 {
                permissionMask |= 0o111
            }
        default:
            throw mspPOSIXChmodInvalidMode(clause)
        }
        index += 1
    }

    let whoMask = mspPOSIXChmodWhoMask(who)
    let mask = permissionMask & whoMask
    switch operation {
    case "+":
        return (currentMode | mask) & 0o777
    case "-":
        return (currentMode & ~mask) & 0o777
    case "=":
        return ((currentMode & ~whoMask) | mask) & 0o777
    default:
        throw mspPOSIXChmodInvalidMode(clause)
    }
}

private func mspPOSIXChmodWhoMask(_ who: Set<Character>) -> UInt16 {
    let normalized = who.isEmpty || who.contains("a") ? Set(["u", "g", "o"]) : who
    var mask: UInt16 = 0
    if normalized.contains("u") { mask |= 0o700 }
    if normalized.contains("g") { mask |= 0o070 }
    if normalized.contains("o") { mask |= 0o007 }
    return mask
}

private func mspPOSIXJoinDisplayPath(parent: String, child: String) -> String {
    if parent == "/" {
        return "/" + child
    }
    let trimmed = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty {
        return child
    }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}

private func mspPOSIXChmodInvalidMode(_ value: String) -> MSPCommandFailure {
    MSPCommandFailure(
        result: .failure(
            exitCode: 1,
            stderr: "chmod: invalid mode: \(mspPOSIXChmodQuote(value))\nTry 'chmod --help' for more information.\n"
        )
    )
}

private func mspPOSIXChmodQuote(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private func mspPOSIXChmodOctal(_ mode: UInt16) -> String {
    String(format: "%04o", mode & 0o777)
}
