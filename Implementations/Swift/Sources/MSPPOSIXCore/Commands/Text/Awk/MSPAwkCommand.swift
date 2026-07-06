import Foundation
import MSPCore

public struct MSPAwkCommand: MSPStreamingCommand {
    public let name = "awk"
    public let summary: String? = "Pattern-scan and process text with awk programs."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var fieldSeparator: String?
        var initialVariables: [String: String] = [:]
        var programFiles: [String] = []
        let parsed = try MSPPOSIXOptionParser.parse(
            invocation.arguments,
            command: "awk",
            shortOptionsRequiringValue: ["F", "v", "f", "W"],
            longOptionsRequiringValue: ["file"]
        )
        for option in parsed.options {
            switch option.name {
            case .short("W"):
                if mspPOSIXAwkWOptionRequestsVersion(option.value ?? "") {
                    return awkVersionResult()
                }
                if mspPOSIXAwkWOptionRequestsHelp(option.value ?? "") {
                    return .success(stdout: mspAwkUsageText)
                }
                throw MSPPOSIXAwkError.usage("awk: unsupported option -- W \(option.value ?? "")")
            case .short("F"):
                fieldSeparator = mspPOSIXAwkDecodeBackslashEscapes(option.value ?? "")
            case .short("v"):
                let assignment = option.value ?? ""
                guard let parsedAssignment = mspPOSIXAwkAssignment(assignment) else {
                    throw MSPPOSIXAwkError.usage("awk: invalid variable assignment \(assignment)")
                }
                initialVariables[parsedAssignment.name] = mspPOSIXAwkDecodeBackslashEscapes(parsedAssignment.value)
            case .short("f"), .long("file"):
                guard let path = option.value, !path.isEmpty else {
                    throw MSPPOSIXAwkError.usage("awk: \(MSPPOSIXOptionParser.optionDisplayName(option)) requires a script file")
                }
                programFiles.append(path)
            case .long(let name):
                throw MSPPOSIXAwkError.usage(awkUnsupportedLongOptionMessage(name: name, value: option.value))
            default:
                throw MSPPOSIXAwkError.usage(MSPPOSIXOptionParser.unsupportedOptionMessage(command: "awk", option: option))
            }
        }

        let program: String
        let rawPaths: [String]
        if programFiles.isEmpty {
            guard let inlineProgram = parsed.operands.first else {
                throw MSPPOSIXAwkError.usage("awk: missing program")
            }
            program = inlineProgram
            rawPaths = Array(parsed.operands.dropFirst())
        } else {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            program = try programFiles.map { path in
                do {
                    return String(decoding: try fileSystem.readFile(path, from: context.currentDirectory), as: UTF8.self)
                } catch {
                    throw MSPPOSIXAwkError.failure(
                        "awk: \(MSPPOSIXCommandSupport.displayPath(path)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                    )
                }
            }.joined(separator: "\n")
            rawPaths = parsed.operands
        }

        let runtimeOperands = awkRuntimeOperands(rawPaths)
        for assignment in runtimeOperands.variables {
            initialVariables[assignment.name] = assignment.value
        }
        let text: String
        if runtimeOperands.paths.isEmpty {
            text = String(decoding: context.standardInput, as: UTF8.self)
        } else {
            let input = try await MSPPOSIXCommandSupport.inputData(
                operands: runtimeOperands.paths,
                context: context,
                command: name,
                readStandardInputWhenEmpty: false,
                fileReadDiagnostic: { path, reason in
                    "awk: cannot open \(path) (\(reason))"
                }
            )
            guard input.diagnostics.isEmpty else {
                return .failure(exitCode: 2, stderr: input.diagnostics.joined(separator: "\n") + "\n")
            }
            text = String(decoding: input.inputs.reduce(into: Data()) { data, input in
                data.append(input.data)
            }, as: UTF8.self)
        }
        let result = try MSPPOSIXAwkRunner(
            program: program,
            fieldSeparator: fieldSeparator,
            variables: initialVariables,
            commandOutput: { command in
                try mspPOSIXAwkCommandOutput(command, context: context)
            },
            fileInput: { path in
                let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                return String(decoding: try fileSystem.readFile(path, from: context.currentDirectory), as: UTF8.self)
            }
        ).run(text: text)
        var stdout = result.stdout
        var stderr = ""
        for output in result.fileOutputs {
            switch output.path {
            case "/dev/stdout":
                stdout += output.text
            case "/dev/stderr":
                stderr += output.text
            case "/dev/null":
                continue
            default:
                try writeAwkFileOutput(output, context: context)
            }
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var fieldSeparator: String?
        var initialVariables: [String: String] = [:]
        var programFiles: [String] = []
        let parsed = try MSPPOSIXOptionParser.parse(
            invocation.arguments,
            command: "awk",
            shortOptionsRequiringValue: ["F", "v", "f", "W"],
            longOptionsRequiringValue: ["file"]
        )
        for option in parsed.options {
            switch option.name {
            case .short("W"):
                if mspPOSIXAwkWOptionRequestsVersion(option.value ?? "") {
                    return awkVersionResult()
                }
                if mspPOSIXAwkWOptionRequestsHelp(option.value ?? "") {
                    return .success(stdout: mspAwkUsageText)
                }
                throw MSPPOSIXAwkError.usage("awk: unsupported option -- W \(option.value ?? "")")
            case .short("F"):
                fieldSeparator = mspPOSIXAwkDecodeBackslashEscapes(option.value ?? "")
            case .short("v"):
                let assignment = option.value ?? ""
                guard let parsedAssignment = mspPOSIXAwkAssignment(assignment) else {
                    throw MSPPOSIXAwkError.usage("awk: invalid variable assignment \(assignment)")
                }
                initialVariables[parsedAssignment.name] = mspPOSIXAwkDecodeBackslashEscapes(parsedAssignment.value)
            case .short("f"), .long("file"):
                guard let path = option.value, !path.isEmpty else {
                    throw MSPPOSIXAwkError.usage("awk: \(MSPPOSIXOptionParser.optionDisplayName(option)) requires a script file")
                }
                programFiles.append(path)
            case .long(let name):
                throw MSPPOSIXAwkError.usage(awkUnsupportedLongOptionMessage(name: name, value: option.value))
            default:
                throw MSPPOSIXAwkError.usage(MSPPOSIXOptionParser.unsupportedOptionMessage(command: "awk", option: option))
            }
        }

        let program: String
        let rawPaths: [String]
        if programFiles.isEmpty {
            guard let inlineProgram = parsed.operands.first else {
                throw MSPPOSIXAwkError.usage("awk: missing program")
            }
            program = inlineProgram
            rawPaths = Array(parsed.operands.dropFirst())
        } else {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            program = try programFiles.map { path in
                do {
                    return String(decoding: try fileSystem.readFile(path, from: context.currentDirectory), as: UTF8.self)
                } catch {
                    throw MSPPOSIXAwkError.failure(
                        "awk: \(MSPPOSIXCommandSupport.displayPath(path)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                    )
                }
            }.joined(separator: "\n")
            rawPaths = parsed.operands
        }

        let runtimeOperands = awkRuntimeOperands(rawPaths)
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }

        for assignment in runtimeOperands.variables {
            initialVariables[assignment.name] = assignment.value
        }

        let runner = MSPPOSIXAwkRunner(
            program: program,
            fieldSeparator: fieldSeparator,
            variables: initialVariables,
            commandOutput: { command in
                try mspPOSIXAwkCommandOutput(command, context: context)
            },
            fileInput: { path in
                let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                return String(decoding: try fileSystem.readFile(path, from: context.currentDirectory), as: UTF8.self)
            }
        )

        do {
            let shouldReadRecords = try runner.start()
            try await flushAwkStdout(from: runner, to: standardOutput)
            if shouldReadRecords {
                if let diagnostic = try await streamAwkInputs(
                    paths: runtimeOperands.paths,
                    context: context,
                    to: standardOutput,
                    runner: runner
                ) {
                    return .failure(exitCode: 2, stderr: diagnostic + "\n")
                }
            } else {
                await context.standardInputStream?.closeRead()
            }
            let result = try runner.finish()
            if !result.stdout.isEmpty {
                try await standardOutput.write(Data(result.stdout.utf8))
            }
            return try await emitAwkStreamingFileOutputs(result.fileOutputs, context: context)
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
    }

    private func streamAwkInputs(
        paths: [String],
        context: MSPCommandContext,
        to standardOutput: any MSPCommandOutputStream,
        runner: MSPPOSIXAwkRunner
    ) async throws -> String? {
        if paths.isEmpty {
            let standardInput = context.standardInputStream ?? MSPDataInputStream(context.standardInput)
            _ = try await streamAwkRecords(
                from: standardInput,
                to: standardOutput,
                runner: runner
            )
            return nil
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var standardInputConsumed = false

        for path in paths {
            let stream: any MSPCommandInputStream
            if path == "-" {
                if standardInputConsumed {
                    stream = MSPDataInputStream(Data())
                } else {
                    standardInputConsumed = true
                    stream = context.standardInputStream ?? MSPDataInputStream(context.standardInput)
                }
            } else {
                do {
                    let info = try fileSystem.stat(path, from: context.currentDirectory)
                    guard info.type != .directory else {
                        return "awk: cannot open \(MSPPOSIXCommandSupport.displayPath(path)) (Is a directory)"
                    }
                } catch {
                    return "awk: cannot open \(MSPPOSIXCommandSupport.displayPath(path)) (\(MSPPOSIXCommandSupport.diagnosticReason(from: error)))"
                }
                stream = MSPWorkspaceFileInputStream(
                    fileSystem: fileSystem,
                    path: path,
                    currentDirectory: context.currentDirectory
                )
            }

            let shouldContinue = try await streamAwkRecords(
                from: stream,
                to: standardOutput,
                runner: runner
            )
            guard shouldContinue else {
                return nil
            }
        }
        return nil
    }

    private func streamAwkRecords(
        from standardInput: any MSPCommandInputStream,
        to standardOutput: any MSPCommandOutputStream,
        runner: MSPPOSIXAwkRunner
    ) async throws -> Bool {
        let rawSeparator = runner.recordSeparator
        let separator = Data((rawSeparator.isEmpty ? "\n" : rawSeparator).utf8)
        var buffer = Data()

        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            buffer.append(chunk)
            while let separatorRange = buffer.mspAwkFirstRange(of: separator) {
                let recordData = buffer.subdata(in: buffer.startIndex..<separatorRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<separatorRange.upperBound)
                guard try runner.processRecord(String(decoding: recordData, as: UTF8.self)) else {
                    try await flushAwkStdout(from: runner, to: standardOutput)
                    await standardInput.closeRead()
                    return false
                }
                try await flushAwkStdout(from: runner, to: standardOutput)
            }
        }

        if !buffer.isEmpty {
            guard try runner.processRecord(String(decoding: buffer, as: UTF8.self)) else {
                try await flushAwkStdout(from: runner, to: standardOutput)
                await standardInput.closeRead()
                return false
            }
            try await flushAwkStdout(from: runner, to: standardOutput)
        }
        return true
    }

    private func flushAwkStdout(
        from runner: MSPPOSIXAwkRunner,
        to standardOutput: any MSPCommandOutputStream
    ) async throws {
        let stdout = runner.drainStdout()
        if !stdout.isEmpty {
            try await standardOutput.write(Data(stdout.utf8))
        }
    }

    private func emitAwkStreamingFileOutputs(
        _ fileOutputs: [MSPPOSIXAwkFileOutput],
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var stderrData = Data()
        for output in fileOutputs {
            switch output.path {
            case "/dev/stdout":
                try await context.standardOutputStream?.write(Data(output.text.utf8))
            case "/dev/stderr":
                if let standardError = context.standardErrorStream {
                    try await standardError.write(Data(output.text.utf8))
                } else {
                    stderrData.append(contentsOf: output.text.utf8)
                }
            case "/dev/null":
                continue
            default:
                try writeAwkFileOutput(output, context: context)
            }
        }
        return MSPCommandResult(stdoutData: Data(), stderrData: stderrData)
    }
}

private extension Data {
    func mspAwkFirstRange(of needle: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, count >= needle.count else {
            return nil
        }
        var index = startIndex
        let lastStart = endIndex - needle.count
        while index <= lastStart {
            var matches = true
            var offset = 0
            while offset < needle.count {
                if self[index + offset] != needle[needle.startIndex + offset] {
                    matches = false
                    break
                }
                offset += 1
            }
            if matches {
                return index..<(index + needle.count)
            }
            index += 1
        }
        return nil
    }
}

private func awkVersionResult() -> MSPCommandResult {
    MSPCommandResult(stdout: "mawk 1.3.4 20200120\nCopyright 2008-2019,2020, Thomas E. Dickey\n")
}

private func mspPOSIXAwkWOptionRequestsVersion(_ value: String) -> Bool {
    value.split(separator: ",").contains { component in
        "version".hasPrefix(component.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

private func mspPOSIXAwkWOptionRequestsHelp(_ value: String) -> Bool {
    value.split(separator: ",").contains { component in
        let normalized = component.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "help".hasPrefix(normalized) || "usage".hasPrefix(normalized)
    }
}

private let mspAwkUsageText = """
Usage: awk [POSIX or GNU style options] -f progfile [--] file ...
Usage: awk [POSIX or GNU style options] [--] 'program' file ...
POSIX options:          GNU long options: (standard)
        -f progfile             --file=progfile
        -F fs                   --field-separator=fs
        -v var=val              --assign=var=val
Short options:          GNU long options: (extensions)
        -W version              --version
        -W help                 --help
        -W usage                --usage

"""

private func awkUnsupportedLongOptionMessage(name: String, value: String?) -> String {
    let valueSuffix = value.map { "=\($0)" } ?? ""
    return "awk: not an option: --\(name)\(valueSuffix)"
}

private func awkRuntimeOperands(_ operands: [String]) -> (variables: [(name: String, value: String)], paths: [String]) {
    var variables: [(name: String, value: String)] = []
    var paths: [String] = []
    for operand in operands {
        if let assignment = mspPOSIXAwkAssignment(operand) {
            variables.append((assignment.name, mspPOSIXAwkDecodeBackslashEscapes(assignment.value)))
        } else {
            paths.append(operand)
        }
    }
    return (variables, paths)
}

private func writeAwkFileOutput(_ output: MSPPOSIXAwkFileOutput, context: MSPCommandContext) throws {
    let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: "awk")
    let resolved = try fileSystem.resolve(output.path, from: context.currentDirectory)
    guard resolved.virtualPath != "/" else {
        throw MSPPOSIXAwkError.failure("/: Is a directory")
    }
    var data = Data()
    if output.append {
        if let existing = try? fileSystem.readFile(resolved.virtualPath, from: "/") {
            data.append(existing)
        }
    }
    data.append(Data(output.text.utf8))
    try fileSystem.writeFile(
        resolved.virtualPath,
        data: data,
        from: "/",
        options: [.overwriteExisting],
        creationMode: context.regularFileCreationMode
    )
}

private func mspPOSIXAwkCommandOutput(_ command: String, context: MSPCommandContext) throws -> String {
    let semaphore = DispatchSemaphore(value: 0)
    final class ResultBox: @unchecked Sendable {
        var result: MSPCommandResult?
    }
    let box = ResultBox()
    Task {
        box.result = await context.runCommandLine(command)
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.result else {
        throw MSPPOSIXAwkError.failure("awk: command getline failed: \(command)")
    }
    guard result.exitCode == 0 else {
        let diagnostic = result.stderr.isEmpty ? "\(command): exit status \(result.exitCode)" : result.stderr
        throw MSPPOSIXAwkError.failure(diagnostic.trimmingCharacters(in: .newlines))
    }
    return result.stdout
}
