import Foundation

enum MSPPlaygroundWorkspaceBootstrap {
    static func prepareWorkspace(fileManager: FileManager = .default) throws -> URL {
        let baseURL = try workspaceContainerURL(fileManager: fileManager)
        let workspaceURL = baseURL.appendingPathComponent("Workspace", isDirectory: true)

        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try ensureTemporaryDirectory(in: workspaceURL, fileManager: fileManager)
        try PhotoSorterChatPersistence.ensureConversationsDirectory(
            in: workspaceURL,
            fileManager: fileManager
        )
        try removePlaygroundSeedIfPresent(at: workspaceURL, fileManager: fileManager)
        return workspaceURL
    }

    static func ensureTemporaryDirectory(
        in workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: workspaceURL.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
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

        let containerURL = url.appendingPathComponent("PhotoSorter", isDirectory: true)
        try fileManager.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        return containerURL
    }

    private static func removePlaygroundSeedIfPresent(
        at workspaceURL: URL,
        fileManager: FileManager
    ) throws {
        let markerURL = workspaceURL.appendingPathComponent(".msp-playground-seeded")
        try? fileManager.removeItem(at: markerURL)

        try removeIfContentsMatch(
            workspaceURL.appendingPathComponent("README.md"),
            expected: "This directory is the MSP workspace root `/`.\n",
            fileManager: fileManager
        )
        try removeIfContentsMatch(
            workspaceURL.appendingPathComponent("docs/welcome.txt"),
            expected: "Try: ls, cat README.md, mkdir tmp, touch tmp/hello.txt\n",
            fileManager: fileManager
        )
        try removeIfContentsMatch(
            workspaceURL.appendingPathComponent("notes/first-run.txt"),
            expected: "Commands run through Model Shell Protocol against this workspace.\n",
            fileManager: fileManager
        )
        try removeDirectoryIfEmpty(workspaceURL.appendingPathComponent("docs"), fileManager: fileManager)
        try removeDirectoryIfEmpty(workspaceURL.appendingPathComponent("notes"), fileManager: fileManager)
    }

    private static func removeIfContentsMatch(
        _ url: URL,
        expected: String,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path),
              (try? String(contentsOf: url, encoding: .utf8)) == expected
        else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private static func removeDirectoryIfEmpty(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let contents = try fileManager.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty else {
            return
        }
        try fileManager.removeItem(at: url)
    }
}
