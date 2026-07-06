import Foundation
import MSPCore

public struct MSPSedCommand: MSPStreamingCommand {
    public let name = "sed"
    public let summary: String? = "Filter and transform text with sed scripts."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspSedUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "sed (GNU sed) 4.9\n")
        }
        let sedInvocation = try MSPPOSIXSedParser.parseInvocation(invocation.arguments)
        let scriptCommands = try resolveScriptCommands(for: sedInvocation, context: context)

        if sedInvocation.inPlace {
            guard !sedInvocation.paths.isEmpty else {
                throw MSPCommandFailure.usage("sed: no input files\n")
            }
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            for path in sedInvocation.paths {
                do {
                    let resolved = try fileSystem.resolve(path, from: context.currentDirectory)
                    let data = try fileSystem.readFile(resolved.virtualPath, from: "/")
                    let updated = try apply(scriptCommands: scriptCommands, data: data, sedInvocation: sedInvocation)
                    try fileSystem.writeFile(
                        resolved.virtualPath,
                        data: Data(updated.utf8),
                        from: "/",
                        options: [.overwriteExisting]
                    )
                } catch let failure as MSPCommandFailure {
                    throw failure
                } catch {
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    return .failure(
                        exitCode: 2,
                        stderr: "sed: can't read \(MSPPOSIXCommandSupport.displayPath(path)): \(reason)\n"
                    )
                }
            }
            return .success()
        }

        let inputText: String
        if sedInvocation.paths.isEmpty {
            inputText = String(decoding: context.standardInput, as: UTF8.self)
        } else {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            var combined = ""
            for path in sedInvocation.paths {
                do {
                    combined += String(decoding: try fileSystem.readFile(path, from: context.currentDirectory), as: UTF8.self)
                } catch {
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    return .failure(
                        exitCode: 2,
                        stdout: combined,
                        stderr: "sed: can't read \(MSPPOSIXCommandSupport.displayPath(path)): \(reason)\n"
                    )
                }
            }
            inputText = combined
        }

        return .success(stdout: try MSPPOSIXSedRunner.apply(
            scriptCommands: scriptCommands,
            text: inputText,
            suppressAutomaticPrint: sedInvocation.suppressAutomaticPrint,
            extendedRegex: sedInvocation.extendedRegex
        ))
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard !invocation.arguments.contains("--help"),
              !invocation.arguments.contains("--version")
        else {
            return try await run(invocation: invocation, context: context)
        }
        let sedInvocation = try MSPPOSIXSedParser.parseInvocation(invocation.arguments)
        guard !sedInvocation.inPlace,
              sedInvocation.paths.isEmpty,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        let scriptCommands = try resolveScriptCommands(for: sedInvocation, context: context)
        var processor = try MSPPOSIXSedRunner.makeStreamingProcessor(
            scriptCommands: scriptCommands,
            suppressAutomaticPrint: sedInvocation.suppressAutomaticPrint,
            extendedRegex: sedInvocation.extendedRegex
        )
        do {
            try await streamSedInput(
                standardInput: standardInput,
                standardOutput: standardOutput,
                processor: &processor
            )
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func resolveScriptCommands(
        for sedInvocation: MSPPOSIXSedInvocation,
        context: MSPCommandContext
    ) throws -> [String] {
        var commands: [String] = []
        for source in sedInvocation.scriptSources {
            switch source {
            case .expression(let script):
                commands.append(contentsOf: try MSPPOSIXSedParser.splitScriptCommands(script))
            case .file(let rawPath):
                let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                do {
                    let script = String(decoding: try fileSystem.readFile(rawPath, from: context.currentDirectory), as: UTF8.self)
                    commands.append(contentsOf: try MSPPOSIXSedParser.splitScriptCommands(script))
                } catch let failure as MSPCommandFailure {
                    throw failure
                } catch {
                    throw MSPCommandFailure.usage("sed: \(MSPPOSIXCommandSupport.displayPath(rawPath)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n")
                }
            }
        }
        return commands
    }

    private func apply(
        scriptCommands: [String],
        data: Data,
        sedInvocation: MSPPOSIXSedInvocation
    ) throws -> String {
        try MSPPOSIXSedRunner.apply(
            scriptCommands: scriptCommands,
            text: String(decoding: data, as: UTF8.self),
            suppressAutomaticPrint: sedInvocation.suppressAutomaticPrint,
            extendedRegex: sedInvocation.extendedRegex
        )
    }

    private func streamSedInput(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        processor: inout MSPPOSIXSedRunner.StreamingProcessor
    ) async throws {
        var buffer = Data()
        var pendingRecord: (text: String, terminated: Bool)?

        func emitPending(isLast: Bool) async throws -> Bool {
            guard let record = pendingRecord else {
                return false
            }
            let result = try processor.process(
                text: record.text,
                terminated: record.terminated,
                isLast: isLast
            )
            if !result.output.isEmpty {
                try await standardOutput.write(Data(result.output.utf8))
            }
            pendingRecord = nil
            return result.shouldQuit
        }

        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let recordData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)
                if try await emitPending(isLast: false) {
                    await standardInput.closeRead()
                    return
                }
                pendingRecord = (String(decoding: recordData, as: UTF8.self), true)
            }
        }

        if !buffer.isEmpty {
            if try await emitPending(isLast: false) {
                await standardInput.closeRead()
                return
            }
            pendingRecord = (String(decoding: buffer, as: UTF8.self), false)
        }
        if try await emitPending(isLast: true) {
            await standardInput.closeRead()
        }
    }
}

private let mspSedUsageText = """
Usage: sed [OPTION]... {script-only-if-no-other-script} [input-file]...

  -n, --quiet, --silent
                 suppress automatic printing of pattern space
      --debug
                 annotate program execution
  -e script, --expression=script
                 add the script to the commands to be executed
  -f script-file, --file=script-file
                 add the contents of script-file to the commands to be executed
  -E, -r, --regexp-extended
                 use extended regular expressions in the script
  -i[SUFFIX], --in-place[=SUFFIX]
                 edit files in place
      --help     display this help and exit
      --version  output version information and exit

"""
