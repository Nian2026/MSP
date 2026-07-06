import Foundation
import MSPCore

enum MSPPOSIXInputError: Error {
    case badFileDescriptor
}

enum MSPPOSIXCommandSupport {
    static func gnuStandardOptionResult(
        command: String,
        arguments: [String],
        helpText: String,
        versionText: String
    ) -> MSPCommandResult? {
        guard arguments.count == 1 else {
            return nil
        }
        switch arguments[0] {
        case "--help":
            return .success(stdout: helpText.hasSuffix("\n") ? helpText : helpText + "\n")
        case "--version":
            return .success(stdout: versionText.hasSuffix("\n") ? versionText : versionText + "\n")
        default:
            return nil
        }
    }

    static func gnuCoreutilsVersionText(command: String) -> String {
        "\(command) (GNU coreutils) 9.1\n"
    }

    static func workspaceFileSystem(
        from context: MSPCommandContext,
        command: String
    ) throws -> any MSPWorkspaceFileSystem {
        guard let workspace = context.workspace else {
            throw MSPCommandFailure(
                result: .failure(exitCode: 125, stderr: "\(command): workspace is required\n")
            )
        }
        return workspace.fileSystem
    }

    static func diagnosticReason(from error: Error) -> String {
        if case MSPPOSIXInputError.badFileDescriptor = error {
            return "Bad file descriptor"
        }
        guard let fileSystemError = error as? MSPWorkspaceFileSystemError else {
            return "\(error)"
        }
        switch fileSystemError {
        case .accessDenied, .hiddenPath:
            return "Permission denied"
        case .invalidPath:
            return "Invalid argument"
        case .notFound:
            return "No such file or directory"
        case .notDirectory:
            return "Not a directory"
        case .isDirectory:
            return "Is a directory"
        case .directoryNotEmpty:
            return "Directory not empty"
        case .notSymbolicLink:
            return "Invalid argument"
        case .alreadyExists:
            return "File exists"
        case .encodingFailed:
            return "Invalid or incomplete multibyte or wide character"
        case .io:
            return "Input/output error"
        }
    }

    static func displayPath(_ path: String) -> String {
        path.isEmpty ? "." : path
    }

    static func gnuQuote(_ value: String) -> String {
        "\u{2018}\(value)\u{2019}"
    }

    static func standardInputData(from context: MSPCommandContext) throws -> Data {
        guard !context.standardInputClosed else {
            throw MSPPOSIXInputError.badFileDescriptor
        }
        return context.standardInput
    }

    static func basename(_ virtualPath: String) -> String {
        let components = MSPWorkspacePathResolver.components(in: virtualPath)
        return components.last ?? "/"
    }

    static func joinPath(_ parent: String, child: String) -> String {
        parent == "/" ? "/" + child : parent + "/" + child
    }

    static func successWithTrailingNewline(_ text: String) -> MSPCommandResult {
        guard !text.isEmpty else {
            return .success()
        }
        return .success(stdout: text.hasSuffix("\n") ? text : text + "\n")
    }

    static func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes)B"
        }
        return String(format: "%.1f%@", value, units[index])
    }

    static func byteSize(_ info: MSPFileInfo) -> Int64 {
        if info.type == .directory {
            return 4096
        }
        return info.size ?? 0
    }

    static func mode(for info: MSPFileInfo) -> UInt16 {
        if info.type == .symbolicLink {
            return 0o777
        }
        if let permissions = info.permissions {
            return permissions & 0o777
        }
        switch info.type {
        case .directory:
            return 0o755
        case .symbolicLink:
            return 0o777
        case .regularFile, .other:
            return 0o644
        }
    }

    static func modeString(for info: MSPFileInfo) -> String {
        let fileType: String
        switch info.type {
        case .directory:
            fileType = "d"
        case .symbolicLink:
            fileType = "l"
        case .regularFile, .other:
            fileType = "-"
        }
        let mode = mode(for: info)
        let triplets: [(UInt16, UInt16, UInt16)] = [
            (0o400, 0o200, 0o100),
            (0o040, 0o020, 0o010),
            (0o004, 0o002, 0o001)
        ]
        let permissions = triplets.map { read, write, execute in
            [
                (mode & read) != 0 ? "r" : "-",
                (mode & write) != 0 ? "w" : "-",
                (mode & execute) != 0 ? "x" : "-"
            ].joined()
        }.joined()
        return fileType + permissions
    }

    static func modeOctalString(for info: MSPFileInfo) -> String {
        String(format: "%03o", mode(for: info) & 0o777)
    }

    static func typeDescription(for info: MSPFileInfo) -> String {
        switch info.type {
        case .directory:
            return "directory"
        case .symbolicLink:
            return "symbolic link"
        case .regularFile:
            return byteSize(info) == 0 ? "regular empty file" : "regular file"
        case .other:
            return "special file"
        }
    }
}
