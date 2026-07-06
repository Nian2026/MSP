import Foundation
import MSPCore

public struct MSPNlCommand: MSPStreamingCommand {
    public let name = "nl"
    public let summary: String? = "Number lines of files."

    private let spec = MSPPOSIXCommandSpec(
        name: "nl",
        allowedShortOptions: ["p"],
        allowedLongOptions: ["no-renumber"],
        shortOptionsRequiringValue: ["b", "d", "f", "h", "i", "l", "n", "w", "s", "v"],
        longOptionsRequiringValue: [
            "body-numbering",
            "footer-numbering",
            "header-numbering",
            "line-increment",
            "join-blank-lines",
            "number-format",
            "number-width",
            "number-separator",
            "section-delimiter",
            "starting-line-number"
        ]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let parsed = try spec.parse(invocation.arguments)
        let configuration = try parseConfiguration(parsed)
        var state = MSPNlState(configuration: configuration)

        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: parsed.operands,
            context: context,
            command: name
        )
        var output = Data()
        for input in input.inputs {
            for line in mspNlLineRecords(in: input.data) {
                try appendProcessedLine(line, state: &state, to: &output)
            }
        }
        return MSPCommandResult(
            stdoutData: output,
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let parsed = try spec.parse(invocation.arguments)
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }

        let configuration = try parseConfiguration(parsed)
        var state = MSPNlState(configuration: configuration)
        let operands = parsed.operands.isEmpty ? ["-"] : parsed.operands
        var standardInputConsumed = false
        var fileSystem: (any MSPWorkspaceFileSystem)?
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        for operand in operands {
            do {
                let stream: any MSPCommandInputStream
                if operand == "-" {
                    if standardInputConsumed {
                        stream = MSPDataInputStream(Data())
                    } else {
                        standardInputConsumed = true
                        if let standardInput = context.standardInputStream {
                            stream = standardInput
                        } else {
                            stream = MSPDataInputStream(try MSPPOSIXCommandSupport.standardInputData(from: context))
                        }
                    }
                } else {
                    if fileSystem == nil {
                        fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                    }
                    stream = MSPWorkspaceFileInputStream(
                        fileSystem: fileSystem!,
                        path: operand,
                        currentDirectory: context.currentDirectory
                    )
                }

                try await writeNumberedLines(
                    from: stream,
                    to: standardOutput,
                    state: &state
                )
            } catch MSPCommandStreamError.brokenPipe {
                return .success()
            } catch {
                let displayPath = operand == "-"
                    ? "stdin"
                    : MSPPOSIXCommandSupport.displayPath(operand)
                diagnostics.append("nl: \(displayPath): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                exitCode = 1
            }
        }

        return MSPCommandResult(
            stderr: diagnostics.isEmpty ? "" : diagnostics.joined(separator: "\n") + "\n",
            exitCode: exitCode
        )
    }

    private func parseConfiguration(_ parsed: MSPPOSIXParsedArguments) throws -> MSPNlConfiguration {
        var configuration = MSPNlConfiguration()

        if let value = parsed.options.lastValue(short: "h", long: "header-numbering") {
            configuration.headerStyle = try MSPNlNumberingStyle(value, sectionName: "header")
        }
        if let value = parsed.options.lastValue(short: "b", long: "body-numbering") {
            configuration.bodyStyle = try MSPNlNumberingStyle(value, sectionName: "body")
        }
        if let value = parsed.options.lastValue(short: "f", long: "footer-numbering") {
            configuration.footerStyle = try MSPNlNumberingStyle(value, sectionName: "footer")
        }
        if let value = parsed.options.lastValue(short: "d", long: "section-delimiter") {
            configuration.sectionDelimiter = MSPNlSectionDelimiter(rawValue: value)
        }
        if let value = parsed.options.lastValue(short: "i", long: "line-increment") {
            configuration.increment = try integerOption(value, diagnosticName: "line number increment")
        }
        if let value = parsed.options.lastValue(short: "l", long: "join-blank-lines") {
            configuration.joinBlankLines = try positiveIntegerOption(
                value,
                diagnosticName: "line number of blank lines"
            )
        }
        if let value = parsed.options.lastValue(short: "n", long: "number-format") {
            configuration.numberFormat = try MSPNlNumberFormat(value)
        }
        if parsed.options.contains(where: { $0.matches(short: "p", long: "no-renumber") }) {
            configuration.renumberOnSection = false
        }
        if let value = parsed.options.lastValue(short: "w", long: "number-width") {
            configuration.width = try positiveIntegerOption(value, diagnosticName: "line number field width")
        }
        if let value = parsed.options.lastValue(short: "s", long: "number-separator") {
            configuration.separator = value
        }
        if let value = parsed.options.lastValue(short: "v", long: "starting-line-number") {
            configuration.startingLineNumber = try integerOption(value, diagnosticName: "starting line number")
        }

        return configuration
    }

    private func writeNumberedLines(
        from stream: any MSPCommandInputStream,
        to standardOutput: any MSPCommandOutputStream,
        state: inout MSPNlState
    ) async throws {
        let reader = MSPNlLineStreamReader(stream: stream)
        while let line = try await reader.readLine() {
            var output = Data()
            try appendProcessedLine(line, state: &state, to: &output)
            try await standardOutput.write(output)
        }
    }

    private func integerOption(_ value: String, diagnosticName: String) throws -> Int {
        guard let parsed = Int(value) else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "nl: invalid \(diagnosticName): \(mspNlGNUQuoted(value))\n"
            ))
        }
        return parsed
    }

    private func positiveIntegerOption(_ value: String, diagnosticName: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            let reason = Int(value) == nil ? "" : ": Numerical result out of range"
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "nl: invalid \(diagnosticName): \(mspNlGNUQuoted(value))\(reason)\n"
            ))
        }
        return parsed
    }

    private static let helpText = """
    Usage: nl [OPTION]... [FILE]...
    Write each FILE to standard output, with line numbers added.

      -b, --body-numbering=STYLE      use STYLE for numbering body lines
      -d, --section-delimiter=CC      use CC for logical page delimiters
      -f, --footer-numbering=STYLE    use STYLE for numbering footer lines
      -h, --header-numbering=STYLE    use STYLE for numbering header lines
      -i, --line-increment=NUMBER     line number increment at each line
      -l, --join-blank-lines=NUMBER   group NUMBER empty lines as one
      -n, --number-format=FORMAT      insert line numbers according to FORMAT
      -p, --no-renumber               do not reset line numbers at pages
      -s, --number-separator=STRING   add STRING after possible line number
      -v, --starting-line-number=NUMBER  first line number on each page
      -w, --number-width=NUMBER       use NUMBER columns for line numbers
          --help                      display this help and exit
          --version                   output version information and exit
    """
}

private struct MSPNlLine {
    var text: String
    var terminated: Bool
}

private func mspNlLineRecords(in data: Data) -> [MSPNlLine] {
    guard !data.isEmpty else {
        return []
    }
    var lines: [MSPNlLine] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0x0A {
        let lineData = data.subdata(in: start..<index)
        lines.append(MSPNlLine(text: String(decoding: lineData, as: UTF8.self), terminated: true))
        start = data.index(after: index)
    }
    if start < data.endIndex {
        let lineData = data.subdata(in: start..<data.endIndex)
        lines.append(MSPNlLine(text: String(decoding: lineData, as: UTF8.self), terminated: false))
    }
    return lines
}

private func appendProcessedLine(_ line: MSPNlLine, state: inout MSPNlState, to output: inout Data) throws {
    output.append(contentsOf: try state.process(line.text).utf8)
    if line.terminated {
        output.append(0x0A)
    }
}

private final class MSPNlLineStreamReader {
    private let stream: any MSPCommandInputStream
    private var buffer = Data()
    private var reachedEOF = false

    init(stream: any MSPCommandInputStream) {
        self.stream = stream
    }

    func readLine(maxBytes: Int = 32 * 1024) async throws -> MSPNlLine? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return MSPNlLine(text: String(decoding: lineData, as: UTF8.self), terminated: true)
            }

            if reachedEOF {
                guard !buffer.isEmpty else {
                    return nil
                }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: false)
                return MSPNlLine(text: String(decoding: lineData, as: UTF8.self), terminated: false)
            }

            if let chunk = try await stream.read(maxBytes: maxBytes) {
                buffer.append(chunk)
            } else {
                reachedEOF = true
            }
        }
    }
}

private struct MSPNlConfiguration {
    var headerStyle: MSPNlNumberingStyle = .none
    var bodyStyle: MSPNlNumberingStyle = .nonEmpty
    var footerStyle: MSPNlNumberingStyle = .none
    var sectionDelimiter = MSPNlSectionDelimiter(rawValue: "\\:")
    var numberFormat: MSPNlNumberFormat = .right
    var width = 6
    var separator = "\t"
    var startingLineNumber = 1
    var increment = 1
    var joinBlankLines = 1
    var renumberOnSection = true
}

private struct MSPNlState {
    let configuration: MSPNlConfiguration
    var currentSection: MSPNlSection = .body
    var lineNumber: Int
    var blankLineRun = 0

    init(configuration: MSPNlConfiguration) {
        self.configuration = configuration
        self.lineNumber = configuration.startingLineNumber
    }

    mutating func process(_ line: String) throws -> String {
        if let section = configuration.sectionDelimiter.section(for: line) {
            currentSection = section
            blankLineRun = 0
            if configuration.renumberOnSection {
                lineNumber = configuration.startingLineNumber
            }
            return ""
        }

        let style = configuration.style(for: currentSection)
        let shouldNumber: Bool
        switch style {
        case .all:
            if line.isEmpty, configuration.joinBlankLines > 1 {
                blankLineRun += 1
                shouldNumber = blankLineRun == configuration.joinBlankLines
                if shouldNumber {
                    blankLineRun = 0
                }
            } else {
                blankLineRun = 0
                shouldNumber = true
            }
        case .nonEmpty:
            blankLineRun = 0
            shouldNumber = !line.isEmpty
        case .none:
            blankLineRun = 0
            shouldNumber = false
        case .pattern(let regex):
            blankLineRun = 0
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            shouldNumber = regex.firstMatch(in: line, options: [], range: range) != nil
        }

        guard shouldNumber else {
            return String(repeating: " ", count: configuration.width + configuration.separator.count) + line
        }

        let number = configuration.numberFormat.formatted(lineNumber, width: configuration.width)
        lineNumber += configuration.increment
        return number + configuration.separator + line
    }
}

private extension MSPNlConfiguration {
    func style(for section: MSPNlSection) -> MSPNlNumberingStyle {
        switch section {
        case .header:
            return headerStyle
        case .body:
            return bodyStyle
        case .footer:
            return footerStyle
        }
    }
}

private enum MSPNlSection {
    case header
    case body
    case footer
}

private struct MSPNlSectionDelimiter {
    let delimiter: String

    init(rawValue: String) {
        switch rawValue.count {
        case 0:
            delimiter = ""
        case 1:
            delimiter = rawValue + ":"
        default:
            delimiter = rawValue
        }
    }

    func section(for line: String) -> MSPNlSection? {
        guard delimiter.count >= 2 else {
            return nil
        }
        if line == String(repeating: delimiter, count: 3) {
            return .header
        }
        if line == String(repeating: delimiter, count: 2) {
            return .body
        }
        if line == delimiter {
            return .footer
        }
        return nil
    }
}

private enum MSPNlNumberingStyle {
    case all
    case nonEmpty
    case none
    case pattern(NSRegularExpression)

    init(_ value: String?, sectionName: String) throws {
        switch value {
        case "a":
            self = .all
        case "t", nil:
            self = .nonEmpty
        case "n":
            self = .none
        case let raw? where raw.hasPrefix("p"):
            let pattern = String(raw.dropFirst())
            do {
                self = .pattern(try NSRegularExpression(pattern: pattern))
            } catch {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "nl: \(error.localizedDescription)\n"
                ))
            }
        default:
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "nl: invalid \(sectionName) numbering style: \(mspNlGNUQuoted(value ?? ""))\n"
            ))
        }
    }
}

private enum MSPNlNumberFormat {
    case left
    case right
    case rightZero

    init(_ value: String?) throws {
        switch value {
        case "ln":
            self = .left
        case "rn", nil:
            self = .right
        case "rz":
            self = .rightZero
        default:
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "nl: invalid line numbering format: \(mspNlGNUQuoted(value ?? ""))\n"
            ))
        }
    }

    func formatted(_ number: Int, width: Int) -> String {
        let text = String(number)
        let padding = max(0, width - text.count)
        switch self {
        case .left:
            return text + String(repeating: " ", count: padding)
        case .right:
            return String(repeating: " ", count: padding) + text
        case .rightZero:
            return String(repeating: "0", count: padding) + text
        }
    }
}

private func mspNlGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private extension Array where Element == MSPPOSIXOption {
    func lastValue(short: Character, long: String) -> String? {
        reversed().first { $0.matches(short: short) || $0.matches(long: long) }?.value
    }
}
