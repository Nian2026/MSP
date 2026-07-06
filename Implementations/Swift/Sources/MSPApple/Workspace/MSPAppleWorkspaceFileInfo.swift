import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func stat(_ path: String, from currentDirectory: String = "/") throws -> MSPFileInfo {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            return try trashFileInfo(atDisplayPath: virtualPath)
        }
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        return try fileInfo(virtualPath: resolvedURL.resolved.virtualPath, url: resolvedURL.url)
    }

    var directoryEntryResourceKeys: [URLResourceKey] {
        [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
    }

    func itemState(at url: URL) -> (exists: Bool, isDirectory: Bool, isSymbolicLink: Bool) {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        let isSymbolicLink = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
        )) != nil
        return (
            exists || isSymbolicLink,
            exists && isDirectory.boolValue,
            isSymbolicLink
        )
    }

    func fileInfo(virtualPath: String, url: URL) throws -> MSPFileInfo {
        do {
            let values = try url.resourceValues(forKeys: Set(directoryEntryResourceKeys))
            let type: MSPFileType
            if values.isSymbolicLink == true {
                type = .symbolicLink
            } else if values.isDirectory == true {
                type = policy.presentsDirectoryPackageAsFile(virtualPath)
                    ? .regularFile
                    : .directory
            } else if values.isRegularFile == true {
                type = .regularFile
            } else {
                type = .other
            }
            let symbolicLinkTarget: String?
            if type == .symbolicLink,
               let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                symbolicLinkTarget = try? virtualSymbolicLinkTarget(
                    destination,
                    linkVirtualPath: virtualPath
                )
            } else {
                symbolicLinkTarget = nil
            }
            let attributes = type == .symbolicLink
                ? nil
                : try? FileManager.default.attributesOfItem(atPath: url.path)
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: type,
                size: values.fileSize.map(Int64.init),
                modificationDate: values.contentModificationDate,
                permissions: type == .symbolicLink ? 0o777 : posixPermissions(from: attributes),
                symbolicLinkTarget: symbolicLinkTarget,
                fileIdentity: type == .symbolicLink ? nil : posixFileIdentity(from: attributes)
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(path: virtualPath, operation: "stat")
        }
    }

    func posixPermissions(at url: URL) -> UInt16? {
        posixPermissions(from: try? FileManager.default.attributesOfItem(atPath: url.path))
    }

    func posixPermissions(from attributes: [FileAttributeKey: Any]?) -> UInt16? {
        guard let value = attributes?[.posixPermissions] as? NSNumber else { return nil }
        return UInt16(truncating: value)
    }

    func posixFileIdentity(at url: URL) -> String? {
        posixFileIdentity(from: try? FileManager.default.attributesOfItem(atPath: url.path))
    }

    func posixFileIdentity(from attributes: [FileAttributeKey: Any]?) -> String? {
        guard let systemNumber = attributes?[.systemNumber] as? NSNumber,
              let fileNumber = attributes?[.systemFileNumber] as? NSNumber
        else {
            return nil
        }
        return "\(systemNumber):\(fileNumber)"
    }
}
