import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func listDirectory(
        _ path: String,
        from currentDirectory: String = "/"
    ) throws -> [MSPDirectoryEntry] {
        try listDirectory(path, from: currentDirectory, offset: 0, limit: nil)
    }

    public func listDirectory(
        _ path: String,
        from currentDirectory: String = "/",
        offset: Int,
        limit: Int?
    ) throws -> [MSPDirectoryEntry] {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            return slice(
                try listTrash(virtualPath),
                offset: offset,
                limit: limit
            )
        }
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        let info = try fileInfo(virtualPath: resolvedURL.resolved.virtualPath, url: resolvedURL.url)
        guard info.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(resolvedURL.resolved.virtualPath)
        }

        do {
            let entries = try lightweightDirectoryEntries(
                parentVirtualPath: resolvedURL.resolved.virtualPath,
                parentURL: resolvedURL.url,
                operation: "list"
            )
            return try pagedDirectoryEntries(
                entries,
                parentVirtualPath: resolvedURL.resolved.virtualPath,
                parentURL: resolvedURL.url,
                offset: offset,
                limit: limit
            )
        } catch let error as MSPWorkspaceFileSystemError {
            throw error
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "list"
            )
        }
    }

    private func pagedDirectoryEntries(
        _ entries: [MSPDirectoryEntry],
        parentVirtualPath: String,
        parentURL: URL,
        offset: Int,
        limit: Int?
    ) throws -> [MSPDirectoryEntry] {
        var lightweightEntries = entries
        try lightweightEntries.append(contentsOf: trashDisplayEntries(in: parentVirtualPath))

        return try slice(
            policy.directoryOrdering.ordered(lightweightEntries),
            offset: offset,
            limit: limit
        ).map { entry in
            if isTrashDisplayPath(entry.virtualPath) {
                return entry
            }
            let childURL = parentURL.appendingPathComponent(entry.name)
            let childInfo = try fileInfo(virtualPath: entry.virtualPath, url: childURL)
            return MSPDirectoryEntry(name: entry.name, info: childInfo)
        }
    }

    private func slice<T>(
        _ entries: [T],
        offset: Int,
        limit: Int?
    ) -> [T] {
        let startIndex = min(max(offset, 0), entries.count)
        let endIndex = limit.map { min(startIndex + max($0, 0), entries.count) } ?? entries.count
        return Array(entries[startIndex..<endIndex])
    }

    public func enumerateDirectory(
        _ path: String,
        from currentDirectory: String = "/",
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        try await enumerateDirectory(
            path,
            from: currentDirectory,
            options: .all,
            visitor: visitor
        )
    }

    public func enumerateDirectory(
        _ path: String,
        from currentDirectory: String = "/",
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            for entry in try listTrash(virtualPath) where options.includes(entry.type) {
                guard try await visitor(entry) else {
                    return
                }
            }
            return
        }

        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        let info = try fileInfo(virtualPath: resolvedURL.resolved.virtualPath, url: resolvedURL.url)
        guard info.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(resolvedURL.resolved.virtualPath)
        }

        let entries = try lightweightDirectoryEntries(
            parentVirtualPath: resolvedURL.resolved.virtualPath,
            parentURL: resolvedURL.url,
            operation: "enumerate"
        )
        for entry in policy.directoryOrdering.ordered(entries) {
            let childURL = resolvedURL.url.appendingPathComponent(entry.name)
            let childInfo = try fileInfo(virtualPath: entry.virtualPath, url: childURL)
            guard options.includes(childInfo.type) else {
                continue
            }
            let typedEntry = MSPDirectoryEntry(name: entry.name, info: childInfo)
            guard try await visitor(typedEntry) else {
                return
            }
        }

        for entry in try trashDisplayEntries(in: resolvedURL.resolved.virtualPath) where options.includes(entry.type) {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    public func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String = "/",
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        batch.reserveCapacity(resolvedBatchSize)
        var shouldContinue = true
        try await enumerateDirectory(
            path,
            from: currentDirectory,
            options: options
        ) { entry in
            batch.append(entry)
            if batch.count >= resolvedBatchSize {
                shouldContinue = try await visitor(batch)
                batch.removeAll(keepingCapacity: true)
            }
            return shouldContinue
        }
        if shouldContinue, !batch.isEmpty {
            _ = try await visitor(batch)
        }
    }

    private func lightweightDirectoryEntries(
        parentVirtualPath: String,
        parentURL: URL,
        operation: String
    ) throws -> [MSPDirectoryEntry] {
        do {
            return try FileManager.default
                .contentsOfDirectory(
                    at: parentURL,
                    includingPropertiesForKeys: directoryEntryResourceKeys,
                    options: [.skipsSubdirectoryDescendants]
                )
                .compactMap { childURL -> MSPDirectoryEntry? in
                    let name = childURL.lastPathComponent
                    let childVirtualPath = joinVirtualPath(
                        parent: parentVirtualPath,
                        child: name
                    )
                    guard !policy.isHidden(childVirtualPath) else {
                        return nil
                    }
                    return MSPDirectoryEntry(
                        name: name,
                        info: MSPFileInfo(
                            virtualPath: childVirtualPath,
                            type: .other
                        )
                    )
                }
        } catch let error as MSPWorkspaceFileSystemError {
            throw error
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: parentVirtualPath,
                operation: operation
            )
        }
    }
}
