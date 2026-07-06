import Foundation
import MSPCore

struct MSPPOSIXChecksumCheckEntry {
    var expected: String
    var path: String
}

enum MSPPOSIXChecksumCheckParseResult {
    case ignored
    case invalid
    case entry(MSPPOSIXChecksumCheckEntry)
}

func mspPOSIXCheckDigests(
    _ operands: [String],
    options: MSPDigestOptions,
    algorithm: MSPDigestAlgorithm,
    context: MSPCommandContext,
    command: String
) async throws -> MSPCommandResult {
    let checkInput = try await MSPPOSIXCommandSupport.inputData(
        operands: operands,
        context: context,
        command: command
    )
    if checkInput.exitCode != 0 {
        return MSPCommandResult(
            stderr: checkInput.diagnostics.joined(separator: "\n") + "\n",
            exitCode: checkInput.exitCode
        )
    }

    var stdoutLines: [String] = []
    var stderrLines: [String] = []
    var improperlyFormatted = 0
    var mismatched = 0
    var readErrors = 0
    var sawValidLine = false
    var matchedChecksums = false

    for input in checkInput.inputs {
        let text = String(decoding: input.data, as: UTF8.self)
        let inputLabel = mspPOSIXChecksumInputLabel(input.label)
        for (lineNumber, line) in mspPOSIXChecksumLines(text).enumerated() {
            switch mspPOSIXChecksumCheckEntry(line, algorithm: algorithm) {
            case .ignored:
                continue
            case .invalid:
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    improperlyFormatted += 1
                    if options.warn {
                        stderrLines.append(
                            "\(command): \(inputLabel): \(lineNumber + 1): improperly formatted \(algorithm.tagLabel) checksum line"
                        )
                    }
                }
                continue
            case .entry(let entry):
                sawValidLine = true
                let actual: String
                do {
                    let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: command)
                    actual = try algorithm.digestHex(
                        fileSystem: fileSystem,
                        path: entry.path,
                        currentDirectory: context.currentDirectory
                    )
                } catch {
                    if options.ignoreMissing, mspPOSIXChecksumIsMissingFileError(error) {
                        continue
                    }
                    readErrors += 1
                    if !options.statusOnly {
                        stdoutLines.append("\(mspPOSIXEscapedChecksumDisplayPath(entry.path)): FAILED open or read")
                    }
                    stderrLines.append(
                        "\(command): \(entry.path): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                    )
                    continue
                }
                let ok = actual.lowercased() == entry.expected.lowercased()
                if ok {
                    matchedChecksums = true
                } else {
                    mismatched += 1
                }
                if !options.statusOnly {
                    if !ok || !options.quiet {
                        stdoutLines.append("\(mspPOSIXEscapedChecksumDisplayPath(entry.path)): \(ok ? "OK" : "FAILED")")
                    }
                }
            }
        }
    }

    if !sawValidLine {
        let label = mspPOSIXChecksumInputLabel(checkInput.inputs.first?.label)
        stderrLines.append("\(command): \(label): no properly formatted checksum lines found")
    } else if !options.statusOnly {
        if improperlyFormatted > 0 {
            let noun = improperlyFormatted == 1 ? "line is" : "lines are"
            stderrLines.append("\(command): WARNING: \(improperlyFormatted) \(noun) improperly formatted")
        }
        if readErrors > 0 {
            let noun = readErrors == 1 ? "listed file could not" : "listed files could not"
            stderrLines.append("\(command): WARNING: \(readErrors) \(noun) be read")
        }
        if mismatched > 0 {
            let noun = mismatched == 1 ? "computed checksum did" : "computed checksums did"
            stderrLines.append("\(command): WARNING: \(mismatched) \(noun) NOT match")
        }
        if options.ignoreMissing, !matchedChecksums {
            let label = mspPOSIXChecksumInputLabel(checkInput.inputs.first?.label)
            stderrLines.append("\(command): \(label): no file was verified")
        }
    }

    let stdout = stdoutLines.isEmpty ? "" : stdoutLines.joined(separator: "\n") + "\n"
    let stderr = stderrLines.isEmpty ? "" : stderrLines.joined(separator: "\n") + "\n"
    let exitCode: Int32 = (
        mismatched > 0
            || readErrors > 0
            || !sawValidLine
            || (options.strict && improperlyFormatted > 0)
            || (options.ignoreMissing && !matchedChecksums)
    ) ? 1 : 0
    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
}

private func mspPOSIXChecksumLines(_ text: String) -> [String] {
    guard !text.isEmpty else {
        return []
    }
    var lines = text.components(separatedBy: .newlines)
    if text.hasSuffix("\n") || text.hasSuffix("\r") {
        lines.removeLast()
    }
    return lines
}

private func mspPOSIXChecksumCheckEntry(
    _ rawLine: String,
    algorithm: MSPDigestAlgorithm
) -> MSPPOSIXChecksumCheckParseResult {
    var line = rawLine
    while line.last == "\n" || line.last == "\r" {
        line.removeLast()
    }
    if line.isEmpty || line.first == "#" {
        return .ignored
    }
    while let first = line.first, first == " " || first == "\t" {
        line.removeFirst()
    }
    var escapedFilename = false
    if line.first == "\\" {
        escapedFilename = true
        line.removeFirst()
    }

    if let tagged = mspPOSIXTaggedChecksumCheckEntry(
        line,
        algorithm: algorithm,
        escapedFilename: escapedFilename
    ) {
        return .entry(tagged)
    }

    guard line.count > algorithm.hexLength else {
        return .invalid
    }
    let checksumEnd = line.index(line.startIndex, offsetBy: algorithm.hexLength)
    let expected = String(line[..<checksumEnd])
    guard expected.allSatisfy(\.isHexDigit),
          line[checksumEnd].isWhitespace else {
        return .invalid
    }
    var rest = String(line[line.index(after: checksumEnd)...])
    if rest.hasPrefix("*") {
        rest.removeFirst()
    } else if rest.hasPrefix(" "), rest.count > 1 {
        rest.removeFirst()
    } else {
        return .invalid
    }
    guard !rest.isEmpty else {
        return .invalid
    }
    if escapedFilename {
        guard let unescaped = mspPOSIXChecksumUnescapedFilename(rest) else {
            return .invalid
        }
        rest = unescaped
    }
    return .entry(MSPPOSIXChecksumCheckEntry(expected: expected, path: rest))
}

private func mspPOSIXTaggedChecksumCheckEntry(
    _ line: String,
    algorithm: MSPDigestAlgorithm,
    escapedFilename: Bool
) -> MSPPOSIXChecksumCheckEntry? {
    let prefix = "\(algorithm.tagLabel) ("
    guard line.hasPrefix(prefix),
          let separatorRange = line.range(of: ") = ", range: prefix.endIndex..<line.endIndex) else {
        return nil
    }
    var path = String(line[prefix.endIndex..<separatorRange.lowerBound])
    let expected = String(line[separatorRange.upperBound...])
    guard expected.count == algorithm.hexLength,
          expected.allSatisfy({ $0.isHexDigit }) else {
        return nil
    }
    if escapedFilename {
        guard let unescaped = mspPOSIXChecksumUnescapedFilename(path) else {
            return nil
        }
        path = unescaped
    }
    return MSPPOSIXChecksumCheckEntry(expected: expected, path: path)
}

private func mspPOSIXChecksumUnescapedFilename(_ filename: String) -> String? {
    var output = ""
    var index = filename.startIndex
    while index < filename.endIndex {
        let character = filename[index]
        if character != "\\" {
            output.append(character)
            index = filename.index(after: index)
            continue
        }
        index = filename.index(after: index)
        guard index < filename.endIndex else {
            return nil
        }
        let escaped = filename[index]
        switch escaped {
        case "n":
            output.append("\n")
        case "r":
            output.append("\r")
        case "\\":
            output.append("\\")
        default:
            return nil
        }
        index = filename.index(after: index)
    }
    return output
}

func mspPOSIXEscapedChecksumDisplayPath(_ path: String) -> String {
    guard path.contains("\n") else {
        return path
    }
    return "\\" + mspPOSIXChecksumEscapedFilename(path)
}

private func mspPOSIXChecksumIsMissingFileError(_ error: Error) -> Bool {
    if case MSPWorkspaceFileSystemError.notFound = error {
        return true
    }
    return false
}

func mspPOSIXChecksumInputLabel(_ label: String?) -> String {
    guard let label, label != "-" else {
        return "'standard input'"
    }
    return label
}
