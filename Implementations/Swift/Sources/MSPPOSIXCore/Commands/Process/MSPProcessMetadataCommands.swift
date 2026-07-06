import Foundation
import MSPCore

public struct MSPPsCommand: MSPCommand {
    public let name = "ps"
    public let summary: String? = "Report the controlled shell process view."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = mspPsParse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        if parsed.version {
            return .success(stdout: "ps from procps-ng 4.0.2\n")
        }
        if parsed.help {
            return .success(stdout: mspPsHelp(category: parsed.helpCategory))
        }

        let commandNames = context.availableCommandNames.joined(separator: ",")
        if !parsed.formats.isEmpty {
            return .success(stdout: customOutput(
                parsed.formats.joined(separator: ","),
                noHeader: parsed.noHeader,
                pidFilter: parsed.pidFilter,
                ppidFilter: parsed.ppidFilter
            ))
        }
        if parsed.bsdAux {
            return .success(stdout: """
            USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
            msp            1  0.0  0.0      0     0 ?        S    00:00   0:00 msp-shell \(commandNames)

            """)
        }
        if parsed.fullListing {
            return .success(stdout: """
            UID          PID    PPID  C STIME TTY          TIME CMD
            msp            1       0  0 00:00 ?        00:00:00 msp-shell

            """)
        }
        return .success(stdout: """
              PID TTY          TIME CMD
                1 ?        00:00:00 msp-shell

            """)
    }

    private func customOutput(_ format: String, noHeader: Bool, pidFilter: Set<Int>, ppidFilter: Set<Int>) -> String {
        let columns = mspPsColumns(format)
        guard !columns.isEmpty else {
            return ""
        }
        let headers = columns.map(\.header)
        let hasHeader = !noHeader && headers.contains { !$0.isEmpty }
        let rowPID = 12_345
        let rowPPID = 0
        guard (pidFilter.isEmpty || pidFilter.contains(rowPID) || pidFilter.contains(1)),
              (ppidFilter.isEmpty || ppidFilter.contains(rowPPID)) else {
            return hasHeader ? zip(columns, headers).map { column, header in
                mspPsFormatHeader(header, column: column)
            }.joined(separator: " ") + "\n" : ""
        }
        let commandName = columns.count == 1 && columns[0].name == "comm" && columns[0].header.isEmpty
            ? "ps"
            : "bash"
        let values = columns.map { column -> String in
            switch column.name {
            case "pid": return "PID"
            case "ppid": return "0"
            case "comm", "cmd", "args": return commandName
            case "user", "uid": return "msp"
            default: return "-"
            }
        }
        let valueLine = zip(columns, values).map { column, value in
            mspPsFormatValue(value, column: column)
        }.joined(separator: " ")
        if !hasHeader {
            return valueLine + "\n"
        }
        let headerLine = zip(columns, headers).map { column, header in
            mspPsFormatHeader(header, column: column)
        }.joined(separator: " ")
        return headerLine + "\n" + valueLine + "\n"
    }
}

private struct MSPPsOptions {
    var formats: [String] = []
    var noHeader = false
    var bsdAux = false
    var fullListing = false
    var version = false
    var help = false
    var helpCategory: String?
    var pidFilter: Set<Int> = []
    var ppidFilter: Set<Int> = []
    var result: MSPCommandResult?
}

private func mspPsParse(_ arguments: [String]) -> MSPPsOptions {
    var parsed = MSPPsOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--version":
            parsed.version = true
        case "--help":
            parsed.help = true
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                parsed.helpCategory = arguments[index + 1]
                index += 1
            }
        case "--no-headers", "--no-header", "--noheading", "--noheadings", "--no-heading", "--no-headings":
            parsed.noHeader = true
        case "--headers", "--header", "--heading", "--headings":
            parsed.noHeader = false
        case "--format":
            guard index + 1 < arguments.count else {
                parsed.result = .failure(exitCode: 1, stderr: mspPsUnknownLongOptionDiagnostic())
                return parsed
            }
            parsed.formats.append(arguments[index + 1])
            index += 1
        case "--pid", "--quick-pid":
            if index + 1 < arguments.count {
                parsed.pidFilter.formUnion(mspPsParsePIDList(arguments[index + 1]))
                index += 1
            }
        case "--ppid":
            if index + 1 < arguments.count {
                parsed.ppidFilter.formUnion(mspPsParsePIDList(arguments[index + 1]))
                index += 1
            }
        case "aux", "ax":
            parsed.bsdAux = true
        case "-e", "-A", "-ef", "-f":
            parsed.fullListing = true
        case "-o":
            if index + 1 < arguments.count {
                parsed.formats.append(arguments[index + 1])
                index += 1
            }
        case "-p", "-q":
            if index + 1 < arguments.count {
                parsed.pidFilter.formUnion(mspPsParsePIDList(arguments[index + 1]))
                index += 1
            }
        default:
            if argument.hasPrefix("--format=") {
                parsed.formats.append(String(argument.dropFirst("--format=".count)))
            } else if argument.hasPrefix("--pid=") {
                parsed.pidFilter.formUnion(mspPsParsePIDList(String(argument.dropFirst("--pid=".count))))
            } else if argument.hasPrefix("--ppid=") {
                parsed.ppidFilter.formUnion(mspPsParsePIDList(String(argument.dropFirst("--ppid=".count))))
            } else if argument.hasPrefix("-o"), argument.count > 2 {
                parsed.formats.append(String(argument.dropFirst(2)))
            } else if argument.hasPrefix("-p"), argument.count > 2 {
                parsed.pidFilter.formUnion(mspPsParsePIDList(String(argument.dropFirst(2))))
            } else if argument.hasPrefix("--") {
                parsed.result = .failure(exitCode: 1, stderr: mspPsUnknownLongOptionDiagnostic())
                return parsed
            }
        }
        index += 1
    }
    return parsed
}

private func mspPsParsePIDList(_ raw: String) -> Set<Int> {
    Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
}

private struct MSPPsColumn {
    var name: String
    var header: String
    var width: Int
    var rightAligned: Bool
}

private func mspPsColumns(_ format: String) -> [MSPPsColumn] {
    format
        .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" })
        .compactMap { rawField -> MSPPsColumn? in
            let parts = rawField.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !name.isEmpty else {
                return nil
            }
            let defaultHeader: String
            let width: Int
            let rightAligned: Bool
            switch name {
            case "pid":
                defaultHeader = "PID"
                width = 7
                rightAligned = true
            case "ppid":
                defaultHeader = "PPID"
                width = 7
                rightAligned = true
            case "comm":
                defaultHeader = "COMMAND"
                width = 7
                rightAligned = false
            case "cmd", "args":
                defaultHeader = name == "cmd" ? "CMD" : "COMMAND"
                width = defaultHeader.count
                rightAligned = false
            case "user", "uid":
                defaultHeader = name.uppercased()
                width = defaultHeader.count
                rightAligned = false
            default:
                defaultHeader = name.uppercased()
                width = defaultHeader.count
                rightAligned = false
            }
            let header = parts.count == 2 ? String(parts[1]) : defaultHeader
            return MSPPsColumn(name: name, header: header, width: max(width, header.count), rightAligned: rightAligned)
        }
}

private func mspPsFormatHeader(_ header: String, column: MSPPsColumn) -> String {
    guard !header.isEmpty else {
        return ""
    }
    if column.rightAligned {
        return mspPsRightAlign(header, width: column.width)
    }
    return header
}

private func mspPsFormatValue(_ value: String, column: MSPPsColumn) -> String {
    let rendered = column.name == "pid" && value == "PID" ? "12345" : value
    if column.rightAligned {
        return mspPsRightAlign(rendered, width: column.width)
    }
    return rendered
}

private func mspPsRightAlign(_ value: String, width: Int) -> String {
    let padding = max(0, width - value.count)
    return String(repeating: " ", count: padding) + value
}

private func mspPsUnknownLongOptionDiagnostic() -> String {
    """
    error: unknown gnu long option

    Usage:
     ps [options]

     Try 'ps --help <simple|list|output|threads|misc|all>'
      or 'ps --help <s|l|o|t|m|a>'
     for additional help text.

    For more details see ps(1).
    """
    + "\n"
}

private func mspPsHelp(category: String?) -> String {
    if let category, !category.isEmpty {
        return "Usage: ps [options]\n\nHelp category: \(category)\n"
    }
    return "Usage: ps [options]\n"
}

public struct MSPLddCommand: MSPCommand {
    public let name = "ldd"
    public let summary: String? = "Print shared object dependencies for supported files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = mspLddParse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        if parsed.help {
            return .success(stdout: mspLddUsage())
        }
        if parsed.version {
            return .success(stdout: "ldd (Debian GLIBC 2.36-9+deb12u14) 2.36\n")
        }
        guard !parsed.files.isEmpty else {
            return .failure(
                exitCode: 1,
                stderr: "ldd: missing file arguments\nTry `ldd --help' for more information.\n"
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var stderr = ""
        var exitCode: Int32 = 0
        for path in parsed.files {
            do {
                let info = try fileSystem.stat(path, from: context.currentDirectory)
                if info.type == .directory {
                    stderr += "ldd: \(lddDiagnosticPath(path)): not regular file\n"
                } else {
                    stderr += "\tnot a dynamic executable\n"
                }
                exitCode = 1
            } catch {
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                stderr += "ldd: \(lddDiagnosticPath(path)): \(reason)\n"
                exitCode = 1
            }
        }
        return MSPCommandResult(stderr: stderr, exitCode: exitCode)
    }
}

private struct MSPLddOptions {
    var help = false
    var version = false
    var files: [String] = []
    var result: MSPCommandResult?
}

private func mspLddParse(_ arguments: [String]) -> MSPLddOptions {
    var parsed = MSPLddOptions()
    var parsingOptions = true
    for argument in arguments {
        if parsingOptions, argument == "--" {
            parsingOptions = false
            continue
        }
        if parsingOptions {
            switch argument {
            case "--vers", "--versi", "--versio", "--version":
                parsed.version = true
                continue
            case "--help", "--h", "--he", "--hel":
                parsed.help = true
                continue
            case "-d", "--data-rel", "--data-relo", "--data-reloc", "--data-relocs",
                 "-r", "--function-relo", "--function-reloc", "--function-relocs",
                 "-u", "--u", "--un", "--unu", "--unus", "--unuse", "--unused",
                 "-v", "--verb", "--verbo", "--verbos", "--verbose":
                continue
            case "--v", "--ve", "--ver":
                parsed.result = .failure(exitCode: 1, stderr: "ldd: option '\(argument)' is ambiguous\n")
                return parsed
            default:
                if argument.hasPrefix("-"), argument != "-" {
                    parsed.result = .failure(exitCode: 1, stderr: "ldd: unrecognized option '\(argument)'\nTry `ldd --help' for more information.\n")
                    return parsed
                }
            }
        }
        parsed.files.append(argument)
    }
    return parsed
}

private func lddDiagnosticPath(_ path: String) -> String {
    let displayPath = MSPPOSIXCommandSupport.displayPath(path)
    if displayPath.hasPrefix("/") || displayPath.hasPrefix("./") || displayPath.hasPrefix("../") {
        return displayPath
    }
    return "./" + displayPath
}

private func mspLddUsage() -> String {
    """
    Usage: ldd [OPTION]... FILE...
          --help              print this help and exit
          --version           print version information and exit
      -d, --data-relocs       process data relocations
      -r, --function-relocs   process data and function relocations
      -u, --unused            print unused direct dependencies
      -v, --verbose           print all information

    """
}
