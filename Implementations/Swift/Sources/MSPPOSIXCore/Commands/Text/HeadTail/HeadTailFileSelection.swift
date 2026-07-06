import Foundation
import MSPCore

extension MSPHeadTailCommand {
    func selectFile(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        selection: HeadTailSelection
    ) async throws -> Data {
        switch selection.unit {
        case .bytes:
            return try selectFileBytes(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                selection: selection
            )
        case .lines:
            return try await selectFileRecords(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                selection: selection
            )
        }
    }

    private func selectFileBytes(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        selection: HeadTailSelection
    ) throws -> Data {
        let fileSize = try regularFileSize(path, fileSystem: fileSystem, currentDirectory: currentDirectory)
        switch selection.direction {
        case .head:
            return try readFileRangeData(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                offset: 0,
                byteCount: min(Int64(selection.count), fileSize)
            )
        case .headAllButLast:
            return try readFileRangeData(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                offset: 0,
                byteCount: max(0, fileSize - Int64(selection.count))
            )
        case .tail:
            let byteCount = min(Int64(selection.count), fileSize)
            return try readFileRangeData(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                offset: UInt64(max(0, fileSize - byteCount)),
                byteCount: byteCount
            )
        case .tailFromStart:
            let start = max(Int64(selection.count) - 1, 0)
            guard start < fileSize else {
                return Data()
            }
            return try readFileRangeData(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                offset: UInt64(start),
                byteCount: fileSize - start
            )
        }
    }

    private func selectFileRecords(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        selection: HeadTailSelection
    ) async throws -> Data {
        switch selection.direction {
        case .head:
            return try selectFileHeadRecords(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                count: selection.count,
                separator: selection.separator
            )
        case .tail:
            return try selectFileTailRecords(
                path,
                fileSystem: fileSystem,
                currentDirectory: currentDirectory,
                count: selection.count,
                separator: selection.separator
            )
        case .headAllButLast, .tailFromStart:
            let input = MSPWorkspaceFileInputStream(
                fileSystem: fileSystem,
                path: path,
                currentDirectory: currentDirectory
            )
            let output = MSPCommandOutputBuffer()
            if selection.direction == .headAllButLast {
                try await streamHead(
                    standardInput: input,
                    standardOutput: output,
                    selection: selection
                )
            } else {
                try await streamTail(
                    standardInput: input,
                    standardOutput: output,
                    selection: selection
                )
            }
            return await output.data()
        }
    }

    private func regularFileSize(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> Int64 {
        let info = try fileSystem.stat(path, from: currentDirectory)
        guard info.type != .directory else {
            throw MSPWorkspaceFileSystemError.isDirectory(path)
        }
        if let size = info.size {
            return max(0, size)
        }
        return Int64(try fileSystem.readFile(path, from: currentDirectory).count)
    }

    private func readFileRangeData(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        offset: UInt64,
        byteCount: Int64
    ) throws -> Data {
        guard byteCount > 0 else {
            return Data()
        }

        var output = Data()
        var currentOffset = offset
        var remaining = byteCount
        let chunkSize = 32 * 1024
        while remaining > 0 {
            let request = remaining > Int64(chunkSize) ? chunkSize : Int(remaining)
            let chunk = try fileSystem.readFileRange(
                path,
                from: currentDirectory,
                offset: currentOffset,
                length: request
            )
            guard !chunk.isEmpty else {
                break
            }
            output.append(chunk)
            currentOffset += UInt64(chunk.count)
            remaining -= Int64(chunk.count)
        }
        return output
    }

    private func selectFileHeadRecords(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        count: Int,
        separator: UInt8
    ) throws -> Data {
        _ = try regularFileSize(path, fileSystem: fileSystem, currentDirectory: currentDirectory)
        guard count > 0 else {
            return Data()
        }

        var output = Data()
        var offset: UInt64 = 0
        var remaining = count
        let chunkSize = 32 * 1024
        while remaining > 0 {
            let chunk = try fileSystem.readFileRange(
                path,
                from: currentDirectory,
                offset: offset,
                length: chunkSize
            )
            guard !chunk.isEmpty else {
                break
            }

            var selectedEnd = chunk.count
            var index = 0
            while index < chunk.count {
                if chunk[index] == separator {
                    remaining -= 1
                    if remaining == 0 {
                        selectedEnd = index + 1
                        break
                    }
                }
                index += 1
            }
            output.append(chunk.headTailPrefixData(selectedEnd))
            offset += UInt64(chunk.count)
        }
        return output
    }

    private func selectFileTailRecords(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        count: Int,
        separator: UInt8
    ) throws -> Data {
        guard count > 0 else {
            _ = try regularFileSize(path, fileSystem: fileSystem, currentDirectory: currentDirectory)
            return Data()
        }

        let fileSize = try regularFileSize(path, fileSystem: fileSystem, currentDirectory: currentDirectory)
        guard fileSize > 0 else {
            return Data()
        }

        let lastByte = try fileSystem.readFileRange(
            path,
            from: currentDirectory,
            offset: UInt64(fileSize - 1),
            length: 1
        ).first
        let requiredSeparators = count + (lastByte == separator ? 1 : 0)
        var separatorsSeen = 0
        var scanOffset = fileSize
        let chunkSize = 32 * 1024

        while scanOffset > 0 {
            let length = min(chunkSize, Int(scanOffset))
            scanOffset -= Int64(length)
            let chunk = try fileSystem.readFileRange(
                path,
                from: currentDirectory,
                offset: UInt64(scanOffset),
                length: length
            )
            guard !chunk.isEmpty else {
                break
            }

            var index = chunk.count - 1
            while index >= 0 {
                if chunk[index] == separator {
                    separatorsSeen += 1
                    if separatorsSeen == requiredSeparators {
                        let startOffset = UInt64(scanOffset) + UInt64(index + 1)
                        return try readFileRangeData(
                            path,
                            fileSystem: fileSystem,
                            currentDirectory: currentDirectory,
                            offset: startOffset,
                            byteCount: fileSize - Int64(startOffset)
                        )
                    }
                }
                if index == 0 {
                    break
                }
                index -= 1
            }
        }

        return try readFileRangeData(
            path,
            fileSystem: fileSystem,
            currentDirectory: currentDirectory,
            offset: 0,
            byteCount: fileSize
        )
    }
}
