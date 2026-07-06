import Foundation
import XCTest
import ModelShellProxy

func mspConformanceTemporaryRootURL() -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["MSP_CONFORMANCE_TMPDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
}

func mspConformanceTemporaryURL(suiteName: String, name: String) -> URL {
    mspConformanceTemporaryRootURL()
        .appendingPathComponent(suiteName)
        .appendingPathComponent(name)
}

class ModelShellProxyIntegrationTestCase: XCTestCase {
    func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        mspConformanceTemporaryURL(
            suiteName: "ModelShellProxyIntegrationTests",
            name: name
        )
    }

    func removeTemporaryURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func findTestDate(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

}

struct PipelineStreamingOnlyWorkspace: MSPWorkspace {
    var rootPath: String { "/" }
    let fileSystem: any MSPWorkspaceFileSystem
}

final class PipelineStreamingOnlyFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private let fileCount: Int
    private(set) var listDirectoryCallCount = 0
    private(set) var enumeratedEntryCount = 0

    init(fileCount: Int) {
        self.fileCount = fileCount
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: "/", type: .directory, permissions: 0o755)
        }
        guard fileIndex(for: virtualPath) != nil else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: 1, permissions: 0o644)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        listDirectoryCallCount += 1
        throw MSPWorkspaceFileSystemError.io(
            path: MSPWorkspacePathResolver.normalize(path, from: currentDirectory),
            operation: "eager-list-forbidden"
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        for index in 0..<fileCount {
            enumeratedEntryCount += 1
            let filePath = String(format: "/file-%03d.txt", index)
            let entry = MSPDirectoryEntry(
                name: String(filePath.dropFirst()),
                info: MSPFileInfo(virtualPath: filePath, type: .regularFile, size: 1, permissions: 0o644)
            )
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        throw MSPWorkspaceFileSystemError.notFound(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func writeFile(_ path: String, data: Data, from currentDirectory: String, options: MSPFileWriteOptions) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func copy(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileCopyOptions) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(destinationPath, from: currentDirectory))
    }

    func move(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileMoveOptions) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(destinationPath, from: currentDirectory))
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(linkPath, from: currentDirectory))
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(linkPath, from: currentDirectory))
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    private func fileIndex(for virtualPath: String) -> Int? {
        guard virtualPath.hasPrefix("/file-"),
              virtualPath.hasSuffix(".txt"),
              let index = Int(virtualPath.dropFirst("/file-".count).dropLast(".txt".count)),
              index >= 0,
              index < fileCount else {
            return nil
        }
        return index
    }
}
