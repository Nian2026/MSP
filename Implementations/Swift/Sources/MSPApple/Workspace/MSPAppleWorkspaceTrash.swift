import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func trashRecords() throws -> [MSPWorkspaceTrashRecord] {
        guard let trashConfiguration else {
            return []
        }
        let recordsURL = url(forVirtualPath: trashRecordsRootPath(in: trashConfiguration))
        guard FileManager.default.fileExists(atPath: recordsURL.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default
            .contentsOfDirectory(
                at: recordsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                try? decoder.decode(MSPWorkspaceTrashRecord.self, from: Data(contentsOf: url))
            }
            .sorted { first, second in
                if first.trashedAt == second.trashedAt {
                    return first.id < second.id
                }
                return first.trashedAt < second.trashedAt
            }
    }

    public func listTrash(_ path: String) throws -> [MSPDirectoryEntry] {
        let normalizedPath = MSPWorkspacePathResolver.normalize(path)
        guard isTrashDisplayPath(normalizedPath) else {
            throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
        }
        guard let trashConfiguration,
              let displayRootPath = trashConfiguration.displayRootPath else {
            throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
        }

        let records = try trashRecords()
        let displayIndex = MSPAppleWorkspaceTrashDisplayIndex(
            records: records,
            configuration: trashConfiguration
        )
        let info = try trashFileInfo(
            atDisplayPath: normalizedPath,
            records: records,
            displayIndex: displayIndex
        )
        guard info.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(normalizedPath)
        }
        if let record = trashRecord(
            containingDisplayPath: normalizedPath,
            records: records,
            displayIndex: displayIndex
        ),
           record.isDirectory {
            let recordDisplayPath = displayIndex.displayPath(for: record)
            let suffix = normalizedPath == recordDisplayPath
                ? ""
                : String(normalizedPath.dropFirst(recordDisplayPath.count))
            let backingPath = MSPWorkspacePathResolver.normalize(record.trashPath + suffix)
            let backingURL = url(forVirtualPath: backingPath)
            return try FileManager.default
                .contentsOfDirectory(
                    at: backingURL,
                    includingPropertiesForKeys: directoryEntryResourceKeys,
                    options: [.skipsSubdirectoryDescendants]
                )
                .map { childURL in
                    let childPath = joinVirtualPath(parent: normalizedPath, child: childURL.lastPathComponent)
                    return MSPDirectoryEntry(
                        name: childURL.lastPathComponent,
                        info: try fileInfo(virtualPath: childPath, url: childURL)
                    )
                }
                .sorted { $0.name < $1.name }
        }

        return try trashVirtualChildren(
            of: normalizedPath,
            displayRootPath: displayRootPath,
            records: records,
            displayIndex: displayIndex
        )
    }

    public func restoreTrash(
        _ paths: [String],
        from currentDirectory: String = "/",
        collisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy = .unique
    ) throws -> [MSPWorkspaceTrashRestoreSummary] {
        guard let trashConfiguration else {
            throw MSPWorkspaceFileSystemError.notFound("/")
        }
        let records = try trashRecords()
        let displayIndex = MSPAppleWorkspaceTrashDisplayIndex(
            records: records,
            configuration: trashConfiguration
        )
        var matched: [MSPWorkspaceTrashRecord] = []
        for rawPath in paths {
            let path = MSPWorkspacePathResolver.normalize(rawPath, from: currentDirectory)
            let matches = records.filter { record in
                record.originalPath == path
                    || record.trashPath == path
                    || displayIndex.displayPath(for: record) == path
            }
            guard !matches.isEmpty else {
                throw MSPWorkspaceFileSystemError.notFound(path)
            }
            for match in matches where !matched.contains(where: { $0.id == match.id }) {
                matched.append(match)
            }
        }

        var summaries: [MSPWorkspaceTrashRestoreSummary] = []
        for record in matched {
            let destinationPath = try restoreDestinationPath(
                for: record,
                collisionPolicy: collisionPolicy
            )
            let trashURL = url(forVirtualPath: record.trashPath)
            guard FileManager.default.fileExists(atPath: trashURL.path) else {
                throw MSPWorkspaceFileSystemError.notFound(record.trashPath)
            }
            let destinationURL = url(forVirtualPath: destinationPath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try FileManager.default.moveItem(at: trashURL, to: destinationURL)
                try? FileManager.default.removeItem(at: trashRecordURL(for: record))
                try? FileManager.default.removeItem(at: trashItemDirectoryURL(for: record))
            } catch {
                throw MSPWorkspaceFileSystemError.io(path: destinationPath, operation: "restore")
            }
            summaries.append(MSPWorkspaceTrashRestoreSummary(
                originalPath: record.originalPath,
                restoredPath: destinationPath,
                originalName: record.originalName,
                isDirectory: record.isDirectory
            ))
        }
        return summaries
    }

    public func emptyTrash(authorization: MSPWorkspaceTrashEmptyAuthorization) throws -> Int {
        _ = authorization
        guard let trashConfiguration else {
            return 0
        }
        let removedCount = try trashRecords().count
        let trashRootURL = url(forVirtualPath: trashConfiguration.storageRootPath)
        if FileManager.default.fileExists(atPath: trashRootURL.path) {
            do {
                try FileManager.default.removeItem(at: trashRootURL)
            } catch {
                throw MSPWorkspaceFileSystemError.io(
                    path: trashConfiguration.storageRootPath,
                    operation: "emptyTrash"
                )
            }
        }
        return removedCount
    }

    func moveToTrash(
        _ resolvedURL: (resolved: MSPResolvedPath, url: URL),
        isDirectory: Bool
    ) throws {
        guard let trashConfiguration else {
            throw MSPWorkspaceFileSystemError.accessDenied(resolvedURL.resolved.virtualPath)
        }
        let id = UUID().uuidString
        let originalName = MSPWorkspacePathResolver.components(in: resolvedURL.resolved.virtualPath).last
            ?? resolvedURL.url.lastPathComponent
        let itemDirectoryPath = joinVirtualPath(
            parent: trashItemsRootPath(in: trashConfiguration),
            child: id
        )
        let trashPath = joinVirtualPath(parent: itemDirectoryPath, child: originalName)
        let itemDirectoryURL = url(forVirtualPath: itemDirectoryPath)
        let trashURL = url(forVirtualPath: trashPath)
        let record = MSPWorkspaceTrashRecord(
            id: id,
            originalPath: resolvedURL.resolved.virtualPath,
            originalName: originalName,
            trashPath: trashPath,
            isDirectory: isDirectory,
            trashedAt: Date()
        )
        let recordURL = trashRecordURL(for: record)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: itemDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: recordURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(record).write(to: recordURL, options: [.atomic])
            try FileManager.default.moveItem(at: resolvedURL.url, to: trashURL)
        } catch {
            let trashItemExists = FileManager.default.fileExists(atPath: trashURL.path)
            let sourceStillExists = FileManager.default.fileExists(atPath: resolvedURL.url.path)
            if trashItemExists && !sourceStillExists {
                return
            }
            if !trashItemExists {
                try? FileManager.default.removeItem(at: recordURL)
                try? FileManager.default.removeItem(at: itemDirectoryURL)
            }
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "trash"
            )
        }
    }

    func trashItemsRootPath(in configuration: MSPWorkspaceTrashConfiguration) -> String {
        joinVirtualPath(parent: configuration.storageRootPath, child: "items")
    }

    func trashRecordsRootPath(in configuration: MSPWorkspaceTrashConfiguration) -> String {
        joinVirtualPath(parent: configuration.storageRootPath, child: "records")
    }

    func trashRecordURL(for record: MSPWorkspaceTrashRecord) -> URL {
        guard let trashConfiguration else {
            return url(forVirtualPath: "/.msp/trash/records/\(record.id).json")
        }
        return url(forVirtualPath: joinVirtualPath(
            parent: trashRecordsRootPath(in: trashConfiguration),
            child: "\(record.id).json"
        ))
    }

    func trashItemDirectoryURL(for record: MSPWorkspaceTrashRecord) -> URL {
        var components = MSPWorkspacePathResolver.components(in: record.trashPath)
        if !components.isEmpty {
            components.removeLast()
        }
        let path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        return url(forVirtualPath: path)
    }

    func isTrashDisplayPath(_ virtualPath: String) -> Bool {
        guard let displayRootPath = trashConfiguration?.displayRootPath else {
            return false
        }
        let normalizedPath = MSPWorkspacePathResolver.normalize(virtualPath)
        return normalizedPath == displayRootPath || normalizedPath.hasPrefix(displayRootPath + "/")
    }

    func trashDisplayEntries(in parentVirtualPath: String) throws -> [MSPDirectoryEntry] {
        guard let trashConfiguration,
              let displayRootPath = trashConfiguration.displayRootPath,
              parentPath(of: displayRootPath) == parentVirtualPath else {
            return []
        }
        let name = MSPWorkspacePathResolver.components(in: displayRootPath).last ?? displayRootPath
        return [
            MSPDirectoryEntry(
                name: name,
                info: MSPFileInfo(
                    virtualPath: displayRootPath,
                    type: .directory,
                    size: 0,
                    modificationDate: try trashRecords().map(\.trashedAt).max()
                )
            )
        ]
    }

    func trashFileInfo(atDisplayPath path: String) throws -> MSPFileInfo {
        guard let trashConfiguration,
              trashConfiguration.displayRootPath != nil else {
            throw MSPWorkspaceFileSystemError.notFound(path)
        }
        let records = try trashRecords()
        let displayIndex = MSPAppleWorkspaceTrashDisplayIndex(
            records: records,
            configuration: trashConfiguration
        )
        return try trashFileInfo(
            atDisplayPath: path,
            records: records,
            displayIndex: displayIndex
        )
    }

    private func trashFileInfo(
        atDisplayPath path: String,
        records: [MSPWorkspaceTrashRecord],
        displayIndex: MSPAppleWorkspaceTrashDisplayIndex
    ) throws -> MSPFileInfo {
        guard let displayRootPath = trashConfiguration?.displayRootPath else {
            throw MSPWorkspaceFileSystemError.notFound(path)
        }
        let normalizedPath = MSPWorkspacePathResolver.normalize(path)
        if normalizedPath == displayRootPath {
            return MSPFileInfo(
                virtualPath: displayRootPath,
                type: .directory,
                size: 0,
                modificationDate: records.map(\.trashedAt).max()
            )
        }

        if let record = trashRecord(
            containingDisplayPath: normalizedPath,
            records: records,
            displayIndex: displayIndex
        ) {
            let recordDisplayPath = displayIndex.displayPath(for: record)
            let backingPath: String
            if normalizedPath == recordDisplayPath {
                backingPath = record.trashPath
            } else {
                guard record.isDirectory else {
                    throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
                }
                let suffix = String(normalizedPath.dropFirst(recordDisplayPath.count))
                backingPath = MSPWorkspacePathResolver.normalize(record.trashPath + suffix)
            }
            let backingURL = url(forVirtualPath: backingPath)
            guard FileManager.default.fileExists(atPath: backingURL.path) else {
                throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
            }
            return try fileInfo(virtualPath: normalizedPath, url: backingURL)
        }

        let children = try trashVirtualChildren(
            of: normalizedPath,
            displayRootPath: displayRootPath,
            records: records,
            displayIndex: displayIndex
        )
        guard !children.isEmpty else {
            throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
        }
        return MSPFileInfo(
            virtualPath: normalizedPath,
            type: .directory,
            size: 0,
            modificationDate: children.compactMap(\.info.modificationDate).max()
        )
    }

    func readTrashFile(atDisplayPath path: String) throws -> Data {
        guard let trashConfiguration else {
            throw MSPWorkspaceFileSystemError.notFound(path)
        }
        let normalizedPath = MSPWorkspacePathResolver.normalize(path)
        let records = try trashRecords()
        let displayIndex = MSPAppleWorkspaceTrashDisplayIndex(
            records: records,
            configuration: trashConfiguration
        )
        guard let record = trashRecord(
            containingDisplayPath: normalizedPath,
            records: records,
            displayIndex: displayIndex
        ) else {
            throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
        }
        let recordDisplayPath = displayIndex.displayPath(for: record)
        let backingPath: String
        if normalizedPath == recordDisplayPath {
            guard !record.isDirectory else {
                throw MSPWorkspaceFileSystemError.isDirectory(normalizedPath)
            }
            backingPath = record.trashPath
        } else {
            guard record.isDirectory else {
                throw MSPWorkspaceFileSystemError.notFound(normalizedPath)
            }
            let suffix = String(normalizedPath.dropFirst(recordDisplayPath.count))
            backingPath = MSPWorkspacePathResolver.normalize(record.trashPath + suffix)
        }
        let backingURL = url(forVirtualPath: backingPath)
        let info = try fileInfo(virtualPath: normalizedPath, url: backingURL)
        guard info.type != .directory else {
            throw MSPWorkspaceFileSystemError.isDirectory(normalizedPath)
        }
        do {
            return try Data(contentsOf: backingURL)
        } catch {
            throw MSPWorkspaceFileSystemError.io(path: normalizedPath, operation: "read")
        }
    }

    func trashRecord(
        containingDisplayPath path: String,
        records: [MSPWorkspaceTrashRecord],
        displayIndex: MSPAppleWorkspaceTrashDisplayIndex
    ) -> MSPWorkspaceTrashRecord? {
        return records
            .filter { record in
                let displayPath = displayIndex.displayPath(for: record)
                return path == displayPath || (record.isDirectory && path.hasPrefix(displayPath + "/"))
            }
            .sorted {
                displayIndex.displayPath(for: $0).count
                    > displayIndex.displayPath(for: $1).count
            }
            .first
    }

    func trashVirtualChildren(
        of path: String,
        displayRootPath: String,
        records: [MSPWorkspaceTrashRecord],
        displayIndex: MSPAppleWorkspaceTrashDisplayIndex
    ) throws -> [MSPDirectoryEntry] {
        var entriesByName: [String: MSPDirectoryEntry] = [:]
        for record in records {
            let displayPath = displayIndex.displayPath(for: record)
            guard displayPath.hasPrefix(path + "/") else {
                continue
            }
            let suffix = String(displayPath.dropFirst(path.count + 1))
            guard let childName = suffix.split(separator: "/").first.map(String.init) else {
                continue
            }
            let childPath = joinVirtualPath(parent: path, child: childName)
            if suffix == childName {
                entriesByName[childName] = MSPDirectoryEntry(
                    name: childName,
                    info: try trashFileInfo(
                        atDisplayPath: childPath,
                        records: records,
                        displayIndex: displayIndex
                    )
                )
            } else {
                let existingDate = entriesByName[childName]?.info.modificationDate
                let modifiedAt = max(existingDate ?? .distantPast, record.trashedAt)
                entriesByName[childName] = MSPDirectoryEntry(
                    name: childName,
                    info: MSPFileInfo(
                        virtualPath: childPath,
                        type: .directory,
                        size: 0,
                        modificationDate: modifiedAt
                    )
                )
            }
        }

        if path == displayRootPath {
            return entriesByName.values.sorted { $0.name < $1.name }
        }
        return entriesByName.values.sorted { $0.name < $1.name }
    }

    func restoreDestinationPath(
        for record: MSPWorkspaceTrashRecord,
        collisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy
    ) throws -> String {
        guard itemState(at: url(forVirtualPath: record.originalPath)).exists else {
            return record.originalPath
        }
        guard collisionPolicy == .unique else {
            throw MSPWorkspaceFileSystemError.alreadyExists(record.originalPath)
        }
        let parent = parentPath(of: record.originalPath)
        let name = record.originalName
        let dotIndex = name.lastIndex(of: ".")
        let base: String
        let suffix: String
        if let dotIndex, dotIndex != name.startIndex {
            base = String(name[..<dotIndex])
            suffix = String(name[dotIndex...])
        } else {
            base = name
            suffix = ""
        }
        for index in 2..<10_000 {
            let candidate = joinVirtualPath(parent: parent, child: "\(base) \(index)\(suffix)")
            if !itemState(at: url(forVirtualPath: candidate)).exists {
                return candidate
            }
        }
        throw MSPWorkspaceFileSystemError.alreadyExists(record.originalPath)
    }
}
