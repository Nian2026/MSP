import Foundation
import ModelShellProxy
import MSPCore

struct PhotoSorterAlbumCommand: MSPCommand {
    let name = "album"
    let summary: String? = "Manage user albums without deleting photo assets."

    private let albumManager: any PhotoSorterAlbumManaging

    init(albumManager: any PhotoSorterAlbumManaging) {
        self.albumManager = albumManager
    }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let help = Self.help.result(for: invocation.arguments) {
            return help
        }
        guard let subcommand = invocation.arguments.first else {
            return usageFailure("album: usage: album add|remove|rm ...\nTry 'album help' for more information.")
        }
        switch subcommand {
        case "add":
            return runAddAssetsToAlbum(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "remove":
            return runRemoveAssetsFromAlbum(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "rm":
            return runRemoveAlbumContainer(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        default:
            return usageFailure("album: unsupported subcommand \(subcommand)\nTry 'album help' for more information.")
        }
    }

    private func runAddAssetsToAlbum(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        let parsed: PhotoSorterAlbumAddArguments
        do {
            parsed = try parseAddArguments(arguments)
        } catch let error as PhotoSorterAlbumUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure(Self.addUsageError)
        }

        var assetPaths = parsed.assetPaths
        if let pathListFile = parsed.pathListFile {
            guard let fileSystem = context.workspace?.fileSystem else {
                return .failure(exitCode: 125, stderr: "album add: workspace is required\n")
            }
            let normalizedListPath = normalizedPath(pathListFile, from: context.currentDirectory)
            guard !isPhotoLibraryVirtualPath(normalizedListPath) else {
                return .failure(
                    exitCode: 1,
                    stderr: "album add: --from-file expects a text path list outside /图库, /相册, or /最近删除\n"
                )
            }
            do {
                let data = try fileSystem.readFile(pathListFile, from: context.currentDirectory)
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure(exitCode: 1, stderr: "album add: \(pathListFile): invalid UTF-8\n")
                }
                assetPaths = text
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .filter { !$0.isEmpty }
            } catch {
                return .failure(stderr: "album add: \(pathListFile): \(error)\n")
            }
        }

        let albumPath = normalizedPath(parsed.albumPath, from: context.currentDirectory)
        let normalizedAssetPaths = assetPaths.map { normalizedPath($0, from: context.currentDirectory) }
        do {
            let summary = try albumManager.addPhotoSorterAssets(
                at: normalizedAssetPaths,
                toAlbumPath: albumPath,
                createAlbumIfNeeded: parsed.createAlbumIfNeeded
            )
            return .success(
                stdout: "album add: added \(summary.added), skipped_existing \(summary.skippedExisting), requested \(summary.requested), album \(albumPath)\n"
            )
        } catch {
            return .failure(stderr: "album add: \(albumPath): \(error)\n")
        }
    }

    private func runRemoveAssetsFromAlbum(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        let parsed: PhotoSorterAlbumRemoveArguments
        do {
            parsed = try parseRemoveArguments(arguments)
        } catch let error as PhotoSorterAlbumUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure(Self.removeUsageError)
        }

        var assetPaths = parsed.assetPaths
        if let pathListFile = parsed.pathListFile {
            guard let fileSystem = context.workspace?.fileSystem else {
                return .failure(exitCode: 125, stderr: "album remove: workspace is required\n")
            }
            let normalizedListPath = normalizedPath(pathListFile, from: context.currentDirectory)
            guard !isPhotoLibraryVirtualPath(normalizedListPath) else {
                return .failure(
                    exitCode: 1,
                    stderr: "album remove: --from-file expects a text path list outside /图库, /相册, or /最近删除\n"
                )
            }
            do {
                let data = try fileSystem.readFile(pathListFile, from: context.currentDirectory)
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure(exitCode: 1, stderr: "album remove: \(pathListFile): invalid UTF-8\n")
                }
                assetPaths = text
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .filter { !$0.isEmpty }
            } catch {
                return .failure(stderr: "album remove: \(pathListFile): \(error)\n")
            }
        }

        let albumPath = normalizedPath(parsed.albumPath, from: context.currentDirectory)
        let normalizedAssetPaths = assetPaths.map { normalizedPath($0, from: context.currentDirectory) }
        do {
            let summary = try albumManager.removePhotoSorterAssets(
                at: normalizedAssetPaths,
                fromAlbumPath: albumPath
            )
            return .success(
                stdout: "album remove: removed \(summary.removed), skipped_not_in_album \(summary.skippedNotInAlbum), requested \(summary.requested), album \(albumPath)\n"
            )
        } catch {
            return .failure(stderr: "album remove: \(albumPath): \(error)\n")
        }
    }

    private func runRemoveAlbumContainer(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        let parsed: PhotoSorterAlbumRmArguments
        do {
            parsed = try parseRmArguments(arguments)
        } catch let error as PhotoSorterAlbumUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure(Self.rmUsageError)
        }

        var rawPaths = parsed.albumPaths
        if let pathListFile = parsed.pathListFile {
            guard let fileSystem = context.workspace?.fileSystem else {
                return .failure(exitCode: 125, stderr: "album rm: workspace is required\n")
            }
            let normalizedListPath = normalizedPath(pathListFile, from: context.currentDirectory)
            guard !isPhotoLibraryVirtualPath(normalizedListPath) else {
                return .failure(
                    exitCode: 1,
                    stderr: "album rm: --from-file expects a text path list outside /图库, /相册, or /最近删除\n"
                )
            }
            do {
                let data = try fileSystem.readFile(pathListFile, from: context.currentDirectory)
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure(exitCode: 1, stderr: "album rm: \(pathListFile): invalid UTF-8\n")
                }
                rawPaths.append(contentsOf: text
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
            } catch {
                return .failure(stderr: "album rm: \(pathListFile): \(error)\n")
            }
        }

        var seen = Set<String>()
        let paths = rawPaths
            .map { normalizedPath($0, from: context.currentDirectory) }
            .filter { seen.insert($0).inserted }

        guard !paths.isEmpty else {
            return usageFailure(Self.rmUsageError)
        }

        if paths.count == 1, let path = paths.first {
            do {
                try albumManager.deletePhotoSorterUserAlbumContainer(at: path)
                return .success(stdout: "album rm: marked \(path) for album deletion without deleting contained photos\n")
            } catch {
                return .failure(stderr: "album rm: \(path): \(error)\n")
            }
        }

        var removedCount = 0
        var stderr = ""
        for path in paths {
            do {
                try albumManager.deletePhotoSorterUserAlbumContainer(at: path)
                removedCount += 1
            } catch {
                stderr += "album rm: \(path): \(error)\n"
            }
        }

        let stdout = removedCount > 0
            ? "album rm: marked \(removedCount) album containers for album deletion without deleting contained photos\n"
            : ""
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: stderr.isEmpty ? 0 : 1)
    }

    private func parseAddArguments(_ arguments: [String]) throws -> PhotoSorterAlbumAddArguments {
        var createAlbumIfNeeded = false
        var pathListFile: String?
        var operands: [String] = []
        var parsingOptions = true
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard parsingOptions else {
                operands.append(argument)
                continue
            }
            if argument == "--" {
                parsingOptions = false
                continue
            }
            if argument == "--create" {
                createAlbumIfNeeded = true
                continue
            }
            if argument == "--from-file" {
                guard index < arguments.count else {
                    throw PhotoSorterAlbumUsageError(message: Self.addUsageError)
                }
                pathListFile = arguments[index]
                index += 1
                continue
            }
            if argument.hasPrefix("--from-file=") {
                let value = String(argument.dropFirst("--from-file=".count))
                guard !value.isEmpty else {
                    throw PhotoSorterAlbumUsageError(message: Self.addUsageError)
                }
                pathListFile = value
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                throw PhotoSorterAlbumUsageError(
                    message: "album add: unsupported option \(argument)\nTry 'album help add' for more information."
                )
            }
            operands.append(argument)
        }

        if pathListFile != nil {
            guard operands.count == 1, let albumPath = operands.first else {
                throw PhotoSorterAlbumUsageError(message: Self.addUsageError)
            }
            return PhotoSorterAlbumAddArguments(
                albumPath: albumPath,
                assetPaths: [],
                pathListFile: pathListFile,
                createAlbumIfNeeded: createAlbumIfNeeded
            )
        }

        guard operands.count >= 2 else {
            throw PhotoSorterAlbumUsageError(message: Self.addUsageError)
        }
        return PhotoSorterAlbumAddArguments(
            albumPath: operands[0],
            assetPaths: Array(operands.dropFirst()),
            pathListFile: nil,
            createAlbumIfNeeded: createAlbumIfNeeded
        )
    }

    private func parseRemoveArguments(_ arguments: [String]) throws -> PhotoSorterAlbumRemoveArguments {
        var pathListFile: String?
        var operands: [String] = []
        var parsingOptions = true
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard parsingOptions else {
                operands.append(argument)
                continue
            }
            if argument == "--" {
                parsingOptions = false
                continue
            }
            if argument == "--from-file" {
                guard index < arguments.count else {
                    throw PhotoSorterAlbumUsageError(message: Self.removeUsageError)
                }
                pathListFile = arguments[index]
                index += 1
                continue
            }
            if argument.hasPrefix("--from-file=") {
                let value = String(argument.dropFirst("--from-file=".count))
                guard !value.isEmpty else {
                    throw PhotoSorterAlbumUsageError(message: Self.removeUsageError)
                }
                pathListFile = value
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                throw PhotoSorterAlbumUsageError(
                    message: "album remove: unsupported option \(argument)\nTry 'album help remove' for more information."
                )
            }
            operands.append(argument)
        }

        if pathListFile != nil {
            guard operands.count == 1, let albumPath = operands.first else {
                throw PhotoSorterAlbumUsageError(message: Self.removeUsageError)
            }
            return PhotoSorterAlbumRemoveArguments(
                albumPath: albumPath,
                assetPaths: [],
                pathListFile: pathListFile
            )
        }

        guard operands.count >= 2 else {
            throw PhotoSorterAlbumUsageError(message: Self.removeUsageError)
        }
        return PhotoSorterAlbumRemoveArguments(
            albumPath: operands[0],
            assetPaths: Array(operands.dropFirst()),
            pathListFile: nil
        )
    }

    private func parseRmArguments(_ arguments: [String]) throws -> PhotoSorterAlbumRmArguments {
        var pathListFile: String?
        var operands: [String] = []
        var parsingOptions = true
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard parsingOptions else {
                operands.append(argument)
                continue
            }
            if argument == "--" {
                parsingOptions = false
                continue
            }
            if argument == "--from-file" {
                guard index < arguments.count else {
                    throw PhotoSorterAlbumUsageError(message: Self.rmUsageError)
                }
                pathListFile = arguments[index]
                index += 1
                continue
            }
            if argument.hasPrefix("--from-file=") {
                let value = String(argument.dropFirst("--from-file=".count))
                guard !value.isEmpty else {
                    throw PhotoSorterAlbumUsageError(message: Self.rmUsageError)
                }
                pathListFile = value
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                throw PhotoSorterAlbumUsageError(
                    message: "album rm: unsupported option \(argument)\nTry 'album help rm' for more information."
                )
            }
            operands.append(argument)
        }

        guard pathListFile != nil || !operands.isEmpty else {
            throw PhotoSorterAlbumUsageError(message: Self.rmUsageError)
        }
        return PhotoSorterAlbumRmArguments(albumPaths: operands, pathListFile: pathListFile)
    }

    private func normalizedPath(_ path: String, from currentDirectory: String) -> String {
        if path.hasPrefix("/") {
            return PhotoLibraryMount.normalizeVirtualPath(path)
        }
        let base = currentDirectory == "/" ? "" : currentDirectory
        return PhotoLibraryMount.normalizeVirtualPath(base + "/" + path)
    }

    private func isPhotoLibraryVirtualPath(_ path: String) -> Bool {
        path == "/图库"
            || path.hasPrefix("/图库/")
            || path == "/相册"
            || path.hasPrefix("/相册/")
            || path == "/最近删除"
            || path.hasPrefix("/最近删除/")
    }

    private func usageFailure(_ message: String) -> MSPCommandResult {
        .failure(exitCode: 2, stderr: message.hasSuffix("\n") ? message : message + "\n")
    }

    private static let addUsageError = """
    album add: usage: album add [--create] <user-album-path> <photo-path>...
           album add [--create] --from-file <path-list> <user-album-path>
    Try 'album help add' for more information.
    """

    private static let removeUsageError = """
    album remove: usage: album remove <user-album-path> <photo-path>...
           album remove --from-file <path-list> <user-album-path>
    Try 'album help remove' for more information.
    """

    private static let rmUsageError = """
    album rm: usage: album rm <user-album-path>...
           album rm --from-file <path-list>
    Try 'album help rm' for more information.
    """

    private static let rootHelp = """
    album

    Usage:
      album add [--create] <user-album-path> <photo-path>...
      album add [--create] --from-file <path-list> <user-album-path>
      album remove <user-album-path> <photo-path>...
      album remove --from-file <path-list> <user-album-path>
      album rm <user-album-path>...
      album rm --from-file <path-list>

    Help:
      album help add
      album help remove
      album help rm
    """

    private static let addHelp = """
    album add

    Usage:
      album add [--create] <user-album-path> <photo-path>...
      album add [--create] --from-file <path-list> <user-album-path>

    Description:
      Add existing photo or video references to a user album under /相册/用户.
      This does not duplicate image bodies or modify the original files in /图库.
      With --from-file, <path-list> is a UTF-8 text file outside /图库, /相册, and /最近删除,
      with one photo path per line.

    Example:
      album add --create --from-file /tmp/low_value_paths.txt /相册/用户/待删除-低价值截图候选
    """

    private static let removeHelp = """
    album remove

    Usage:
      album remove <user-album-path> <photo-path>...
      album remove --from-file <path-list> <user-album-path>

    Description:
      Remove selected photo or video references from a user album under /相册/用户.
      This keeps the assets in /图库 and keeps any memberships in other albums.
      With --from-file, <path-list> is a UTF-8 text file outside /图库, /相册, and /最近删除,
      with one photo path per line.

    Example:
      album remove --from-file /tmp/selected_from_album.txt /相册/用户/旅行
    """

    private static let rmHelp = """
    album rm

    Usage:
      album rm <user-album-path>...
      album rm --from-file <path-list>

    Description:
      Remove a user album container under /相册/用户.
      This does not delete the photo assets inside the album.
      With --from-file, <path-list> is a UTF-8 text file outside /图库, /相册, and /最近删除,
      with one user album path per line.

    Examples:
      album rm /相册/用户/待删除截图-最旧50张
      album rm --from-file /tmp/empty_user_albums.txt
    """

    private static let help = MSPCommandHelp(
        commandName: "album",
        root: rootHelp,
        topics: [
            "add": addHelp,
            "remove": removeHelp,
            "rm": rmHelp
        ]
    )
}

private struct PhotoSorterAlbumAddArguments {
    var albumPath: String
    var assetPaths: [String]
    var pathListFile: String?
    var createAlbumIfNeeded: Bool
}

private struct PhotoSorterAlbumRemoveArguments {
    var albumPath: String
    var assetPaths: [String]
    var pathListFile: String?
}

private struct PhotoSorterAlbumRmArguments {
    var albumPaths: [String]
    var pathListFile: String?
}

private struct PhotoSorterAlbumUsageError: Error {
    var message: String
}
