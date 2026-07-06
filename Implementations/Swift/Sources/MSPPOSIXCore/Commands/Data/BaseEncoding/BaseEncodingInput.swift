import Foundation
import MSPCore

func mspBaseEncodingReadFileChunks(
    fileSystem: any MSPWorkspaceFileSystem,
    path: String,
    currentDirectory: String,
    chunkSize: Int = 32 * 1024,
    consume: (Data) throws -> Void
) throws {
    let info = try fileSystem.stat(path, from: currentDirectory)
    guard let size = info.size else {
        try consume(fileSystem.readFile(path, from: currentDirectory))
        return
    }
    var offset: UInt64 = 0
    while offset < UInt64(max(0, size)) {
        let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: chunkSize)
        guard !chunk.isEmpty else {
            break
        }
        try consume(chunk)
        offset += UInt64(chunk.count)
    }
}
