import Foundation

enum Debian12OracleWorkspaceFixtureSupport {
    static func prepareFixture(_ fixture: Debian12OracleFixtureSpec, rootURL: URL) throws {
        for directory in fixture.directories {
            let url = try safeFixtureURL(rootURL: rootURL, relativePath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for file in fixture.files {
            let url = try safeFixtureURL(rootURL: rootURL, relativePath: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let target = file.target {
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            } else {
                try file.contentData.write(to: url)
            }
            if let mode = file.modeValue {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int(mode))],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    static func snapshotFileTree(rootURL: URL) throws -> [Debian12OracleFileTreeEntry] {
        var entries: [Debian12OracleFileTreeEntry] = []
        try appendSnapshotEntry(url: rootURL, path: ".", entries: &entries)
        return entries.sorted { lhs, rhs in
            if lhs.path == rhs.path {
                return lhs.kind < rhs.kind
            }
            return lhs.path < rhs.path
        }
    }

    private static func appendSnapshotEntry(
        url: URL,
        path: String,
        entries: inout [Debian12OracleFileTreeEntry]
    ) throws {
        guard !isInternalImplementationSnapshotPath(path) else {
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = String(format: "%03o", (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            entries.append(
                Debian12OracleFileTreeEntry(
                    kind: "symlink",
                    mode: "777",
                    path: path,
                    size: nil,
                    contentB64: nil,
                    target: target
                )
            )
            return
        }

        var isDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let children = try FileManager.default
                .contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if path == "./tmp", children.isEmpty {
                return
            }
            entries.append(
                Debian12OracleFileTreeEntry(
                    kind: "directory",
                    mode: mode,
                    path: path,
                    size: nil,
                    contentB64: nil,
                    target: nil
                )
            )
            for child in children {
                let childPath = path == "."
                    ? "./\(child.lastPathComponent)"
                    : "\(path)/\(child.lastPathComponent)"
                try appendSnapshotEntry(url: child, path: childPath, entries: &entries)
            }
        } else {
            let data = try Data(contentsOf: url)
            entries.append(
                Debian12OracleFileTreeEntry(
                    kind: "file",
                    mode: mode,
                    path: path,
                    size: data.count,
                    contentB64: data.base64EncodedString(),
                    target: nil
                )
            )
        }
    }

    private static func isInternalImplementationSnapshotPath(_ path: String) -> Bool {
        path == "./.msp" || path.hasPrefix("./.msp/")
    }

    private static func safeFixtureURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw Debian12OracleTestSupport.runnerError("absolute fixture path is not allowed: \(relativePath)")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw Debian12OracleTestSupport.runnerError("escaping fixture path is not allowed: \(relativePath)")
        }
        return rootURL.appendingPathComponent(relativePath)
    }
}
