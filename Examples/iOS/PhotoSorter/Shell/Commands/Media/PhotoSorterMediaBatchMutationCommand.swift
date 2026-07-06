import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    func runTrash(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        guard let assetTrashBatcher else {
            return .failure(stderr: "media trash: trash batching is unavailable\n")
        }
        let parsed: PhotoSorterMediaPathListArguments
        do {
            parsed = try Self.parsePathListArguments(
                arguments,
                commandName: "media trash",
                defaultLimit: nil,
                allowsInlinePaths: false
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media trash: \(error)")
        }
        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsed.rawPaths,
                fromFile: parsed.pathListFile,
                limit: parsed.limit,
                commandName: "media trash",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media trash: \(error)\n")
        }
        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        if let invalidPath = paths.first(where: { !Self.isTrashableMediaPath($0) }) {
            return .failure(stderr: "media trash: expected a photo or video path under /图库 or /相册, got \(invalidPath)\n")
        }
        do {
            let summary = try assetTrashBatcher.trashPhotoSorterAssets(at: paths)
            let missingFragment = summary.missing > 0 ? ", missing \(summary.missing)" : ""
            return .success(stdout: "media trash: trashed \(summary.trashed)\(missingFragment), requested \(summary.requested)\n")
        } catch {
            return .failure(stderr: "media trash: \(error)\n")
        }
    }

    func runRestore(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        guard let assetTrashRestorer else {
            return .failure(stderr: "media restore: trash restore is unavailable\n")
        }
        let parsed: PhotoSorterMediaPathListArguments
        do {
            parsed = try Self.parsePathListArguments(
                arguments,
                commandName: "media restore",
                defaultLimit: nil,
                allowsInlinePaths: false
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media restore: \(error)")
        }
        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsed.rawPaths,
                fromFile: parsed.pathListFile,
                limit: parsed.limit,
                commandName: "media restore",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media restore: \(error)\n")
        }
        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        if let invalidPath = paths.first(where: { !Self.isRestorableTrashPath($0) }) {
            return .failure(stderr: "media restore: expected a /最近删除 path, got \(invalidPath)\n")
        }
        do {
            let summary = try assetTrashRestorer.restorePhotoSorterTrash(at: paths)
            let missingFragment = summary.missing > 0 ? ", missing \(summary.missing)" : ""
            return .success(stdout: "media restore: restored \(summary.restored)\(missingFragment), requested \(summary.requested)\n")
        } catch {
            return .failure(stderr: "media restore: \(error)\n")
        }
    }
}
