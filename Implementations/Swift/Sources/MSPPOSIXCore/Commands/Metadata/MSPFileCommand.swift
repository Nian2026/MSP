import Foundation
import MSPCore

public struct MSPFileCommand: MSPCommand {
    public var name: String { "file" }
    public var summary: String? { "Classify workspace file contents." }

    private let spec = MSPPOSIXCommandSpec(
        name: "file",
        allowedShortOptions: ["0", "b", "c", "C", "d", "E", "h", "i", "k", "L", "l", "n", "N", "p", "r", "s", "S", "v", "z", "Z"],
        allowedLongOptions: [
            "apple",
            "brief",
            "checking-printout",
            "compile",
            "debug",
            "dereference",
            "extension",
            "help",
            "keep-going",
            "list",
            "mime",
            "mime-encoding",
            "mime-type",
            "no-buffer",
            "no-dereference",
            "no-pad",
            "no-sandbox",
            "preserve-date",
            "print0",
            "raw",
            "special-files",
            "uncompress",
            "uncompress-noreport",
            "version"
        ],
        shortOptionsRequiringValue: ["e", "f", "F", "m", "P"],
        longOptionsRequiringValue: ["exclude", "exclude-quiet", "files-from", "magic-file", "parameter", "separator"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try spec.parse(invocation.arguments)
        var options = MSPFileOptions()
        for option in parsed.options {
            switch option.name {
            case .long("help"):
                return .success(stdout: mspFileUsage())
            case .short("v"), .long("version"):
                return .success(stdout: "file-5.44\n")
            case .short("b"), .long("brief"):
                options.brief = true
            case .short("i"), .long("mime"):
                options.mimeMode = .mime
            case .long("mime-type"):
                options.mimeMode = .mimeType
            case .long("mime-encoding"):
                options.mimeMode = .mimeEncoding
            case .short("0"), .long("print0"):
                options.print0 = true
            case .short("F"), .long("separator"):
                options.separator = option.value ?? ":"
            case .short("N"), .long("no-pad"), .short("n"), .long("no-buffer"), .short("r"), .long("raw"),
                    .short("k"), .long("keep-going"), .short("E"), .short("p"), .long("preserve-date"),
                    .short("h"), .long("no-dereference"), .short("L"), .long("dereference"),
                    .short("d"), .long("debug"), .short("s"), .long("special-files"),
                    .short("S"), .long("no-sandbox"), .short("z"), .long("uncompress"),
                    .short("Z"), .long("uncompress-noreport"):
                continue
            case .short("e"), .long("exclude"), .long("exclude-quiet"):
                guard let value = option.value, mspFileKnownExcludeTests.contains(value) else {
                    return .failure(stderr: "file: invalid exclude type \(MSPPOSIXCommandSupport.gnuQuote(option.value ?? ""))\n")
                }
            case .short("P"), .long("parameter"):
                if let value = option.value, let bytes = mspFileProbeLimit(from: value) {
                    options.probeByteLimit = bytes
                }
            case .short("f"), .long("files-from"):
                if let value = option.value {
                    options.filesFrom.append(value)
                }
            case .short("c"), .long("checking-printout"), .short("C"), .long("compile"), .short("l"), .long("list"),
                    .short("m"), .long("magic-file"), .long("apple"), .long("extension"):
                return .failure(stderr: "file: \(MSPPOSIXOptionParser.optionDisplayName(option)) is not supported in the MSP virtual classifier\n")
            default:
                continue
            }
        }
        var operands = parsed.operands
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        for listPath in options.filesFrom {
            operands.append(contentsOf: try mspFileOperandsFromList(
                listPath,
                context: context,
                fileSystem: fileSystem
            ))
        }
        try spec.requireOperandCount(operands, min: 1)
        var rows: [String] = []
        for operand in operands {
            do {
                let description: String
                if operand == "-" {
                    description = mspPOSIXFileDescription(
                        data: try MSPPOSIXCommandSupport.standardInputData(from: context),
                        lowerName: "-",
                        mimeMode: options.mimeMode
                    )
                } else {
                    let info = try fileSystem.stat(operand, from: context.currentDirectory)
                    description = try mspPOSIXFileDescription(
                        path: operand,
                        info: info,
                        fileSystem: fileSystem,
                        currentDirectory: context.currentDirectory,
                        mimeMode: options.mimeMode,
                        probeByteLimit: options.probeByteLimit
                    )
                }
                rows.append(options.brief ? description : mspFileFormatRow(path: operand, description: description, options: options))
            } catch {
                let message = "cannot open `\(MSPPOSIXCommandSupport.displayPath(operand))' (\(MSPPOSIXCommandSupport.diagnosticReason(from: error)))"
                rows.append(options.brief ? message : mspFileFormatRow(path: operand, description: message, options: options))
            }
        }
        let lineSeparator = options.print0 ? "\0\n" : "\n"
        return MSPCommandResult(
            stdout: rows.isEmpty ? "" : rows.joined(separator: lineSeparator) + lineSeparator,
            stderr: "",
            exitCode: 0
        )
    }
}

private struct MSPFileOptions {
    var brief = false
    var mimeMode = MSPFileMimeMode.none
    var print0 = false
    var separator = ":"
    var filesFrom: [String] = []
    var probeByteLimit = mspPOSIXFileProbeByteLimit
}

private enum MSPFileMimeMode {
    case none
    case mime
    case mimeType
    case mimeEncoding
}

private func mspPOSIXFileDescription(
    path: String,
    info: MSPFileInfo,
    fileSystem: any MSPWorkspaceFileSystem,
    currentDirectory: String,
    mimeMode: MSPFileMimeMode,
    probeByteLimit: Int
) throws -> String {
    switch info.type {
    case .directory:
        return mspPOSIXFileDescription(
            plain: "directory",
            mimeType: "inode/directory",
            charset: "binary",
            mimeMode: mimeMode
        )
    case .symbolicLink:
        return mspPOSIXFileDescription(
            plain: "symbolic link",
            mimeType: "inode/symlink",
            charset: "binary",
            mimeMode: mimeMode
        )
    case .regularFile, .other:
        break
    }
    let data = try fileSystem.readFileRange(path, from: currentDirectory, offset: 0, length: probeByteLimit)
    let lowerName = MSPPOSIXCommandSupport.basename(info.virtualPath).lowercased()
    return mspPOSIXFileDescription(data: data, lowerName: lowerName, mimeMode: mimeMode, size: info.size)
}

private func mspPOSIXFileDescription(
    data: Data,
    lowerName: String,
    mimeMode: MSPFileMimeMode,
    size: Int64? = nil
) -> String {
    if (size ?? Int64(data.count)) == 0 {
        return mspPOSIXFileDescription(
            plain: "empty",
            mimeType: "inode/x-empty",
            charset: "binary",
            mimeMode: mimeMode
        )
    }
    if data.starts(with: Data("%PDF".utf8)) {
        return mspPOSIXFileDescription(
            plain: "PDF document",
            mimeType: "application/pdf",
            charset: "binary",
            mimeMode: mimeMode
        )
    }
    if data.count >= 3, data[0] == 0xff, data[1] == 0xd8, data[2] == 0xff {
        return mspPOSIXFileDescription(
            plain: "JPEG image data",
            mimeType: "image/jpeg",
            charset: "binary",
            mimeMode: mimeMode
        )
    }
    if data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) {
        if lowerName.hasSuffix(".docx") {
            return mspPOSIXFileDescription(
                plain: "Microsoft Word 2007+ document",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                charset: "binary",
                mimeMode: mimeMode
            )
        }
        return mspPOSIXFileDescription(
            plain: "Zip archive data",
            mimeType: "application/zip",
            charset: "binary",
            mimeMode: mimeMode
        )
    }
    if mspPOSIXContainsMP4FileTypeBox(data) {
        return mspPOSIXFileDescription(
            plain: "ISO Media, MP4 Base Media",
            mimeType: "video/mp4",
            charset: "binary",
            mimeMode: mimeMode
        )
    }
    if data.starts(with: Data("WEBVTT".utf8)) {
        return mspPOSIXFileDescription(
            plain: "WebVTT subtitle text",
            mimeType: "text/vtt",
            charset: "us-ascii",
            mimeMode: mimeMode
        )
    }
    if data.contains(0) {
        return mspPOSIXFileDescription(
            plain: "data",
            mimeType: "application/octet-stream",
            charset: "binary",
            mimeMode: mimeMode
        )
    }
    if lowerName.hasSuffix(".srt"), let text = String(data: data, encoding: .utf8) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first?.isNumber == true {
            return mspPOSIXFileDescription(
                plain: "SubRip subtitle text",
                mimeType: "text/plain",
                charset: mspPOSIXFileIsASCII(data) ? "us-ascii" : "utf-8",
                mimeMode: mimeMode
            )
        }
    }
    if String(data: data, encoding: .utf8) != nil {
        let isASCII = mspPOSIXFileIsASCII(data)
        let lineTerminated = data.contains(0x0a) || data.contains(0x0d)
        var plain = isASCII ? "ASCII text" : "Unicode text, UTF-8 text"
        if !lineTerminated {
            plain += ", with no line terminators"
        }
        return mspPOSIXFileDescription(
            plain: plain,
            mimeType: "text/plain",
            charset: isASCII ? "us-ascii" : "utf-8",
            mimeMode: mimeMode
        )
    }
    return mspPOSIXFileDescription(
        plain: data.count < 4 ? "very short file (no magic)" : "data",
        mimeType: "application/octet-stream",
        charset: "binary",
        mimeMode: mimeMode
    )
}

private let mspPOSIXFileProbeByteLimit = 4096

private func mspPOSIXFileDescription(
    plain: String,
    mimeType: String,
    charset: String,
    mimeMode: MSPFileMimeMode
) -> String {
    switch mimeMode {
    case .none:
        return plain
    case .mime:
        return "\(mimeType); charset=\(charset)"
    case .mimeType:
        return mimeType
    case .mimeEncoding:
        return charset
    }
}

private func mspFileFormatRow(path: String, description: String, options: MSPFileOptions) -> String {
    if options.print0 {
        return path + "\0" + options.separator + " " + description
    }
    return path + options.separator + " " + description
}

private let mspFileKnownExcludeTests: Set<String> = [
    "apptype",
    "ascii",
    "cdf",
    "compress",
    "csv",
    "elf",
    "encoding",
    "json",
    "soft",
    "tar",
    "text",
    "tokens"
]

private func mspFileProbeLimit(from parameter: String) -> Int? {
    let pieces = parameter.split(separator: "=", maxSplits: 1).map(String.init)
    guard pieces.count == 2, pieces[0] == "bytes", let value = Int(pieces[1]), value > 0 else {
        return nil
    }
    return min(value, mspPOSIXFileProbeByteLimit)
}

private func mspFileOperandsFromList(
    _ path: String,
    context: MSPCommandContext,
    fileSystem: any MSPWorkspaceFileSystem
) throws -> [String] {
    let data = path == "-"
        ? try MSPPOSIXCommandSupport.standardInputData(from: context)
        : try fileSystem.readFile(path, from: context.currentDirectory)
    guard let text = String(data: data, encoding: .utf8) else {
        throw MSPWorkspaceFileSystemError.encodingFailed(path)
    }
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

private func mspFileUsage() -> String {
    """
    Usage: file [OPTION...] [FILE...]
    Classify virtual workspace file contents with a bounded MSP classifier.

    """
}

private func mspPOSIXFileIsASCII(_ data: Data) -> Bool {
    data.allSatisfy { $0 < 0x80 }
}

private func mspPOSIXContainsMP4FileTypeBox(_ data: Data) -> Bool {
    guard data.count >= 8 else {
        return false
    }
    let marker = Data("ftyp".utf8)
    let upperBound = min(data.count - marker.count, 64)
    guard upperBound >= 0 else {
        return false
    }
    for offset in 0...upperBound where data.subdata(in: offset..<(offset + marker.count)) == marker {
        return true
    }
    return false
}
