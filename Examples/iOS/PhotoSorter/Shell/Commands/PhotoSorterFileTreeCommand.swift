import Foundation
import ModelShellProxy
import MSPCore

struct PhotoSorterFileTreeCommand: MSPCommand {
    let name = "filetree"
    let summary: String? = "Print the current PhotoSorter workspace tree snapshot."

    private let snapshotProvider: any PhotoSorterFileTreeSnapshotProviding

    init(snapshotProvider: any PhotoSorterFileTreeSnapshotProviding) {
        self.snapshotProvider = snapshotProvider
    }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let help = Self.help.result(for: invocation.arguments) {
            return help
        }
        guard let subcommand = invocation.arguments.first else {
            return usageFailure(Self.rootUsageError)
        }
        switch subcommand {
        case "ls":
            return runList(arguments: Array(invocation.arguments.dropFirst()))
        default:
            return usageFailure("filetree: unsupported subcommand \(subcommand)\nTry 'filetree help' for more information.")
        }
    }

    private func runList(arguments: [String]) -> MSPCommandResult {
        let parsedArguments: PhotoSorterFileTreeListArguments
        do {
            parsedArguments = try parseListArguments(arguments)
        } catch let error as PhotoSorterFileTreeUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure(Self.listUsageError)
        }
        return .success(stdout: snapshotProvider.photoSorterFileTreeSnapshot(
            rootPath: parsedArguments.rootPath,
            maxUserAlbums: parsedArguments.maxUserAlbums
        ) + "\n")
    }

    private func parseListArguments(_ arguments: [String]) throws -> PhotoSorterFileTreeListArguments {
        var rootPath: String?
        var maxUserAlbums = PhotoSorterFileTreeCommand.defaultMaxUserAlbums
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--limit" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw PhotoSorterFileTreeUsageError(message: "filetree ls: --limit requires a value\nTry 'filetree help ls' for more information.")
                }
                maxUserAlbums = try parseLimit(arguments[valueIndex])
                index += 2
                continue
            }
            if argument.hasPrefix("--limit=") {
                maxUserAlbums = try parseLimit(String(argument.dropFirst("--limit=".count)))
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                throw PhotoSorterFileTreeUsageError(message: "filetree ls: unsupported option \(argument)\nTry 'filetree help ls' for more information.")
            }
            guard rootPath == nil else {
                throw PhotoSorterFileTreeUsageError(message: "filetree ls: too many path operands\nTry 'filetree help ls' for more information.")
            }
            rootPath = argument
            index += 1
        }
        return PhotoSorterFileTreeListArguments(
            rootPath: rootPath ?? "/",
            maxUserAlbums: maxUserAlbums
        )
    }

    private func parseLimit(_ value: String) throws -> Int {
        guard let limit = Int(value), limit >= 0 else {
            throw PhotoSorterFileTreeUsageError(message: "filetree ls: invalid --limit value \(value)\nTry 'filetree help ls' for more information.")
        }
        return limit
    }

    private func usageFailure(_ message: String) -> MSPCommandResult {
        .failure(exitCode: 2, stderr: message.hasSuffix("\n") ? message : message + "\n")
    }

    private static let defaultMaxUserAlbums = 300

    private static let rootUsageError = """
    filetree: usage: filetree ls [path] [--limit N]
    Try 'filetree help' for more information.
    """

    private static let listUsageError = """
    filetree ls: usage: filetree ls [path] [--limit N]
    Try 'filetree help ls' for more information.
    """

    private static let rootHelp = """
    filetree

    Usage:
      filetree ls [path] [--limit N]

    Help:
      filetree help ls
    """

    private static let listHelp = """
    filetree ls

    Usage:
      filetree ls [path] [--limit N]

    Description:
      Print the current PhotoSorter workspace tree snapshot.
      When path is provided, print the same cheap tree snapshot rooted at that workspace path.
      This reuses the same shape as the current workspace tree injected into the prompt.
      Counts come from the PhotoSorter cached index and workspace overlay; this is not a recursive filesystem walk and does not enumerate every photo in large albums.
      Use this before inspecting album names, album counts, empty albums, or broad source scopes.

    Example:
      filetree ls
      filetree ls /相册/用户
      filetree ls --limit 500
    """

    private static let help = MSPCommandHelp(
        commandName: "filetree",
        root: rootHelp,
        topics: [
            "ls": listHelp
        ]
    )
}

private struct PhotoSorterFileTreeUsageError: Error {
    var message: String
}

private struct PhotoSorterFileTreeListArguments {
    var rootPath: String
    var maxUserAlbums: Int
}
