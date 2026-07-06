import Foundation
import MSPCore

public enum MSPGitWorkspaceMappingError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingWorkspace
    case unmappedWorkspacePath(String)

    public var description: String {
        switch self {
        case .missingWorkspace:
            return "git backend requires a mapped workspace"
        case .unmappedWorkspacePath(let path):
            return "workspace path is not mapped to a physical path: \(path)"
        }
    }
}

public struct MSPGitWorkspaceMapping: Sendable, Equatable {
    public var virtualRootPath: String
    public var physicalRootPath: String

    public init(
        physicalRootPath: String,
        virtualRootPath: String = "/"
    ) {
        self.physicalRootPath = URL(fileURLWithPath: physicalRootPath)
            .standardizedFileURL
            .path
        self.virtualRootPath = MSPWorkspacePathResolver.normalize(virtualRootPath)
    }

    public init(context: MSPCommandContext) throws {
        guard let workspace = context.workspace else {
            throw MSPGitWorkspaceMappingError.missingWorkspace
        }
        let resolvedRoot = try workspace.fileSystem.resolve("/", from: "/")
        guard let physicalRootPath = resolvedRoot.physicalPath else {
            throw MSPGitWorkspaceMappingError.unmappedWorkspacePath(resolvedRoot.virtualPath)
        }
        self.init(
            physicalRootPath: physicalRootPath,
            virtualRootPath: resolvedRoot.virtualPath
        )
    }

    public func physicalPath(
        forVirtualPath virtualPath: String,
        from currentDirectory: String = "/"
    ) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(virtualPath, from: currentDirectory)
        guard normalized != virtualRootPath else {
            return physicalRootPath
        }
        var url = URL(fileURLWithPath: physicalRootPath, isDirectory: true)
        let relative = relativeComponents(for: normalized)
        for component in relative {
            url.appendPathComponent(component, isDirectory: false)
        }
        return url.standardizedFileURL.path
    }

    public func virtualPath(forPhysicalPath physicalPath: String) -> String? {
        let normalizedPhysicalPath = URL(fileURLWithPath: physicalPath)
            .standardizedFileURL
            .path
        if normalizedPhysicalPath == physicalRootPath {
            return virtualRootPath
        }
        let prefix = physicalRootPath + "/"
        guard normalizedPhysicalPath.hasPrefix(prefix) else {
            return nil
        }
        let relative = String(normalizedPhysicalPath.dropFirst(prefix.count))
        guard !relative.isEmpty else {
            return virtualRootPath
        }
        if virtualRootPath == "/" {
            return "/" + relative
        }
        return MSPWorkspacePathResolver.normalize(virtualRootPath + "/" + relative)
    }

    public func outputSanitizer() -> MSPOutputPathSanitizer {
        MSPOutputPathSanitizer(mappings: [
            MSPOutputPathSanitizer.Mapping(
                realPath: physicalRootPath,
                virtualPath: virtualRootPath
            )
        ])
    }

    public func sanitize(_ result: MSPCommandResult) -> MSPCommandResult {
        outputSanitizer().sanitize(result)
    }

    private func relativeComponents(for virtualPath: String) -> [String] {
        let normalized = MSPWorkspacePathResolver.normalize(virtualPath)
        let rootComponents = MSPWorkspacePathResolver.components(in: virtualRootPath)
        let components = MSPWorkspacePathResolver.components(in: normalized)
        guard components.starts(with: rootComponents) else {
            return components
        }
        return Array(components.dropFirst(rootComponents.count))
    }
}
