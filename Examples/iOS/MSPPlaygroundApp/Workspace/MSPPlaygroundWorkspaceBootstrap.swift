import Foundation

enum MSPPlaygroundWorkspaceBootstrap {
    static func prepareWorkspace(
        profile: MSPPlaygroundWorkspaceProfile = .hostBacked,
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseURL = try workspaceContainerURL(fileManager: fileManager)
        let workspaceURL = baseURL.appendingPathComponent("Workspace", isDirectory: true)

        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try seedWorkspaceIfNeeded(
            at: workspaceURL,
            markerURL: baseURL.appendingPathComponent(".msp-playground-seeded"),
            fileManager: fileManager
        )
        if profile == .mixedBackend {
            try seedMixedWorkspaceHostFilesIfNeeded(at: workspaceURL, fileManager: fileManager)
        }
        return workspaceURL
    }

    private static func workspaceContainerURL(fileManager: FileManager) throws -> URL {
        #if os(iOS)
        let searchPath: FileManager.SearchPathDirectory = .documentDirectory
        #else
        let searchPath: FileManager.SearchPathDirectory = .applicationSupportDirectory
        #endif

        guard let url = fileManager.urls(for: searchPath, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let containerURL = url.appendingPathComponent("MSPPlaygroundApp", isDirectory: true)
        try fileManager.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        return containerURL
    }

    private static func seedWorkspaceIfNeeded(
        at workspaceURL: URL,
        markerURL: URL,
        fileManager: FileManager
    ) throws {
        let legacyMarkerURL = workspaceURL.appendingPathComponent(".msp-playground-seeded")
        if fileManager.fileExists(atPath: legacyMarkerURL.path) {
            try fileManager.removeItem(at: legacyMarkerURL)
        }
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            return
        }

        let docsURL = workspaceURL.appendingPathComponent("docs", isDirectory: true)
        let notesURL = workspaceURL.appendingPathComponent("notes", isDirectory: true)
        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)

        try write(
            "This directory is the MSP workspace root `/`.\n",
            to: workspaceURL.appendingPathComponent("README.md")
        )
        try write(
            "Try: ls, cat README.md, mkdir tmp, touch tmp/hello.txt\n",
            to: docsURL.appendingPathComponent("welcome.txt")
        )
        try write(
            "Commands run through Model Shell Protocol against this workspace.\n",
            to: notesURL.appendingPathComponent("first-run.txt")
        )
        try Data().write(to: markerURL)
    }

    private static func seedMixedWorkspaceHostFilesIfNeeded(
        at workspaceURL: URL,
        fileManager: FileManager
    ) throws {
        let docsURL = workspaceURL.appendingPathComponent("docs", isDirectory: true)
        let tmpURL = workspaceURL.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try writeIfMissing(
            "host-doc\n",
            to: docsURL.appendingPathComponent("host.txt"),
            fileManager: fileManager
        )
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeIfMissing(
        _ text: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            return
        }
        try write(text, to: url)
    }
}
