import Foundation
import MSPCore

public struct MSPExternalCommandPathMapper: Sendable {
    public var executableURL: URL
    public var modelVisibleExecutableDirectory: String
    public var runtimePathMappings: [MSPOutputPathSanitizer.Mapping]

    public init(
        executableURL: URL,
        modelVisibleExecutableDirectory: String = "/usr/local/bin",
        runtimePathMappings: [MSPOutputPathSanitizer.Mapping] = []
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.modelVisibleExecutableDirectory = MSPWorkspacePathResolver.normalize(
            modelVisibleExecutableDirectory
        )
        self.runtimePathMappings = runtimePathMappings.sorted { lhs, rhs in
            lhs.virtualPath.count > rhs.virtualPath.count
        }
    }

    public func workingDirectoryURL(
        virtualPath: String,
        context: MSPCommandContext
    ) throws -> URL {
        guard let workspace = context.workspace else {
            throw MSPExternalCommandPathMapperError.missingWorkspace
        }
        let resolved = try workspace.fileSystem.resolve(virtualPath, from: "/")
        guard let physicalPath = resolved.physicalPath else {
            throw MSPExternalCommandPathMapperError.unmappedWorkspacePath(resolved.virtualPath)
        }
        return URL(fileURLWithPath: physicalPath, isDirectory: true)
    }

    public func arguments(
        _ arguments: [String],
        context: MSPCommandContext
    ) throws -> [String] {
        try arguments.map { argument in
            try mapArgument(argument, context: context)
        }
    }

    public func environment(
        request: MSPExternalCommandRequest,
        extraEnvironment: [String: String] = [:],
        context: MSPCommandContext
    ) throws -> [String: String] {
        var environment = defaultWorkspaceEnvironment()
        environment.merge(try mappedEnvironment(extraEnvironment, context: context)) { _, new in new }
        environment.merge(try mappedEnvironment(request.environment, context: context)) { _, new in new }
        environment["HOME"] = try mapEnvironmentValue("/", context: context)
        environment["PWD"] = try mapEnvironmentValue(
            MSPWorkspacePathResolver.normalize(request.workingDirectory, from: context.currentDirectory),
            context: context
        )
        environment["TMPDIR"] = try mapEnvironmentValue("/tmp", context: context)
        environment["MSP_WORKSPACE_ROOT"] = try mapEnvironmentValue("/", context: context)
        environment["PATH"] = try executableSearchPath(
            existingPath: environment["PATH"] ?? "",
            context: context
        )
        return environment
    }

    public func outputSanitizer(
        context: MSPCommandContext,
        additionalMappings: [MSPOutputPathSanitizer.Mapping] = []
    ) throws -> MSPOutputPathSanitizer {
        var mappings = [try workspaceRootOutputMapping(context: context)]
        mappings.append(contentsOf: runtimePathMappings)
        mappings.append(contentsOf: additionalMappings)
        let baseSanitizer = MSPOutputPathSanitizer(mappings: mappings)
        let executableDirectory = executableURL.deletingLastPathComponent().path
        if shouldVirtualizeExecutableDirectory(
            executableDirectory,
            baseSanitizer: baseSanitizer
        ) {
            mappings.append(MSPOutputPathSanitizer.Mapping(
                realPath: executableDirectory,
                virtualPath: modelVisibleExecutableDirectory
            ))
        }
        return MSPOutputPathSanitizer(mappings: mappings)
    }

    public func mapArgument(
        _ argument: String,
        context: MSPCommandContext
    ) throws -> String {
        if let mappedOptionValue = try mapOptionValueArgument(argument, context: context) {
            return mappedOptionValue
        }
        return try mapVirtualPathLikeValue(argument, context: context) ?? argument
    }

    public func mapEnvironmentValue(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String {
        if let mappedPathList = try mapVirtualPathList(value, context: context) {
            return mappedPathList
        }
        return try mapVirtualPathLikeValue(value, context: context) ?? value
    }

    public func mapVirtualAbsolutePath(
        _ path: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard path.hasPrefix("/"),
              MSPWorkspacePathResolver.isSyntacticallyValid(path)
        else {
            return nil
        }
        if let runtimePath = mapRuntimePath(path) {
            return runtimePath
        }
        guard let workspace = context.workspace else {
            return nil
        }
        let resolved = try workspace.fileSystem.resolve(path, from: "/")
        guard let physicalPath = resolved.physicalPath else {
            throw MSPExternalCommandPathMapperError.unmappedWorkspacePath(resolved.virtualPath)
        }
        return physicalPath
    }

    private func mapRuntimePath(_ path: String) -> String? {
        let normalizedPath = MSPWorkspacePathResolver.normalize(path)
        for mapping in runtimePathMappings {
            let virtualRoot = mapping.virtualPath
            guard normalizedPath == virtualRoot ||
                    normalizedPath.hasPrefix(virtualRoot + "/")
            else {
                continue
            }
            let suffix = normalizedPath == virtualRoot
                ? ""
                : String(normalizedPath.dropFirst(virtualRoot.count + 1))
            let realRootURL = URL(fileURLWithPath: mapping.realPath, isDirectory: true)
                .standardizedFileURL
            guard !suffix.isEmpty else {
                return realRootURL.path
            }
            return realRootURL
                .appendingPathComponent(suffix, isDirectory: false)
                .standardizedFileURL
                .path
        }
        return nil
    }

    private func workspaceRootOutputMapping(
        context: MSPCommandContext
    ) throws -> MSPOutputPathSanitizer.Mapping {
        guard let workspace = context.workspace else {
            throw MSPExternalCommandPathMapperError.missingWorkspace
        }
        let resolvedRoot = try workspace.fileSystem.resolve("/", from: "/")
        guard let physicalRootPath = resolvedRoot.physicalPath else {
            throw MSPExternalCommandPathMapperError.unmappedWorkspacePath("/")
        }
        return MSPOutputPathSanitizer.Mapping(
            realPath: physicalRootPath,
            virtualPath: "/"
        )
    }

    private var modelVisibleExecutableDirectories: Set<String> {
        [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    private func shouldVirtualizeExecutableDirectory(
        _ executableDirectory: String,
        baseSanitizer: MSPOutputPathSanitizer
    ) -> Bool {
        guard !executableDirectory.isEmpty,
              !modelVisibleExecutableDirectories.contains(executableDirectory)
        else {
            return false
        }
        return baseSanitizer.sanitize(executableDirectory) == executableDirectory
    }

    private func executableSearchPath(
        existingPath: String,
        context: MSPCommandContext
    ) throws -> String {
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let pathComponents = existingPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        if pathComponents.contains(executableDirectory) {
            return existingPath
        }

        let baseSanitizer = MSPOutputPathSanitizer(mappings: [
            try workspaceRootOutputMapping(context: context)
        ])
        if shouldVirtualizeExecutableDirectory(
            executableDirectory,
            baseSanitizer: baseSanitizer
        ) {
            var didReplace = false
            let replacedComponents = pathComponents.map { component in
                guard !didReplace,
                      component == modelVisibleExecutableDirectory
                else {
                    return component
                }
                didReplace = true
                return executableDirectory
            }
            if didReplace {
                return replacedComponents.joined(separator: ":")
            }
        }

        return existingPath.isEmpty
            ? executableDirectory
            : executableDirectory + ":" + existingPath
    }

    private func defaultWorkspaceEnvironment() -> [String: String] {
        [
            "HOME": "/",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": "/",
            "TMPDIR": "/tmp",
            "MSP_WORKSPACE_ROOT": "/"
        ]
    }

    private func mappedEnvironment(
        _ environment: [String: String],
        context: MSPCommandContext
    ) throws -> [String: String] {
        var processed: [String: String] = [:]
        for (key, value) in environment {
            processed[key] = try mapEnvironmentValue(value, context: context)
        }
        return processed
    }

    private func mapOptionValueArgument(
        _ argument: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard argument.hasPrefix("-"),
              let separatorIndex = argument.firstIndex(of: "=")
        else {
            return nil
        }
        let valueStartIndex = argument.index(after: separatorIndex)
        let value = String(argument[valueStartIndex...])
        guard let mappedValue = try mapVirtualPathLikeValue(value, context: context) else {
            return nil
        }
        return String(argument[...separatorIndex]) + mappedValue
    }

    private func mapVirtualPathLikeValue(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String? {
        if let mappedPath = try mapVirtualAbsolutePath(value, context: context) {
            return mappedPath
        }
        return try mapVirtualFileURL(value, context: context)
    }

    private func mapVirtualPathList(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard value.contains(":"),
              !value.contains("://")
        else {
            return nil
        }
        let components = value
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count > 1 else {
            return nil
        }
        var didMap = false
        let mappedComponents = try components.map { component in
            guard !component.isEmpty,
                  let mappedComponent = try mapVirtualPathLikeValue(component, context: context)
            else {
                return component
            }
            didMap = true
            return mappedComponent
        }
        guard didMap else {
            return nil
        }
        return mappedComponents.joined(separator: ":")
    }

    private func mapVirtualFileURL(
        _ value: String,
        context: MSPCommandContext
    ) throws -> String? {
        guard let url = URL(string: value), url.isFileURL else {
            return nil
        }
        guard let physicalPath = try mapVirtualAbsolutePath(url.path, context: context) else {
            return nil
        }
        return URL(fileURLWithPath: physicalPath)
            .standardizedFileURL
            .absoluteString
    }
}

public enum MSPExternalCommandPathMapperError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingWorkspace
    case unmappedWorkspacePath(String)

    public var description: String {
        switch self {
        case .missingWorkspace:
            return "external command path mapping requires a mapped workspace"
        case .unmappedWorkspacePath(let path):
            return "workspace path is not mapped to a host path: \(path)"
        }
    }
}
