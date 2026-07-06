import Foundation

extension MSPCompositeWorkspaceFileSystem {
    public func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        let source = try route(sourcePath, from: currentDirectory)
        let destination = try route(destinationPath, from: currentDirectory)
        if source.identity == destination.identity {
            try withRebasedRouteErrors(source) {
                try fileSystem(for: source).copy(
                    source.backendPath,
                    to: destination.backendPath,
                    from: "/",
                    options: options
                )
            }
            return
        }
        let sourceInfo = try stat(source.virtualPath, from: "/")
        guard sourceInfo.type == .regularFile else {
            throw MSPWorkspaceFileSystemError.io(path: source.virtualPath, operation: "cross-backend copy")
        }
        let data = try readFile(source.virtualPath, from: "/")
        try writeFile(
            destination.virtualPath,
            data: data,
            from: "/",
            options: writeOptions(for: options)
        )
    }

    public func copy(
        _ requests: [MSPFileCopyRequest],
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        guard let firstRequest = requests.first else {
            return
        }
        let firstSource = try route(firstRequest.sourcePath, from: currentDirectory)
        let firstDestination = try route(firstRequest.destinationPath, from: currentDirectory)
        guard firstSource.identity == firstDestination.identity else {
            return try copyIndividually(requests, from: currentDirectory, options: options)
        }

        var routedRequests: [(source: MSPCompositeRoute, destination: MSPCompositeRoute)] = [
            (source: firstSource, destination: firstDestination)
        ]
        routedRequests.reserveCapacity(requests.count)
        for request in requests.dropFirst() {
            let source = try route(request.sourcePath, from: currentDirectory)
            let destination = try route(request.destinationPath, from: currentDirectory)
            guard source.identity == firstSource.identity,
                  destination.identity == firstSource.identity
            else {
                return try copyIndividually(requests, from: currentDirectory, options: options)
            }
            routedRequests.append((source: source, destination: destination))
        }

        let targetFileSystem = fileSystem(for: firstSource)
        let backendRequests = routedRequests.map {
            MSPFileCopyRequest(
                sourcePath: $0.source.backendPath,
                destinationPath: $0.destination.backendPath
            )
        }
        try withRebasedRouteErrors(firstSource) {
            if let batchFileSystem = targetFileSystem as? any MSPWorkspaceBatchCopying {
                try batchFileSystem.copy(backendRequests, from: "/", options: options)
            } else {
                for request in backendRequests {
                    try targetFileSystem.copy(
                        request.sourcePath,
                        to: request.destinationPath,
                        from: "/",
                        options: options
                    )
                }
            }
        }
    }

    public func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        let source = try route(sourcePath, from: currentDirectory)
        let destination = try route(destinationPath, from: currentDirectory)
        if source.identity == destination.identity {
            try withRebasedRouteErrors(source) {
                try fileSystem(for: source).move(
                    source.backendPath,
                    to: destination.backendPath,
                    from: "/",
                    options: options
                )
            }
            return
        }
        let sourceInfo = try stat(source.virtualPath, from: "/")
        guard sourceInfo.type == .regularFile else {
            throw MSPWorkspaceFileSystemError.io(path: source.virtualPath, operation: "cross-backend move")
        }
        let data = try readFile(source.virtualPath, from: "/")
        try writeFile(
            destination.virtualPath,
            data: data,
            from: "/",
            options: writeOptions(for: options)
        )
        try remove(source.virtualPath, from: "/", recursive: false)
    }

    public func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        let source = try route(sourcePath, from: currentDirectory)
        let link = try route(linkPath, from: currentDirectory)
        guard source.identity == link.identity else {
            throw MSPWorkspaceFileSystemError.accessDenied(link.virtualPath)
        }
        try withRebasedRouteErrors(source) {
            try fileSystem(for: source).createHardLink(source: source.backendPath, at: link.backendPath, from: "/")
        }
    }

    public func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        let link = try route(linkPath, from: currentDirectory)
        switch link.backend {
        case .base:
            try baseFileSystem.createSymbolicLink(target: target, at: link.virtualPath, from: "/")
        case .mount(let mount):
            let backendTarget: String
            if target.hasPrefix("/") {
                let normalizedTarget = MSPWorkspacePathResolver.normalize(target)
                guard normalizedTarget == mount.path || normalizedTarget.hasPrefix(mount.path + "/") else {
                    throw MSPWorkspaceFileSystemError.accessDenied(normalizedTarget)
                }
                backendTarget = backendPath(forRebasedPath: normalizedTarget, mountPath: mount.path)
            } else {
                backendTarget = target
            }
            try withRebasedMountErrors(mount) {
                try mount.fileSystem.createSymbolicLink(target: backendTarget, at: link.backendPath, from: "/")
            }
        }
    }

    public func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                return
            }
            try baseFileSystem.chmod(route.virtualPath, mode: mode, from: "/")
        case .mount(let mount):
            try withRebasedMountErrors(mount) {
                try mount.fileSystem.chmod(route.backendPath, mode: mode, from: "/")
            }
        }
    }

    func copyIndividually(
        _ requests: [MSPFileCopyRequest],
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        for request in requests {
            try copy(
                request.sourcePath,
                to: request.destinationPath,
                from: currentDirectory,
                options: options
            )
        }
    }

    func writeOptions(for copyOptions: MSPFileCopyOptions) -> MSPFileWriteOptions {
        var options: MSPFileWriteOptions = []
        if copyOptions.contains(.overwriteExisting) {
            options.insert(.overwriteExisting)
        }
        if copyOptions.contains(.createParentDirectories) {
            options.insert(.createParentDirectories)
        }
        return options
    }

    func writeOptions(for moveOptions: MSPFileMoveOptions) -> MSPFileWriteOptions {
        var options: MSPFileWriteOptions = []
        if moveOptions.contains(.overwriteExisting) {
            options.insert(.overwriteExisting)
        }
        if moveOptions.contains(.createParentDirectories) {
            options.insert(.createParentDirectories)
        }
        return options
    }
}
