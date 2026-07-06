import Foundation
import MSPCore

let mspCore100DefaultInstallMode: UInt16 = 0o755
let mspCore100DefaultFileMode: UInt16 = 0o644
let mspCore100MaximumMaterializedFileSize = 64 * 1024 * 1024

func mspCore100SingleQuote(_ value: String) -> String {
    "'\(value)'"
}

func mspCore100CurlyQuote(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

func mspCore100ParentPath(of path: String) -> String {
    var components = MSPWorkspacePathResolver.components(in: path)
    guard !components.isEmpty else {
        return "/"
    }
    components.removeLast()
    return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
}

func mspCore100Basename(_ path: String) -> String {
    let components = MSPWorkspacePathResolver.components(in: path)
    return components.last ?? path
}

func mspCore100JoinPath(parent: String, child: String) -> String {
    parent == "/" ? "/" + child : parent + "/" + child
}

func mspCore100DisplayPath(_ path: String) -> String {
    MSPPOSIXCommandSupport.displayPath(path)
}

func mspCore100Reason(_ error: Error) -> String {
    MSPPOSIXCommandSupport.diagnosticReason(from: error)
}

func mspCore100ParseOctalMode(_ rawValue: String, command: String) throws -> UInt16 {
    guard !rawValue.isEmpty,
          rawValue.allSatisfy({ ("0"..."7").contains($0) }),
          let parsed = UInt16(rawValue, radix: 8),
          parsed <= 0o7777 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "\(command): invalid mode \(mspCore100CurlyQuote(rawValue))\n"
        ))
    }
    return parsed & 0o777
}

func mspCore100MissingOperand(_ command: String, noun: String = "operand") -> MSPCommandResult {
    .failure(
        exitCode: 1,
        stderr: "\(command): missing \(noun)\nTry '\(command) --help' for more information.\n"
    )
}

func mspCore100InvalidOption(_ command: String, option: Character) -> MSPCommandResult {
    .failure(
        exitCode: 1,
        stderr: "\(command): invalid option -- '\(option)'\nTry '\(command) --help' for more information.\n"
    )
}

func mspCore100GNUHelpHint(_ command: String) -> String {
    "Try '\(command) --help' for more information.\n"
}

func mspCore100AppendDiagnostic(_ diagnostics: inout [String], _ message: String) {
    diagnostics.append(message)
}

func mspCore100NormalizedOperandPath(_ path: String) -> String {
    var value = path
    while value.count > 1, value.hasSuffix("/") {
        value.removeLast()
    }
    return value.isEmpty ? "." : value
}

func mspCore100ParentDisplayPath(of path: String) -> String? {
    let normalized = mspCore100NormalizedOperandPath(path)
    guard normalized != "/", normalized != "." else {
        return nil
    }
    if let slash = normalized.lastIndex(of: "/") {
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }
    return nil
}

func mspCore100IsDirectory(_ info: MSPFileInfo) -> Bool {
    info.type == .directory
}

func mspCore100IsSymlinkToDirectory(
    _ info: MSPFileInfo,
    parentVirtualPath: String,
    fileSystem: any MSPWorkspaceFileSystem
) -> Bool {
    guard info.type == .symbolicLink,
          let target = info.symbolicLinkTarget,
          !target.isEmpty
    else {
        return false
    }
    let targetPath: String
    if target.hasPrefix("/") {
        targetPath = target
    } else {
        targetPath = mspCore100JoinPath(parent: parentVirtualPath, child: target)
    }
    guard let targetInfo = try? fileSystem.stat(targetPath, from: "/") else {
        return false
    }
    return targetInfo.type == .directory
}

func mspCore100GlobMatch(_ value: String, pattern: String) -> Bool {
    let valueCharacters = Array(value)
    let patternCharacters = Array(pattern)
    var memo: [String: Bool] = [:]

    func key(_ valueIndex: Int, _ patternIndex: Int) -> String {
        "\(valueIndex):\(patternIndex)"
    }

    func match(_ valueIndex: Int, _ patternIndex: Int) -> Bool {
        let memoKey = key(valueIndex, patternIndex)
        if let cached = memo[memoKey] {
            return cached
        }
        let result: Bool
        if patternIndex == patternCharacters.count {
            result = valueIndex == valueCharacters.count
        } else {
            let patternCharacter = patternCharacters[patternIndex]
            if patternCharacter == "*" {
                result = match(valueIndex, patternIndex + 1)
                    || (valueIndex < valueCharacters.count && match(valueIndex + 1, patternIndex))
            } else if patternCharacter == "?" {
                result = valueIndex < valueCharacters.count && match(valueIndex + 1, patternIndex + 1)
            } else {
                result = valueIndex < valueCharacters.count
                    && valueCharacters[valueIndex] == patternCharacter
                    && match(valueIndex + 1, patternIndex + 1)
            }
        }
        memo[memoKey] = result
        return result
    }

    return match(0, 0)
}
