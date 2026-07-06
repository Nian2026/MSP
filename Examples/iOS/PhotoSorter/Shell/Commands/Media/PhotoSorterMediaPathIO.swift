import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    func normalizedPath(_ path: String, from currentDirectory: String) -> String {
        if path.hasPrefix("/") {
            return PhotoLibraryMount.normalizeVirtualPath(path)
        }
        let base = currentDirectory == "/" ? "" : currentDirectory
        return PhotoLibraryMount.normalizeVirtualPath(base + "/" + path)
    }

    static func isPhotoLibraryVirtualPath(_ path: String) -> Bool {
        path == "/图库"
            || path.hasPrefix("/图库/")
            || path == "/相册"
            || path.hasPrefix("/相册/")
            || path == "/最近删除"
            || path.hasPrefix("/最近删除/")
    }

    static func isTrashableMediaPath(_ path: String) -> Bool {
        guard let parentPath = PhotoLibraryMount.parentPath(of: path) else {
            return false
        }
        if parentPath == "/图库" {
            return true
        }
        if PhotoLibraryMount.isSystemAlbumMediaDirectory(parentPath) {
            return true
        }
        return parentPath.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/")
    }

    static func isRestorableTrashPath(_ path: String) -> Bool {
        path.hasPrefix("/最近删除/")
    }

    func usageFailure(_ message: String) -> MSPCommandResult {
        .failure(exitCode: 2, stderr: message.hasSuffix("\n") ? message : message + "\n")
    }

    func readCommandPaths(
        _ inlinePaths: [String],
        fromFile pathListFile: String?,
        limit: Int?,
        commandName: String,
        context: MSPCommandContext
    ) throws -> [String] {
        var paths = inlinePaths
        if let pathListFile {
            guard let fileSystem = context.workspace?.fileSystem else {
                throw PhotoSorterMediaUsageError(message: "\(commandName): workspace is required")
            }
            let normalizedListPath = normalizedPath(pathListFile, from: context.currentDirectory)
            guard !Self.isPhotoLibraryVirtualPath(normalizedListPath) else {
                throw PhotoSorterMediaUsageError(
                    message: "\(commandName): --from-file expects a text path list outside /图库, /相册, or /最近删除"
                )
            }
            let data = try fileSystem.readFile(pathListFile, from: context.currentDirectory)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PhotoSorterMediaUsageError(message: "\(commandName): \(pathListFile): invalid UTF-8")
            }
            paths.append(contentsOf: text
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }
        guard !paths.isEmpty else {
            throw PhotoSorterMediaUsageError(message: "\(commandName): missing path operand")
        }
        if let limit {
            return Array(paths.prefix(max(0, limit)))
        }
        return paths
    }

    func readAskJSONL(
        _ jsonlFile: String,
        limit: Int?,
        commandName: String,
        context: MSPCommandContext
    ) throws -> (paths: [String], reasonsByPath: [String: PhotoSorterMediaAskReason]) {
        guard let fileSystem = context.workspace?.fileSystem else {
            throw PhotoSorterMediaUsageError(message: "\(commandName): workspace is required")
        }
        let normalizedJSONLPath = normalizedPath(jsonlFile, from: context.currentDirectory)
        guard !Self.isPhotoLibraryVirtualPath(normalizedJSONLPath) else {
            throw PhotoSorterMediaUsageError(
                message: "\(commandName): --from-jsonl expects a JSONL file outside /图库, /相册, or /最近删除"
            )
        }
        let data = try fileSystem.readFile(jsonlFile, from: context.currentDirectory)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PhotoSorterMediaUsageError(message: "\(commandName): \(jsonlFile): invalid UTF-8")
        }

        let inputLimit = limit.map { max(0, $0) }
        var paths: [String] = []
        var reasonsByPath: [String: PhotoSorterMediaAskReason] = [:]
        for (lineIndex, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            if let inputLimit, paths.count >= inputLimit {
                break
            }
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }
            let lineData = Data(line.utf8)
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: lineData)
            } catch {
                throw PhotoSorterMediaUsageError(
                    message: "\(commandName): \(jsonlFile): invalid JSON on line \(lineIndex + 1): \(error.localizedDescription)"
                )
            }
            guard let dictionary = object as? [String: Any] else {
                throw PhotoSorterMediaUsageError(
                    message: "\(commandName): \(jsonlFile): line \(lineIndex + 1) must be a JSON object"
                )
            }
            guard let rawPath = Self.jsonString(dictionary["path"]) else {
                throw PhotoSorterMediaUsageError(
                    message: "\(commandName): \(jsonlFile): line \(lineIndex + 1) missing string field path"
                )
            }
            let path = normalizedPath(rawPath, from: context.currentDirectory)
            let reason = PhotoSorterMediaAskReason(
                path: path,
                title: Self.jsonString(dictionary["title"]),
                confidence: Self.jsonString(dictionary["confidence"]),
                basis: Self.jsonStringArray(dictionary["basis"]),
                matchedTerms: Self.jsonStringArray(dictionary["matched_terms"]).isEmpty
                    ? Self.jsonStringArray(dictionary["matchedTerms"])
                    : Self.jsonStringArray(dictionary["matched_terms"]),
                risk: Self.jsonString(dictionary["risk"]),
                detail: Self.jsonString(dictionary["detail"])
            )
            paths.append(path)
            reasonsByPath[path] = reason
        }
        guard !paths.isEmpty else {
            throw PhotoSorterMediaUsageError(message: "\(commandName): missing path operand")
        }
        return (paths, reasonsByPath)
    }

    func writeAskPathLists(
        selectedPaths: [String],
        excludedPaths: [String],
        skippedPaths: [String],
        arguments: PhotoSorterMediaAskArguments,
        context: MSPCommandContext
    ) throws -> [PhotoSorterMediaAskWriteResult] {
        var results: [PhotoSorterMediaAskWriteResult] = []
        if let path = arguments.writeSelectedPath {
            results.append(try writeAskPathList(
                selectedPaths,
                to: path,
                option: "--write-selected",
                label: "selected",
                context: context
            ))
        }
        if let path = arguments.writeExcludedPath {
            results.append(try writeAskPathList(
                excludedPaths,
                to: path,
                option: "--write-excluded",
                label: "excluded",
                context: context
            ))
        }
        if let path = arguments.writeSkippedPath {
            results.append(try writeAskPathList(
                skippedPaths,
                to: path,
                option: "--write-skipped",
                label: "skipped",
                context: context
            ))
        }
        return results
    }

    func writeAskPathList(
        _ paths: [String],
        to outputPath: String,
        option: String,
        label: String,
        context: MSPCommandContext
    ) throws -> PhotoSorterMediaAskWriteResult {
        guard let fileSystem = context.workspace?.fileSystem else {
            throw PhotoSorterMediaUsageError(message: "media ask: \(option) requires a workspace")
        }
        let normalizedOutputPath = normalizedPath(outputPath, from: context.currentDirectory)
        guard !Self.isPhotoLibraryVirtualPath(normalizedOutputPath) else {
            throw PhotoSorterMediaUsageError(
                message: "media ask: \(option) expects a text path outside /图库, /相册, or /最近删除"
            )
        }
        let text = paths.isEmpty ? "" : paths.joined(separator: "\n") + "\n"
        try fileSystem.writeFile(
            outputPath,
            data: Data(text.utf8),
            from: context.currentDirectory,
            options: [.overwriteExisting, .createParentDirectories, .atomic]
        )
        return PhotoSorterMediaAskWriteResult(
            label: label,
            count: paths.count,
            path: normalizedOutputPath
        )
    }

    static func jsonString(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func jsonStringArray(_ value: Any?) -> [String] {
        if let values = value as? [Any] {
            return values.compactMap(jsonString)
        }
        if let string = jsonString(value) {
            return [string]
        }
        return []
    }
}
