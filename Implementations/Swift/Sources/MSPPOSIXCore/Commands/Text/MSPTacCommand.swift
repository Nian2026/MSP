import Foundation
import MSPCore

public struct MSPTacCommand: MSPCommand {
    public var name: String { "tac" }
    public var summary: String? { "Concatenate files and print records in reverse." }

    private let spec = MSPPOSIXCommandSpec(
        name: "tac",
        allowedShortOptions: ["b", "r"],
        allowedLongOptions: ["before", "regex"],
        shortOptionsRequiringValue: ["s"],
        longOptionsRequiringValue: ["separator"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: Self.versionText
        ) {
            return standardOption
        }
        let parsed = try spec.parse(invocation.arguments)
        var separator = Data("\n".utf8)
        var separatorPattern = "\n"
        var separatorEndsRecord = true
        var regexSeparator = false
        for option in parsed.options {
            switch option.name {
            case .short("b"), .long("before"):
                separatorEndsRecord = false
            case .short("r"), .long("regex"):
                regexSeparator = true
            case .short("s"), .long("separator"):
                let value = option.value ?? ""
                separatorPattern = value
                separator = value.isEmpty ? Data([0]) : Data(value.utf8)
            default:
                continue
            }
        }
        if regexSeparator, separatorPattern.isEmpty {
            return .failure(stderr: "tac: separator cannot be empty\n")
        }
        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: parsed.operands,
            context: context,
            command: name,
            fileReadDiagnostic: { path, reason in
                "tac: failed to open '\(path)' for reading: \(reason)"
            }
        )
        let outputData = input.inputs.reduce(into: Data()) { output, input in
            let records = regexSeparator
                ? tacRegexRecords(
                    in: input.data,
                    separatorPattern: separatorPattern,
                    separatorEndsRecord: separatorEndsRecord
                )
                : tacRecords(
                    in: input.data,
                    separator: separator,
                    separatorEndsRecord: separatorEndsRecord
                )
            for record in records.reversed() {
                output.append(record)
            }
        }
        return MSPCommandResult(
            stdoutData: outputData,
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    private static let helpText = """
    Usage: tac [OPTION]... [FILE]...
    Write each FILE to standard output, last line first.

    With no FILE, or when FILE is -, read standard input.

      -b, --before             attach the separator before instead of after
      -r, --regex              interpret the separator as a regular expression
      -s, --separator=STRING   use STRING as the separator instead of newline
          --help        display this help and exit
          --version     output version information and exit

    GNU coreutils online help: <https://www.gnu.org/software/coreutils/>
    Report any translation bugs to <https://translationproject.org/team/>
    Full documentation <https://www.gnu.org/software/coreutils/tac>
    or available locally via: info '(coreutils) tac invocation'
    """

    private static let versionText = """
    tac (GNU coreutils) 9.1
    Copyright (C) 2022 Free Software Foundation, Inc.
    License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.

    Written by Jay Lepreau and David MacKenzie.
    """
}

private func tacRecords(in data: Data, separator: Data, separatorEndsRecord: Bool) -> [Data] {
    guard !data.isEmpty else {
        return []
    }
    var records: [Data] = []
    var start = data.startIndex
    var searchStart = data.startIndex
    while searchStart < data.endIndex,
          let range = data.range(of: separator, options: [], in: searchStart..<data.endIndex) {
        let end = separatorEndsRecord ? range.upperBound : range.lowerBound
        records.append(data.subdata(in: start..<end))
        start = separatorEndsRecord ? range.upperBound : range.lowerBound
        if !separatorEndsRecord {
            searchStart = range.upperBound
            start = range.lowerBound
        } else {
            searchStart = range.upperBound
        }
    }
    if start < data.endIndex {
        records.append(data.subdata(in: start..<data.endIndex))
    }
    return records
}

private func tacRegexRecords(
    in data: Data,
    separatorPattern: String,
    separatorEndsRecord: Bool
) -> [Data] {
    guard !data.isEmpty else {
        return []
    }
    let text = String(decoding: data, as: UTF8.self)
    guard let regex = try? NSRegularExpression(pattern: separatorPattern),
          let textData = text.data(using: .utf8),
          textData == data else {
        return [data]
    }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    guard !matches.isEmpty else {
        return [data]
    }

    var records: [Data] = []
    var startOffset = 0
    for match in matches where match.range.length > 0 {
        guard let range = Range(match.range, in: text) else {
            continue
        }
        let lower = text[..<range.lowerBound].utf8.count
        let upper = text[..<range.upperBound].utf8.count
        let endOffset = separatorEndsRecord ? upper : lower
        records.append(data.subdata(in: startOffset..<endOffset))
        startOffset = separatorEndsRecord ? upper : lower
    }
    if startOffset < data.count {
        records.append(data.subdata(in: startOffset..<data.count))
    }
    return records
}
