import Foundation
import MSPCore

public struct MSPCksumCommand: MSPCommand {
    public let name = "cksum"
    public let summary: String? = "Print or verify checksums."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspPOSIXChecksumUsage(command: name))
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "\(name) (GNU coreutils) 9.1\n")
        }
        let parsed = try MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["c", "w", "z"],
            allowedLongOptions: [
                "check",
                "debug",
                "help",
                "ignore-missing",
                "quiet",
                "status",
                "strict",
                "tag",
                "untagged",
                "version",
                "warn",
                "zero"
            ],
            shortOptionsRequiringValue: ["a", "l"],
            longOptionsRequiringValue: ["algorithm", "length"]
        ).parse(invocation.arguments)
        let selection = try MSPCksumAlgorithmSelection(options: parsed.options, command: name)
        let options = MSPDigestOptions(
            options: parsed.options,
            defaultTagged: selection.algorithm.usesTaggedOutputByDefault
        )
        let isChecking = parsed.options.contains { $0.matches(short: "c", long: "check") }
        try mspPOSIXValidateDigestModeOptions(
            parsed.options,
            options: options,
            command: name,
            isChecking: isChecking,
            allowsTaggedCheckOption: true,
            allowsBinaryTextCheckOptions: true
        )

        if isChecking {
            if selection.algorithmWasSpecified, !selection.algorithm.supportsChecking {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "\(name): --check is not supported with --algorithm={bsd,sysv,crc}\n"
                ))
            }
            guard case .digest(let algorithm) = selection.algorithm else {
                return try await cksumNoProperlyFormattedCheckLines(parsed.operands, context: context)
            }
            return try await mspPOSIXCheckDigests(
                parsed.operands,
                options: options,
                algorithm: algorithm,
                context: context,
                command: name
            )
        }

        let result = try await cksumRows(
            operands: parsed.operands,
            algorithm: selection.algorithm,
            options: options,
            context: context
        )
        let stderrPrefix = selection.debugEnabled && selection.algorithm == .crc
            ? "\(name): using generic hardware support\n"
            : ""
        return MSPCommandResult(
            stdoutData: result.rows.reduce(into: Data()) { $0.append($1) },
            stderr: stderrPrefix + (result.diagnostics.isEmpty ? "" : result.diagnostics.joined(separator: "\n") + "\n"),
            exitCode: result.exitCode
        )
    }

    private func cksumRows(
        operands: [String],
        algorithm: MSPCksumAlgorithm,
        options: MSPDigestOptions,
        context: MSPCommandContext
    ) async throws -> (rows: [Data], diagnostics: [String], exitCode: Int32) {
        try await mspPOSIXChecksumRows(operands: operands, context: context, command: name) { input in
            cksumRow(data: input.data, label: input.label, algorithm: algorithm, options: options)
        } fileRender: { fileSystem, operand in
            try cksumFileRow(
                fileSystem: fileSystem,
                operand: operand,
                algorithm: algorithm,
                options: options,
                context: context
            )
        }
    }

    private func cksumRow(
        data: Data,
        label: String?,
        algorithm: MSPCksumAlgorithm,
        options: MSPDigestOptions
    ) -> Data {
        switch algorithm {
        case .crc:
            return mspPOSIXCksumOutputRow(mspPOSIXCksum(data), label: label, delimiter: options.delimiter)
        case .bsd:
            return mspPOSIXSumOutputRow(data: data, label: label, algorithm: .bsd, delimiter: options.delimiter)
        case .sysv:
            return mspPOSIXSumOutputRow(data: data, label: label, algorithm: .sysv, delimiter: options.delimiter)
        case .digest(let digestAlgorithm):
            return mspPOSIXDigestOutputRow(
                hex: digestAlgorithm.digestHex(data),
                label: label ?? "-",
                algorithm: digestAlgorithm,
                options: options
            )
        }
    }

    private func cksumFileRow(
        fileSystem: any MSPWorkspaceFileSystem,
        operand: String,
        algorithm: MSPCksumAlgorithm,
        options: MSPDigestOptions,
        context: MSPCommandContext
    ) throws -> Data {
        switch algorithm {
        case .crc:
            let checksum = try mspPOSIXCksumFile(
                fileSystem: fileSystem,
                path: operand,
                currentDirectory: context.currentDirectory
            )
            return mspPOSIXCksumOutputRow(checksum, label: operand, delimiter: options.delimiter)
        case .bsd:
            let data = try fileSystem.readFile(operand, from: context.currentDirectory)
            return mspPOSIXSumOutputRow(data: data, label: operand, algorithm: .bsd, delimiter: options.delimiter)
        case .sysv:
            let data = try fileSystem.readFile(operand, from: context.currentDirectory)
            return mspPOSIXSumOutputRow(data: data, label: operand, algorithm: .sysv, delimiter: options.delimiter)
        case .digest(let digestAlgorithm):
            return mspPOSIXDigestOutputRow(
                hex: try digestAlgorithm.digestHex(
                    fileSystem: fileSystem,
                    path: operand,
                    currentDirectory: context.currentDirectory
                ),
                label: operand,
                algorithm: digestAlgorithm,
                options: options
            )
        }
    }

    private func cksumNoProperlyFormattedCheckLines(
        _ operands: [String],
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let checkInput = try await MSPPOSIXCommandSupport.inputData(
            operands: operands,
            context: context,
            command: name
        )
        if checkInput.exitCode != 0 {
            return MSPCommandResult(
                stderr: checkInput.diagnostics.joined(separator: "\n") + "\n",
                exitCode: checkInput.exitCode
            )
        }
        let label = mspPOSIXChecksumInputLabel(checkInput.inputs.first?.label)
        return MSPCommandResult(
            stderr: "\(name): \(label): no properly formatted checksum lines found\n",
            exitCode: 1
        )
    }
}

public struct MSPDigestCommand: MSPCommand {
    public let name: String
    public let summary: String?
    private let algorithm: MSPDigestAlgorithm

    public init(name: String, algorithm: MSPDigestAlgorithm) {
        self.name = name
        self.algorithm = algorithm
        self.summary = "Print \(algorithm.label) checksums."
    }

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspPOSIXChecksumUsage(command: name))
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "\(name) (GNU coreutils) 9.1\n")
        }
        let supportsLength = algorithm.supportsLengthOption
        let parsed = try MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["b", "c", "t", "w", "z"],
            allowedLongOptions: [
                "binary",
                "text",
                "check",
                "help",
                "ignore-missing",
                "quiet",
                "status",
                "strict",
                "tag",
                "version",
                "warn",
                "zero"
            ],
            shortOptionsRequiringValue: supportsLength ? ["l"] : [],
            longOptionsRequiringValue: supportsLength ? ["length"] : []
        ).parse(invocation.arguments)
        let effectiveAlgorithm = try algorithm.effectiveAlgorithm(from: parsed.options, command: name)
        let options = MSPDigestOptions(options: parsed.options)
        let isChecking = parsed.options.contains { $0.matches(short: "c", long: "check") }
        try mspPOSIXValidateDigestModeOptions(
            parsed.options,
            options: options,
            command: name,
            isChecking: isChecking,
            allowsTaggedCheckOption: false,
            allowsBinaryTextCheckOptions: false
        )
        if isChecking {
            return try await mspPOSIXCheckDigests(
                parsed.operands,
                options: options,
                algorithm: effectiveAlgorithm,
                context: context,
                command: name
            )
        }
        let result = try await mspPOSIXChecksumRows(operands: parsed.operands, context: context, command: name) { input -> Data in
            let label = input.label ?? "-"
            return mspPOSIXDigestOutputRow(
                hex: effectiveAlgorithm.digestHex(input.data),
                label: label,
                algorithm: effectiveAlgorithm,
                options: options
            )
        } fileRender: { fileSystem, operand in
            mspPOSIXDigestOutputRow(
                hex: try effectiveAlgorithm.digestHex(
                    fileSystem: fileSystem,
                    path: operand,
                    currentDirectory: context.currentDirectory
                ),
                label: operand,
                algorithm: effectiveAlgorithm,
                options: options
            )
        }
        return MSPCommandResult(
            stdoutData: result.rows.reduce(into: Data()) { $0.append($1) },
            stderr: result.diagnostics.isEmpty ? "" : result.diagnostics.joined(separator: "\n") + "\n",
            exitCode: result.exitCode
        )
    }
}

private func mspPOSIXChecksumUsage(command: String) -> String {
    """
    Usage: \(command) [OPTION]... [FILE]...
    Print or check checksums.

    """
}

public struct MSPB2SumCommand: MSPCommand {
    public let name = "b2sum"
    public let summary: String? = "Print BLAKE2b checksums."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await MSPDigestCommand(name: name, algorithm: .blake2b(byteCount: 64))
            .run(invocation: invocation, context: context)
    }
}
