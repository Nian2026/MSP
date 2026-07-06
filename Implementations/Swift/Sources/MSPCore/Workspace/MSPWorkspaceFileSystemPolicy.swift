import Foundation

public struct MSPWorkspaceFileSystemPolicy: Sendable, Equatable {
    public var hiddenPathComponents: Set<String>
    public var trashConfiguration: MSPWorkspaceTrashConfiguration?
    public var directoryOrdering: MSPWorkspaceDirectoryOrdering
    public var directoryPackageFileExtensions: Set<String>

    public init(
        hiddenPathComponents: Set<String> = [".msp"],
        trashConfiguration: MSPWorkspaceTrashConfiguration? = .default,
        directoryOrdering: MSPWorkspaceDirectoryOrdering = .debian12OracleExt4,
        directoryPackageFileExtensions: Set<String> = ["chat"]
    ) {
        self.hiddenPathComponents = Set(
            hiddenPathComponents.filter { component in
                !component.isEmpty && !component.contains("/")
            }
        )
        self.trashConfiguration = trashConfiguration
        self.directoryOrdering = directoryOrdering
        self.directoryPackageFileExtensions = Set(
            directoryPackageFileExtensions.compactMap(Self.normalizedPackageFileExtension)
        )
    }

    public static var `default`: MSPWorkspaceFileSystemPolicy {
        MSPWorkspaceFileSystemPolicy()
    }

    public func isHidden(_ virtualPath: String) -> Bool {
        let normalizedPath = MSPWorkspacePathResolver.normalize(virtualPath)
        if let storageRootPath = trashConfiguration?.storageRootPath,
           normalizedPath == storageRootPath || normalizedPath.hasPrefix(storageRootPath + "/") {
            return true
        }
        guard !hiddenPathComponents.isEmpty else {
            return false
        }
        return MSPWorkspacePathResolver.components(in: normalizedPath)
            .contains { hiddenPathComponents.contains($0) }
    }

    public func presentsDirectoryPackageAsFile(_ virtualPath: String) -> Bool {
        guard let extensionName = packageFileExtension(in: virtualPath) else {
            return false
        }
        return directoryPackageFileExtensions.contains(extensionName)
    }

    public func directoryPackageFileAncestor(in virtualPath: String) -> String? {
        let components = MSPWorkspacePathResolver.components(in: virtualPath)
        guard components.count > 1 else {
            return nil
        }

        var cursor: [String] = []
        for component in components.dropLast() {
            cursor.append(component)
            let candidate = "/" + cursor.joined(separator: "/")
            if presentsDirectoryPackageAsFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func normalizedPackageFileExtension(_ rawExtension: String) -> String? {
        let trimmed = rawExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix(".")
            .lowercased()
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            return nil
        }
        return trimmed
    }

    private func packageFileExtension(in virtualPath: String) -> String? {
        guard let name = MSPWorkspacePathResolver.components(in: virtualPath).last,
              let dotIndex = name.lastIndex(of: "."),
              dotIndex != name.startIndex
        else {
            return nil
        }
        let extensionStart = name.index(after: dotIndex)
        guard extensionStart < name.endIndex else {
            return nil
        }
        return String(name[extensionStart...]).lowercased()
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        var result = self
        while result.first == prefix {
            result.removeFirst()
        }
        return result
    }
}
