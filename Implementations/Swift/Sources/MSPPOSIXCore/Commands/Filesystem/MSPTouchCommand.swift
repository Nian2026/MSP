import Foundation
import MSPCore

public struct MSPTouchCommand: MSPCommand {
    public let name = "touch"
    public let summary: String? = "Update file timestamps or create empty files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["a", "c", "f", "h", "m"],
            allowedLongOptions: ["no-create", "no-dereference"],
            shortOptionsRequiringValue: ["d", "r", "t"],
            longOptionsRequiringValue: ["date", "reference", "time"]
        )
        let parsed = try spec.parse(invocation.arguments)
        guard !parsed.operands.isEmpty else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "touch: missing file operand\nTry 'touch --help' for more information.\n"
                )
            )
        }
        let noCreate = parsed.options.contains { option in
            option.matches(short: "c") || option.matches(long: "no-create")
        }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let requestedDate = try requestedModificationDate(
            from: parsed.options,
            fileSystem: fileSystem,
            currentDirectory: context.currentDirectory
        )

        var diagnostics: [String] = []
        for path in parsed.operands {
            do {
                if noCreate {
                    do {
                        _ = try fileSystem.stat(path, from: context.currentDirectory)
                    } catch MSPWorkspaceFileSystemError.notFound {
                        continue
                    }
                }
                try fileSystem.touch(
                    path,
                    from: context.currentDirectory,
                    creationMode: context.regularFileCreationMode
                )
                if let requestedDate {
                    try setModificationDateIfSupported(
                        requestedDate,
                        path: path,
                        fileSystem: fileSystem,
                        currentDirectory: context.currentDirectory
                    )
                }
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(path)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("touch: cannot touch '\(displayPath)': \(reason)")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success()
    }

    private func requestedModificationDate(
        from options: [MSPPOSIXOption],
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> Date? {
        var dateArgument: String?
        var referencePath: String?

        for option in options {
            switch option.name {
            case .short("d"), .long("date"):
                dateArgument = option.value
            case .short("r"), .long("reference"):
                referencePath = option.value
            case .short("t"):
                if let value = option.value {
                    guard let date = Self.date(fromPOSIXTimestamp: value) else {
                        throw MSPCommandFailure(
                            result: .failure(
                                stderr: "touch: invalid date format '\(MSPPOSIXCommandSupport.displayPath(value))'\n"
                            )
                        )
                    }
                    return date
                }
            default:
                continue
            }
        }

        if let referencePath {
            do {
                let info = try fileSystem.stat(referencePath, from: currentDirectory)
                return info.modificationDate ?? Date(timeIntervalSince1970: 0)
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(referencePath)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                throw MSPCommandFailure(
                    result: .failure(
                        stderr: "touch: failed to get attributes of '\(displayPath)': \(reason)\n"
                    )
                )
            }
        }

        guard let dateArgument else {
            return nil
        }
        guard let date = Self.date(fromGNUDateArgument: dateArgument) else {
            throw MSPCommandFailure(
                result: .failure(
                    stderr: "touch: invalid date format '\(MSPPOSIXCommandSupport.displayPath(dateArgument))'\n"
                )
            )
        }
        return date
    }

    private func setModificationDateIfSupported(
        _ date: Date,
        path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws {
        let resolved = try fileSystem.resolve(path, from: currentDirectory)
        guard let physicalPath = resolved.physicalPath else {
            return
        }
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: physicalPath
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(path: resolved.virtualPath, operation: "touch")
        }
    }

    private static func date(fromGNUDateArgument argument: String) -> Date? {
        if argument.hasPrefix("@") {
            let secondsText = String(argument.dropFirst())
            guard let seconds = TimeInterval(secondsText) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }
        if argument == "now" {
            return Date()
        }
        return nil
    }

    private static func date(fromPOSIXTimestamp stamp: String) -> Date? {
        let mainAndSeconds = stamp.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let main = String(mainAndSeconds[0])
        let seconds = mainAndSeconds.count == 2 ? String(mainAndSeconds[1]) : "00"
        guard main.count == 12 else {
            return nil
        }
        guard
            let year = Int(main.prefix(4)),
            let month = Int(main.dropFirst(4).prefix(2)),
            let day = Int(main.dropFirst(6).prefix(2)),
            let hour = Int(main.dropFirst(8).prefix(2)),
            let minute = Int(main.dropFirst(10).prefix(2)),
            let second = Int(seconds)
        else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date
    }
}
