import Foundation
import MSPCore

public struct MSPDuCommand: MSPCommand {
    public var name: String { "du" }
    public var summary: String? { "Estimate workspace file space usage." }

    private let spec = MSPPOSIXCommandSpec(
        name: "du",
        allowedShortOptions: ["s", "h", "a", "b", "k", "m", "c", "0"],
        allowedLongOptions: ["summarize", "human-readable", "all", "bytes", "apparent-size", "total", "null"],
        shortOptionsRequiringValue: ["B", "d"],
        longOptionsRequiringValue: ["max-depth", "block-size"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try spec.parse(invocation.arguments)
        var summarize = false
        var all = false
        var showTotal = false
        var measurement = MSPDuMeasurement.allocated
        var displayStyle = MSPDuDisplayStyle.blocks(1024)
        var rowTerminator = "\n"
        var maxDepth: Int?
        for option in parsed.options {
            switch option.name {
            case .short("s"), .long("summarize"):
                summarize = true
            case .short("h"), .long("human-readable"):
                displayStyle = .human
            case .short("a"), .long("all"):
                all = true
            case .short("c"), .long("total"):
                showTotal = true
            case .short("0"), .long("null"):
                rowTerminator = "\0"
            case .short("b"), .long("bytes"):
                measurement = .apparent
                displayStyle = .bytes
            case .long("apparent-size"):
                measurement = .apparent
            case .short("k"):
                displayStyle = .blocks(1024)
            case .short("m"):
                displayStyle = .blocks(1024 * 1024)
            case .short("B"), .long("block-size"):
                displayStyle = try mspPOSIXDuBlockSizeStyle(option.value)
            case .short("d"), .long("max-depth"):
                guard let value = option.value, let depth = Int(value), depth >= 0 else {
                    throw MSPCommandFailure(
                        result: .failure(
                            exitCode: 1,
                            stderr: "du: invalid maximum depth \(mspPOSIXDuQuote(option.value ?? ""))\nTry 'du --help' for more information.\n"
                        )
                    )
                }
                maxDepth = depth
            default:
                continue
            }
        }
        let operands = parsed.operands.isEmpty ? ["."] : parsed.operands
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var rows: [(bytes: Int64, path: String)] = []
        var diagnostics: [String] = []
        var totalBytes: Int64 = 0
        var exitCode: Int32 = 0

        for operand in operands {
            do {
                let root = try fileSystem.stat(operand, from: context.currentDirectory)
                let rootDisplayPath = MSPPOSIXCommandSupport.displayPath(operand)
                let rootSize: Int64
                if summarize {
                    rootSize = try await mspPOSIXCollectDuTotal(
                        of: root,
                        fileSystem: fileSystem,
                        measurement: measurement
                    )
                    rows.append((rootSize, rootDisplayPath))
                } else {
                    rootSize = try await mspPOSIXCollectDuRows(
                        of: root,
                        fileSystem: fileSystem,
                        displayPath: rootDisplayPath,
                        depth: 0,
                        all: all,
                        maxDepth: maxDepth,
                        measurement: measurement,
                        rows: &rows
                    )
                }
                totalBytes += rootSize
            } catch {
                diagnostics.append("du: cannot access '\(MSPPOSIXCommandSupport.displayPath(operand))': \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                exitCode = 1
            }
        }

        if showTotal {
            rows.append((totalBytes, "total"))
        }
        let stdout = rows.map { sizeBytes, path in
            "\(mspPOSIXDuDisplaySize(sizeBytes, style: displayStyle))\t\(path)"
        }.joined(separator: rowTerminator)
        return MSPCommandResult(
            stdout: stdout.isEmpty ? "" : stdout + rowTerminator,
            stderr: diagnostics.isEmpty ? "" : diagnostics.joined(separator: "\n") + "\n",
            exitCode: exitCode
        )
    }
}

private typealias MSPDuRow = (bytes: Int64, path: String)

private enum MSPDuMeasurement {
    case allocated
    case apparent
}

private enum MSPDuDisplayStyle {
    case bytes
    case human
    case blocks(Int64)
}

private func mspPOSIXCollectDuRows(
    of info: MSPFileInfo,
    fileSystem: any MSPWorkspaceFileSystem,
    displayPath: String,
    depth: Int,
    all: Bool,
    maxDepth: Int?,
    measurement: MSPDuMeasurement,
    rows: inout [MSPDuRow]
) async throws -> Int64 {
    var total = mspPOSIXDuEntrySize(info, measurement: measurement)
    if info.isDirectory {
        if let batchFileSystem = fileSystem as? any MSPWorkspaceBatchDirectoryEnumerating {
            try await batchFileSystem.enumerateDirectoryBatches(
                info.virtualPath,
                from: "/",
                options: .all,
                batchSize: 1024
            ) { entries in
                for entry in entries {
                    total += try await mspPOSIXCollectDuRows(
                        of: entry.info,
                        fileSystem: fileSystem,
                        displayPath: childDisplayPath(parent: displayPath, child: entry.name),
                        depth: depth + 1,
                        all: all,
                        maxDepth: maxDepth,
                        measurement: measurement,
                        rows: &rows
                    )
                }
                return true
            }
        } else {
            try await fileSystem.enumerateDirectory(info.virtualPath, from: "/") { entry in
                total += try await mspPOSIXCollectDuRows(
                    of: entry.info,
                    fileSystem: fileSystem,
                    displayPath: childDisplayPath(parent: displayPath, child: entry.name),
                    depth: depth + 1,
                    all: all,
                    maxDepth: maxDepth,
                    measurement: measurement,
                    rows: &rows
                )
                return true
            }
        }
    }

    let shouldPrint: Bool
    if info.isDirectory {
        shouldPrint = maxDepth.map { depth <= $0 } ?? true
    } else {
        shouldPrint = depth == 0 || all
    }
    if shouldPrint {
        rows.append((total, displayPath))
    }
    return total
}

private func mspPOSIXCollectDuTotal(
    of info: MSPFileInfo,
    fileSystem: any MSPWorkspaceFileSystem,
    measurement: MSPDuMeasurement
) async throws -> Int64 {
    var total = mspPOSIXDuEntrySize(info, measurement: measurement)
    guard info.isDirectory else {
        return total
    }

    if let batchFileSystem = fileSystem as? any MSPWorkspaceBatchDirectoryEnumerating {
        try await batchFileSystem.enumerateDirectoryBatches(
            info.virtualPath,
            from: "/",
            options: .all,
            batchSize: 1024
        ) { entries in
            for entry in entries {
                total += try await mspPOSIXCollectDuTotal(
                    of: entry.info,
                    fileSystem: fileSystem,
                    measurement: measurement
                )
            }
            return true
        }
        return total
    }

    try await fileSystem.enumerateDirectory(info.virtualPath, from: "/") { entry in
        total += try await mspPOSIXCollectDuTotal(
            of: entry.info,
            fileSystem: fileSystem,
            measurement: measurement
        )
        return true
    }
    return total
}

private func childDisplayPath(parent: String, child: String) -> String {
    if parent == "/" {
        return "/" + child
    }
    if parent == "." {
        return "./" + child
    }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}

private func mspPOSIXDuEntrySize(_ info: MSPFileInfo, measurement: MSPDuMeasurement) -> Int64 {
    switch measurement {
    case .apparent:
        if info.isDirectory {
            return mspPOSIXDuDirectoryByteSize
        }
        return MSPPOSIXCommandSupport.byteSize(info)
    case .allocated:
        if info.isDirectory {
            return mspPOSIXDuDirectoryByteSize
        }
        let byteSize = MSPPOSIXCommandSupport.byteSize(info)
        guard byteSize > 0 else {
            return 0
        }
        return mspPOSIXRoundUp(byteSize, toMultipleOf: mspPOSIXDuDirectoryByteSize)
    }
}

private let mspPOSIXDuDirectoryByteSize: Int64 = 4096

private func mspPOSIXDuBlockSizeStyle(_ rawValue: String?) throws -> MSPDuDisplayStyle {
    guard let rawValue, !rawValue.isEmpty else {
        throw MSPCommandFailure.usage("du: --block-size requires an argument\n")
    }
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "1" {
        return .bytes
    }
    if let exact = Int64(normalized), exact > 0 {
        return .blocks(exact)
    }
    var digits = ""
    var suffix = ""
    for character in normalized {
        if character.isNumber, suffix.isEmpty {
            digits.append(character)
        } else {
            suffix.append(character)
        }
    }
    let count = Int64(digits).flatMap { $0 > 0 ? $0 : nil } ?? 1
    let multiplier: Int64
    switch suffix {
    case "k", "ki", "kib":
        multiplier = 1024
    case "kb":
        multiplier = 1000
    case "m", "mi", "mib":
        multiplier = 1024 * 1024
    case "mb":
        multiplier = 1000 * 1000
    case "g", "gi", "gib":
        multiplier = 1024 * 1024 * 1024
    case "gb":
        multiplier = 1000 * 1000 * 1000
    default:
        throw MSPCommandFailure.usage("du: invalid --block-size value \(rawValue)\n")
    }
    return .blocks(count * multiplier)
}

private func mspPOSIXDuDisplaySize(_ bytes: Int64, style: MSPDuDisplayStyle) -> String {
    switch style {
    case .bytes:
        return String(bytes)
    case .human:
        return MSPPOSIXCommandSupport.humanSize(bytes)
    case .blocks(let blockSize):
        let divisor = max(blockSize, 1)
        return String((bytes + divisor - 1) / divisor)
    }
}

private func mspPOSIXRoundUp(_ value: Int64, toMultipleOf multiple: Int64) -> Int64 {
    guard multiple > 0 else {
        return value
    }
    return ((value + multiple - 1) / multiple) * multiple
}

private func mspPOSIXDuQuote(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}
