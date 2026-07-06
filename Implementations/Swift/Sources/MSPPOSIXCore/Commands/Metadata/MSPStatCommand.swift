import Foundation
import MSPCore

public struct MSPStatCommand: MSPCommand {
    public let name = "stat"
    public let summary: String? = "Display workspace file metadata."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["f", "L", "t"],
            allowedLongOptions: ["dereference", "file-system", "help", "terse", "version"],
            shortOptionsRequiringValue: ["c"],
            longOptionsRequiringValue: ["cached", "format", "printf"]
        )
        let parsed = try spec.parse(invocation.arguments)
        var formatMode: MSPStatFormatMode?
        var fileSystemMode = false
        var terseMode = false
        var dereference = false
        for option in parsed.options {
            switch option.name {
            case .long("help"):
                return .success(stdout: mspStatUsage())
            case .long("version"):
                return .success(stdout: "stat (GNU coreutils) 9.1\n")
            case .short("f"), .long("file-system"):
                fileSystemMode = true
            case .short("L"), .long("dereference"):
                dereference = true
            case .short("t"), .long("terse"):
                terseMode = true
            case .short("c"), .long("format"), .long("printf"):
                guard let value = option.value else {
                    throw MSPCommandFailure.usage(
                        "stat: \(MSPPOSIXOptionParser.optionDisplayName(option)) requires a format\n"
                    )
                }
                formatMode = MSPStatFormatMode(
                    format: value,
                    interpretsEscapes: option.matches(long: "printf"),
                    appendsNewline: !option.matches(long: "printf")
                )
            case .long("cached"):
                continue
            default:
                continue
            }
        }
        guard !parsed.operands.isEmpty else {
            throw MSPCommandFailure.usage("stat: missing operand\n")
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var output: [String] = []
        var diagnostics: [String] = []
        for operand in parsed.operands {
            do {
                let resolved = try statPath(
                    operand,
                    dereference: dereference,
                    fileSystem: fileSystem,
                    currentDirectory: context.currentDirectory
                )
                let info = try fileSystem.stat(resolved, from: "/")
                if fileSystemMode {
                    let format = formatMode?.format ?? (terseMode ? "%n %i %l %t %s %S %b %f %a %c %d" : "%n %T")
                    output.append(formattedStatFileSystem(
                        format,
                        displayPath: operand,
                        interpretsEscapes: formatMode?.interpretsEscapes ?? false
                    ))
                } else if let formatMode {
                    output.append(formattedStat(
                        formatMode.format,
                        for: info,
                        displayPath: operand,
                        interpretsEscapes: formatMode.interpretsEscapes
                    ))
                } else if terseMode {
                    output.append(formattedStat(
                        "%n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o",
                        for: info,
                        displayPath: operand,
                        interpretsEscapes: false
                    ))
                } else {
                    output.append(defaultStatOutput(for: info, displayPath: operand))
                }
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(operand)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("stat: cannot statx '\(displayPath)': \(reason)")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(
                stdout: statOutput(output, formatMode: formatMode),
                stderr: diagnostics.joined(separator: "\n") + "\n"
            )
        }
        if formatMode != nil {
            return .success(stdout: statOutput(output, formatMode: formatMode))
        }
        return MSPPOSIXCommandSupport.successWithTrailingNewline(output.joined(separator: "\n\n"))
    }

    private func defaultStatOutput(for info: MSPFileInfo, displayPath: String) -> String {
        let size = MSPPOSIXCommandSupport.byteSize(info)
        let blocks = (size + 511) / 512
        let modeOctal = MSPPOSIXCommandSupport.modeOctalString(for: info)
        let modeString = MSPPOSIXCommandSupport.modeString(for: info)
        let timestamp = defaultStatTimestamp(info.modificationDate)
        let user = MSPPOSIXVirtualIdentity.currentUser
        let lines = [
            "  File: \(displayPath)",
            "  Size: \(size)        \tBlocks: \(blocks)          IO Block: 4096   \(MSPPOSIXCommandSupport.typeDescription(for: info))",
            "Device: 0,0\tInode: \(stableIdentifier(for: info.virtualPath))      Links: 1",
            "Access: (0\(modeOctal)/\(modeString))  Uid: (\(mspStatPadLeft("\(user.uid)", width: 5))/\(mspStatPadLeft(user.name, width: 8)))   Gid: (\(mspStatPadLeft("\(user.gid)", width: 5))/\(mspStatPadLeft(user.groupName, width: 8)))",
            "Access: \(timestamp)",
            "Modify: \(timestamp)",
            "Change: \(timestamp)",
            " Birth: -"
        ]
        return lines.joined(separator: "\n")
    }

    private func formattedStat(
        _ format: String,
        for info: MSPFileInfo,
        displayPath: String,
        interpretsEscapes: Bool
    ) -> String {
        var output = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            if interpretsEscapes, character == "\\" {
                let next = format.index(after: index)
                guard next < format.endIndex else {
                    output.append(character)
                    index = next
                    continue
                }
                switch format[next] {
                case "a":
                    output.append("\u{7}")
                case "b":
                    output.append("\u{8}")
                case "f":
                    output.append("\u{c}")
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                case "v":
                    output.append("\u{b}")
                case "\\":
                    output.append("\\")
                default:
                    output.append("\\")
                    output.append(format[next])
                }
                index = format.index(after: next)
                continue
            }

            guard character == "%" else {
                output.append(character)
                index = format.index(after: index)
                continue
            }

            let next = format.index(after: index)
            guard next < format.endIndex else {
                output.append(character)
                index = next
                continue
            }

            let size = MSPPOSIXCommandSupport.byteSize(info)
            let modifiedEpoch = Int(info.modificationDate?.timeIntervalSince1970 ?? 0)
            let user = MSPPOSIXVirtualIdentity.currentUser
            switch format[next] {
            case "%":
                output.append("%")
            case "a":
                output += MSPPOSIXCommandSupport.modeOctalString(for: info)
            case "A":
                output += MSPPOSIXCommandSupport.modeString(for: info)
            case "b":
                output += String((size + 511) / 512)
            case "B":
                output += "512"
            case "C":
                output += "?"
            case "d":
                output += "0"
            case "F":
                output += MSPPOSIXCommandSupport.typeDescription(for: info)
            case "f":
                output += fileModeHex(for: info)
            case "g":
                output += "\(user.gid)"
            case "G":
                output += user.groupName
            case "h":
                output += "1"
            case "i":
                output += String(stableIdentifier(for: info.virtualPath))
            case "n":
                output += displayPath
            case "N":
                output += "'\(displayPath)'"
            case "o":
                output += "4096"
            case "m":
                output += "/"
            case "r", "R":
                output += "0"
            case "s":
                output += String(size)
            case "t", "T":
                output += "0"
            case "u":
                output += "\(user.uid)"
            case "U":
                output += user.name
            case "D":
                output += "0"
            case "w":
                output += "-"
            case "W":
                output += "-1"
            case "x", "y", "z":
                output += MSPPOSIXCommandSupport.formattedDate(info.modificationDate)
            case "X", "Y", "Z":
                output += String(modifiedEpoch)
            default:
                output.append("%")
                output.append(format[next])
            }
            index = format.index(after: next)
        }
        return output
    }

    private func formattedStatFileSystem(
        _ format: String,
        displayPath: String,
        interpretsEscapes: Bool
    ) -> String {
        var output = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            if interpretsEscapes, character == "\\" {
                let next = format.index(after: index)
                guard next < format.endIndex else {
                    output.append(character)
                    index = next
                    continue
                }
                switch format[next] {
                case "n":
                    output.append("\n")
                case "t":
                    output.append("\t")
                case "\\":
                    output.append("\\")
                default:
                    output.append("\\")
                    output.append(format[next])
                }
                index = format.index(after: next)
                continue
            }
            guard character == "%" else {
                output.append(character)
                index = format.index(after: index)
                continue
            }
            let next = format.index(after: index)
            guard next < format.endIndex else {
                output.append(character)
                index = next
                continue
            }
            switch format[next] {
            case "%":
                output.append("%")
            case "n":
                output += displayPath
            case "T":
                output += "ext2/ext3"
            case "i":
                output += "0"
            case "l":
                output += "255"
            case "t":
                output += "ef53"
            case "s", "S":
                output += "4096"
            case "b", "f", "a", "c", "d":
                output += "0"
            default:
                output.append("?")
            }
            index = format.index(after: next)
        }
        return output
    }

    private func statOutput(_ output: [String], formatMode: MSPStatFormatMode?) -> String {
        guard let formatMode else {
            return output.joined(separator: "\n\n")
        }
        if formatMode.appendsNewline {
            return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
        }
        return output.joined()
    }

    private func stableIdentifier(for path: String) -> UInt64 {
        path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func fileModeHex(for info: MSPFileInfo) -> String {
        let typeBits: UInt16
        switch info.type {
        case .directory:
            typeBits = 0o040000
        case .symbolicLink:
            typeBits = 0o120000
        case .regularFile, .other:
            typeBits = 0o100000
        }
        return String(format: "%x", typeBits | MSPPOSIXCommandSupport.mode(for: info))
    }

    private func defaultStatTimestamp(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let nanosecond = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
            .nanosecond ?? 0
        return "\(formatter.string(from: date)).\(String(format: "%09d", nanosecond)) +0000"
    }

    private func statPath(
        _ operand: String,
        dereference: Bool,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> String {
        if dereference {
            return try MSPPOSIXCommandSupport.canonicalVirtualPath(
                operand,
                command: name,
                mode: .existingOnly,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory
            )
        }
        return try fileSystem.resolve(operand, from: currentDirectory).virtualPath
    }
}

private struct MSPStatFormatMode {
    var format: String
    var interpretsEscapes: Bool
    var appendsNewline: Bool
}

private func mspStatUsage() -> String {
    """
    Usage: stat [OPTION]... FILE...
    Display virtual workspace file or file-system status.

    """
}

private func mspStatPadLeft(_ value: String, width: Int) -> String {
    String(repeating: " ", count: max(0, width - value.count)) + value
}
