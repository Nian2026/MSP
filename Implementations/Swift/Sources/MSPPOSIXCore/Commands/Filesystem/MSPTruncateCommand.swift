import Foundation
import MSPCore

public struct MSPTruncateCommand: MSPCommand {
    public let name = "truncate"
    public let summary: String? = "Shrink or extend workspace files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = parse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard parsed.sizeSpec != nil || parsed.referencePath != nil else {
            return .failure(
                exitCode: 1,
                stderr: "truncate: you must specify either \(mspCore100CurlyQuote("--size")) or \(mspCore100CurlyQuote("--reference"))\n\(mspCore100GNUHelpHint(name))"
            )
        }
        if parsed.ioBlocks, parsed.sizeSpec == nil {
            return .failure(
                exitCode: 1,
                stderr: "truncate: \(mspCore100CurlyQuote("--io-blocks")) was specified but \(mspCore100CurlyQuote("--size")) was not\n\(mspCore100GNUHelpHint(name))"
            )
        }
        if parsed.referencePath != nil, parsed.sizeSpec?.mode == .absolute {
            return .failure(
                exitCode: 1,
                stderr: "truncate: you must specify a relative \(mspCore100CurlyQuote("--size")) with \(mspCore100CurlyQuote("--reference"))\n\(mspCore100GNUHelpHint(name))"
            )
        }
        guard !parsed.operands.isEmpty else {
            return .failure(
                exitCode: 1,
                stderr: "truncate: missing file operand\n\(mspCore100GNUHelpHint(name))"
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let referenceSize: Int64?
        if let referencePath = parsed.referencePath {
            do {
                referenceSize = try fileSystem.stat(referencePath, from: context.currentDirectory).size ?? 0
            } catch {
                return .failure(
                    stderr: "truncate: cannot stat '\(mspCore100DisplayPath(referencePath))': \(mspCore100Reason(error))\n"
                )
            }
        } else {
            referenceSize = nil
        }

        var diagnostics: [String] = []
        for operand in parsed.operands {
            do {
                try apply(
                    operand: operand,
                    parsed: parsed,
                    referenceSize: referenceSize,
                    context: context,
                    fileSystem: fileSystem
                )
            } catch is TruncateSkipMissing {
                continue
            } catch {
                diagnostics.append("truncate: cannot truncate '\(mspCore100DisplayPath(operand))': \(mspCore100Reason(error))")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success()
    }

    private func apply(
        operand: String,
        parsed: TruncateParseResult,
        referenceSize: Int64?,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        let resolved = try fileSystem.resolve(operand, from: context.currentDirectory)
        let info: MSPFileInfo?
        do {
            info = try fileSystem.stat(resolved.virtualPath, from: "/")
        } catch MSPWorkspaceFileSystemError.notFound where parsed.noCreate {
            throw TruncateSkipMissing()
        } catch MSPWorkspaceFileSystemError.notFound {
            info = nil
        }

        let currentSize = info?.size ?? 0
        let targetSize = targetSize(
            currentSize: currentSize,
            referenceSize: referenceSize,
            sizeSpec: parsed.sizeSpec
        )
        let boundedTargetSize = max(0, targetSize)
        guard boundedTargetSize <= Int64(mspCore100MaximumMaterializedFileSize) else {
            throw MSPWorkspaceFileSystemError.io(path: resolved.virtualPath, operation: "file too large")
        }
        guard currentSize <= Int64(mspCore100MaximumMaterializedFileSize) || boundedTargetSize < currentSize else {
            throw MSPWorkspaceFileSystemError.io(path: resolved.virtualPath, operation: "file too large")
        }

        var data = Data()
        if boundedTargetSize > 0, info != nil {
            let readLength = Int(min(currentSize, boundedTargetSize))
            if readLength > 0 {
                data = try fileSystem.readFileRange(
                    resolved.virtualPath,
                    from: "/",
                    offset: 0,
                    length: readLength
                )
            }
        }
        if Int64(data.count) < boundedTargetSize {
            data.append(Data(repeating: 0, count: Int(boundedTargetSize) - data.count))
        }
        try fileSystem.writeFile(
            resolved.virtualPath,
            data: data,
            from: "/",
            options: [.overwriteExisting],
            creationMode: info == nil ? context.regularFileCreationMode : nil
        )
    }

    private func targetSize(
        currentSize: Int64,
        referenceSize: Int64?,
        sizeSpec: TruncateSizeSpec?
    ) -> Int64 {
        guard let sizeSpec else {
            return referenceSize ?? currentSize
        }
        let base = referenceSize ?? currentSize
        switch sizeSpec.mode {
        case .absolute:
            return sizeSpec.amount
        case .relativePlus:
            return base + sizeSpec.amount
        case .relativeMinus:
            return base - sizeSpec.amount
        case .atMost:
            return min(base, sizeSpec.amount)
        case .atLeast:
            return max(base, sizeSpec.amount)
        case .roundDown:
            return sizeSpec.amount == 0 ? base : base - (base % sizeSpec.amount)
        case .roundUp:
            guard sizeSpec.amount != 0 else {
                return base
            }
            let remainder = base % sizeSpec.amount
            return remainder == 0 ? base : base + sizeSpec.amount - remainder
        }
    }

    private func parse(_ arguments: [String]) -> TruncateParseResult {
        var result = TruncateParseResult()
        var parsingOptions = true
        var index = 0

        func requireValue(option: String) -> String? {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                result.result = .failure(
                    exitCode: 1,
                    stderr: "truncate: option requires an argument -- '\(option)'\n\(mspCore100GNUHelpHint(name))"
                )
                return nil
            }
            index = nextIndex
            return arguments[nextIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if !parsingOptions {
                result.operands.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                parsingOptions = false
                index += 1
                continue
            }
            if argument.hasPrefix("--"), argument.count > 2 {
                let body = String(argument.dropFirst(2))
                let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let option = String(parts[0])
                let inlineValue = parts.count == 2 ? String(parts[1]) : nil
                switch option {
                case "no-create":
                    result.noCreate = true
                case "io-blocks":
                    result.ioBlocks = true
                case "reference":
                    guard let value = inlineValue ?? requireValue(option: "reference") else {
                        return result
                    }
                    result.referencePath = value
                case "size":
                    guard let value = inlineValue ?? requireValue(option: "size") else {
                        return result
                    }
                    result.sizeSpec = parseSize(value, ioBlocks: result.ioBlocks)
                    if result.sizeSpec == nil {
                        result.result = invalidSize(value)
                        return result
                    }
                default:
                    let invalid = option.first ?? "?"
                    result.result = mspCore100InvalidOption(name, option: invalid)
                    return result
                }
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-", !isSizeLikeOperand(argument) {
                let characters = Array(argument.dropFirst())
                var characterIndex = 0
                while characterIndex < characters.count {
                    let option = characters[characterIndex]
                    switch option {
                    case "c":
                        result.noCreate = true
                    case "o":
                        result.ioBlocks = true
                    case "r", "s":
                        let tail = String(characters.dropFirst(characterIndex + 1))
                        let value: String
                        if tail.isEmpty {
                            guard let required = requireValue(option: String(option)) else {
                                return result
                            }
                            value = required
                        } else {
                            value = tail
                        }
                        if option == "r" {
                            result.referencePath = value
                        } else {
                            result.sizeSpec = parseSize(value, ioBlocks: result.ioBlocks)
                            if result.sizeSpec == nil {
                                result.result = invalidSize(value)
                                return result
                            }
                        }
                        characterIndex = characters.count
                        continue
                    default:
                        result.result = mspCore100InvalidOption(name, option: option)
                        return result
                    }
                    characterIndex += 1
                }
                index += 1
                continue
            }
            result.operands.append(argument)
            index += 1
        }
        return result
    }

    private func parseSize(_ rawValue: String, ioBlocks: Bool) -> TruncateSizeSpec? {
        guard !rawValue.isEmpty else {
            return nil
        }
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: TruncateSizeMode
        if text.hasPrefix("<") {
            mode = .atMost
            text.removeFirst()
        } else if text.hasPrefix(">") {
            mode = .atLeast
            text.removeFirst()
        } else if text.hasPrefix("/") {
            mode = .roundDown
            text.removeFirst()
        } else if text.hasPrefix("%") {
            mode = .roundUp
            text.removeFirst()
        } else if text.hasPrefix("+") {
            mode = .relativePlus
            text.removeFirst()
        } else if text.hasPrefix("-") {
            mode = .relativeMinus
            text.removeFirst()
        } else {
            mode = .absolute
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != .absolute, text.hasPrefix("+") || text.hasPrefix("-") {
            return nil
        }
        guard !text.isEmpty else {
            return nil
        }

        var multiplier: Int64 = ioBlocks ? 4096 : 1
        guard let suffixMultiplier = Self.sizeSuffixMultiplier(from: &text) else {
            return nil
        }
        let (combinedMultiplier, multiplierOverflow) = multiplier.multipliedReportingOverflow(by: suffixMultiplier)
        guard !multiplierOverflow else {
            return nil
        }
        multiplier = combinedMultiplier
        guard !text.isEmpty,
              text.allSatisfy({ $0.isNumber }),
              let number = Int64(text)
        else {
            return nil
        }
        let (amount, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow, !((mode == .roundDown || mode == .roundUp) && amount == 0) else {
            return nil
        }
        return TruncateSizeSpec(mode: mode, amount: amount)
    }

    private static func sizeSuffixMultiplier(from text: inout String) -> Int64? {
        let suffixes: [(String, Int64)] = [
            ("KiB", 1024),
            ("K", 1024),
            ("k", 1024),
            ("MiB", 1024 * 1024),
            ("M", 1024 * 1024),
            ("m", 1024 * 1024),
            ("GiB", 1024 * 1024 * 1024),
            ("G", 1024 * 1024 * 1024),
            ("g", 1024 * 1024 * 1024),
            ("TiB", 1024 * 1024 * 1024 * 1024),
            ("T", 1024 * 1024 * 1024 * 1024),
            ("t", 1024 * 1024 * 1024 * 1024),
            ("PiB", 1_125_899_906_842_624),
            ("P", 1_125_899_906_842_624),
            ("EiB", 1_152_921_504_606_846_976),
            ("E", 1_152_921_504_606_846_976)
        ]
        for (suffix, multiplier) in suffixes.sorted(by: { $0.0.count > $1.0.count }) {
            if text.hasSuffix(suffix) {
                text.removeLast(suffix.count)
                return multiplier
            }
        }
        if text.hasSuffix("Z") || text.hasSuffix("Y") {
            return nil
        }
        return 1
    }

    private func invalidSize(_ value: String) -> MSPCommandResult {
        .failure(exitCode: 1, stderr: "truncate: Invalid number: \(mspCore100CurlyQuote(value))\n")
    }

    private func isSizeLikeOperand(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), argument.count > 1 else {
            return false
        }
        return argument.dropFirst().allSatisfy { $0.isNumber }
    }
}

private struct TruncateSkipMissing: Error {}

private enum TruncateSizeMode {
    case absolute
    case relativePlus
    case relativeMinus
    case atMost
    case atLeast
    case roundDown
    case roundUp
}

private struct TruncateSizeSpec {
    var mode: TruncateSizeMode
    var amount: Int64
}

private struct TruncateParseResult {
    var noCreate = false
    var ioBlocks = false
    var referencePath: String?
    var sizeSpec: TruncateSizeSpec?
    var operands: [String] = []
    var result: MSPCommandResult?
}
