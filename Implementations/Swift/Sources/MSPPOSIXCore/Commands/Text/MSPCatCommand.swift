import Foundation
import MSPCore

public struct MSPCatCommand: MSPStreamingCommand {
    public let name = "cat"
    public let summary: String? = "Concatenate workspace files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["A", "e", "E", "b", "n", "s", "t", "T", "v", "u"],
            allowedLongOptions: [
                "show-all",
                "show-ends",
                "number-nonblank",
                "number",
                "squeeze-blank",
                "show-tabs",
                "show-nonprinting",
                "help",
                "version"
            ]
        )
        let parsed = try spec.parse(invocation.arguments)
        if let standardOption = standardOptionResult(from: parsed.options) {
            return standardOption
        }
        let options = renderOptions(from: parsed.options)
        let operands = parsed.operands.isEmpty ? ["-"] : parsed.operands
        var fileSystem: (any MSPWorkspaceFileSystem)?

        var stdoutData = Data()
        var diagnostics: [String] = []
        var standardInputConsumed = false
        var renderState = CatRenderState()
        for path in operands {
            do {
                let data: Data
                if path == "-" {
                    if standardInputConsumed {
                        data = Data()
                    } else {
                        standardInputConsumed = true
                        data = try MSPPOSIXCommandSupport.standardInputData(from: context)
                    }
                } else {
                    if fileSystem == nil {
                        fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                    }
                    data = try readCatFile(path, from: context.currentDirectory, fileSystem: fileSystem!)
                }
                if options.requiresTextRendering {
                    stdoutData.append(renderCatOutput(data, options: options, state: &renderState))
                } else {
                    stdoutData.append(data)
                }
            } catch {
                let displayPath = path == "-"
                    ? "stdin"
                    : MSPPOSIXCommandSupport.displayPath(path)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("cat: \(displayPath): \(reason)")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stdoutData: stdoutData, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdoutData: stdoutData)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["A", "e", "E", "b", "n", "s", "t", "T", "v", "u"],
            allowedLongOptions: [
                "show-all",
                "show-ends",
                "number-nonblank",
                "number",
                "squeeze-blank",
                "show-tabs",
                "show-nonprinting",
                "help",
                "version"
            ]
        )
        let parsed = try spec.parse(invocation.arguments)
        if let standardOption = standardOptionResult(from: parsed.options) {
            return standardOption
        }
        let options = renderOptions(from: parsed.options)
        guard !options.requiresTextRendering,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        let operands = parsed.operands.isEmpty ? ["-"] : parsed.operands
        var fileSystem: (any MSPWorkspaceFileSystem)?
        var standardInputConsumed = false
        var diagnostics: [String] = []
        do {
            for path in operands {
                do {
                    if path == "-" {
                        if standardInputConsumed {
                            continue
                        }
                        standardInputConsumed = true
                        if let standardInput = context.standardInputStream {
                            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                                try await standardOutput.write(chunk)
                            }
                        } else if !context.standardInput.isEmpty {
                            try await standardOutput.write(context.standardInput)
                        }
                    } else {
                        if fileSystem == nil {
                            fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                        }
                        try await streamCatFile(
                            path,
                            from: context.currentDirectory,
                            fileSystem: fileSystem!,
                            standardOutput: standardOutput
                        )
                    }
                } catch let streamError as MSPCommandStreamError {
                    throw streamError
                } catch {
                    let displayPath = MSPPOSIXCommandSupport.displayPath(path)
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    diagnostics.append("cat: \(displayPath): \(reason)")
                }
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        guard diagnostics.isEmpty else {
            return .failure(stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success()
    }

    private func renderOptions(from parsedOptions: [MSPPOSIXOption]) -> CatRenderOptions {
        var numberAllLines = false
        var numberNonblankLines = false
        var showEnds = false
        var squeezeBlank = false
        var showTabs = false
        var showNonprinting = false

        for option in parsedOptions {
            switch option.name {
            case .short("A"), .long("show-all"):
                showEnds = true
                showTabs = true
                showNonprinting = true
            case .short("e"):
                showEnds = true
                showNonprinting = true
            case .short("E"), .long("show-ends"):
                showEnds = true
            case .short("b"), .long("number-nonblank"):
                numberNonblankLines = true
                numberAllLines = false
            case .short("n"), .long("number"):
                if !numberNonblankLines {
                    numberAllLines = true
                }
            case .short("s"), .long("squeeze-blank"):
                squeezeBlank = true
            case .short("t"):
                showTabs = true
                showNonprinting = true
            case .short("T"), .long("show-tabs"):
                showTabs = true
            case .short("v"), .long("show-nonprinting"):
                showNonprinting = true
            case .short("u"):
                continue
            default:
                continue
            }
        }

        return CatRenderOptions(
            numberAllLines: numberAllLines,
            numberNonblankLines: numberNonblankLines,
            showEnds: showEnds,
            squeezeBlank: squeezeBlank,
            showTabs: showTabs,
            showNonprinting: showNonprinting
        )
    }

    private func standardOptionResult(from options: [MSPPOSIXOption]) -> MSPCommandResult? {
        if options.contains(where: { $0.matches(long: "help") }) {
            return .success(stdout: Self.helpText)
        }
        if options.contains(where: { $0.matches(long: "version") }) {
            return .success(stdout: Self.versionText)
        }
        return nil
    }

    private static let helpText = """
    Usage: cat [OPTION]... [FILE]...
    Concatenate FILE(s) to standard output.

    With no FILE, or when FILE is -, read standard input.

      -A, --show-all           equivalent to -vET
      -b, --number-nonblank    number nonempty output lines, overrides -n
      -e                       equivalent to -vE
      -E, --show-ends          display $ at end of each line
      -n, --number             number all output lines
      -s, --squeeze-blank      suppress repeated empty output lines
      -t                       equivalent to -vT
      -T, --show-tabs          display TAB characters as ^I
      -u                       (ignored)
      -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
          --help        display this help and exit
          --version     output version information and exit

    GNU coreutils online help: <https://www.gnu.org/software/coreutils/>
    Full documentation <https://www.gnu.org/software/coreutils/cat>
    or available locally via: info '(coreutils) cat invocation'
    """

    private static let versionText = """
    cat (GNU coreutils) 9.1
    Copyright (C) 2022 Free Software Foundation, Inc.
    License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.

    Written by Torbjorn Granlund and Richard M. Stallman.
    """
}

private func readCatFile(
    _ path: String,
    from currentDirectory: String,
    fileSystem: any MSPWorkspaceFileSystem
) throws -> Data {
    let info = try fileSystem.stat(path, from: currentDirectory)
    guard let size = info.size else {
        return try fileSystem.readFile(path, from: currentDirectory)
    }
    guard size > 0 else {
        return Data()
    }
    var output = Data()
    let chunkSize = 32 * 1024
    var offset: UInt64 = 0
    let total = UInt64(size)
    while offset < total {
        let requested = min(chunkSize, Int(total - offset))
        let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: requested)
        guard !chunk.isEmpty else {
            break
        }
        output.append(chunk)
        offset += UInt64(chunk.count)
    }
    return output
}

private func streamCatFile(
    _ path: String,
    from currentDirectory: String,
    fileSystem: any MSPWorkspaceFileSystem,
    standardOutput: any MSPCommandOutputStream
) async throws {
    let info = try fileSystem.stat(path, from: currentDirectory)
    guard let size = info.size else {
        let data = try fileSystem.readFile(path, from: currentDirectory)
        if !data.isEmpty {
            try await standardOutput.write(data)
        }
        return
    }
    guard size > 0 else {
        return
    }
    let chunkSize = 32 * 1024
    var offset: UInt64 = 0
    let total = UInt64(size)
    while offset < total {
        let requested = min(chunkSize, Int(total - offset))
        let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: requested)
        guard !chunk.isEmpty else {
            break
        }
        try await standardOutput.write(chunk)
        offset += UInt64(chunk.count)
    }
}

private struct CatRenderState {
    var lineNumber = 1
    var previousBlank = false
}

private struct CatRenderOptions {
    var numberAllLines: Bool
    var numberNonblankLines: Bool
    var showEnds: Bool
    var squeezeBlank: Bool
    var showTabs: Bool
    var showNonprinting: Bool

    var requiresTextRendering: Bool {
        numberAllLines || numberNonblankLines || showEnds || squeezeBlank || showTabs || showNonprinting
    }
}

private func renderCatOutput(_ data: Data, options: CatRenderOptions, state: inout CatRenderState) -> Data {
    let shouldNumber = options.numberAllLines || options.numberNonblankLines
    guard options.squeezeBlank || shouldNumber else {
        return visibleCatOutput(
            data,
            showEnds: options.showEnds,
            showTabs: options.showTabs,
            showNonprinting: options.showNonprinting
        )
    }

    var output = Data()
    for record in catLineRecords(from: data) {
        let isBlank = record.bytes.isEmpty
        if options.squeezeBlank, isBlank, state.previousBlank {
            continue
        }
        state.previousBlank = isBlank

        let shouldNumberLine = options.numberAllLines || (options.numberNonblankLines && !isBlank)
        if shouldNumberLine {
            output.append(contentsOf: String(format: "%6d\t", state.lineNumber).utf8)
            state.lineNumber += 1
        }
        output.append(contentsOf: visibleCatOutput(
            record.bytes,
            showEnds: false,
            showTabs: options.showTabs,
            showNonprinting: options.showNonprinting
        ))
        if record.terminated {
            if options.showEnds {
                output.append(0x24)
            }
            output.append(0x0A)
        }
    }
    return output
}

private func catLineRecords(from data: Data) -> [(bytes: [UInt8], terminated: Bool)] {
    guard !data.isEmpty else { return [] }
    let bytes = [UInt8](data)
    var records: [(bytes: [UInt8], terminated: Bool)] = []
    var start = 0
    var index = 0
    while index < bytes.count {
        if bytes[index] == 0x0A {
            records.append((Array(bytes[start..<index]), true))
            index += 1
            start = index
            continue
        }
        index += 1
    }
    if start < bytes.count {
        records.append((Array(bytes[start..<bytes.count]), false))
    }
    return records
}

private func visibleCatOutput(
    _ data: Data,
    showEnds: Bool,
    showTabs: Bool,
    showNonprinting: Bool
) -> Data {
    visibleCatOutput([UInt8](data), showEnds: showEnds, showTabs: showTabs, showNonprinting: showNonprinting)
}

private func visibleCatOutput(
    _ bytes: [UInt8],
    showEnds: Bool,
    showTabs: Bool,
    showNonprinting: Bool
) -> Data {
    var output = Data()
    for byte in bytes {
        switch byte {
        case 0x0A:
            if showEnds {
                output.append(0x24)
            }
            output.append(0x0A)
        case 0x09:
            if showTabs {
                output.append(contentsOf: "^I".utf8)
            } else {
                output.append(byte)
            }
        default:
            if showNonprinting {
                output.append(contentsOf: catVisibleByte(byte).utf8)
            } else {
                output.append(byte)
            }
        }
    }
    return output
}

private func catVisibleByte(_ byte: UInt8) -> String {
    if byte < 0x20 {
        return "^" + String(UnicodeScalar(byte + 0x40))
    }
    if byte == 0x7F {
        return "^?"
    }
    if byte >= 0x80 {
        return "M-" + catVisibleByte(byte - 0x80)
    }
    return String(UnicodeScalar(byte))
}
