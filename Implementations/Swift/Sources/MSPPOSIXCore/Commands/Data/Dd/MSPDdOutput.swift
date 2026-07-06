import Foundation
import MSPCore

enum MSPDdOutput {
    case buffer(MSPDdBufferedOutput)
    case stream(MSPDdStreamOutput)
    case file(MSPDdFileOutput)

    static func makeBuffered(
        options: MSPDdOptions,
        context: MSPCommandContext,
        commandName: String
    ) throws -> MSPDdOutput {
        if let outputPath = options.outputPath {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: commandName)
            return .file(try MSPDdFileOutput(
                fileSystem: fileSystem,
                path: outputPath,
                currentDirectory: context.currentDirectory,
                seekOffset: options.seekRecords * options.outputBlockSize,
                append: options.append,
                notrunc: options.notrunc,
                creationMode: context.regularFileCreationMode
            ))
        }
        return .buffer(MSPDdBufferedOutput())
    }

    mutating func write(_ data: Data) async throws {
        switch self {
        case .buffer(var output):
            try await output.write(data)
            self = .buffer(output)
        case .stream(let output):
            try await output.write(data)
        case .file(var output):
            try await output.write(data)
            self = .file(output)
        }
    }

    mutating func finish() async throws {
        switch self {
        case .buffer:
            return
        case .stream(let output):
            await output.close()
        case .file(var output):
            try output.finish()
            self = .file(output)
        }
    }

    func stdoutData() async -> Data {
        switch self {
        case .buffer(let output):
            return output.data
        case .stream, .file:
            return Data()
        }
    }
}

struct MSPDdBufferedOutput {
    var data = Data()

    mutating func write(_ chunk: Data) async throws {
        data.append(chunk)
    }
}

struct MSPDdStreamOutput {
    var stream: any MSPCommandOutputStream

    init(_ stream: any MSPCommandOutputStream) {
        self.stream = stream
    }

    func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    func close() async {
        await stream.closeWrite()
    }
}

struct MSPDdFileOutput {
    var fileSystem: any MSPWorkspaceFileSystem
    var path: String
    var currentDirectory: String
    var append: Bool
    var notrunc: Bool
    var creationMode: UInt16
    var temporaryPath: String?
    var oldSize: Int64
    var written = 0

    init(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String,
        seekOffset: Int,
        append: Bool,
        notrunc: Bool,
        creationMode: UInt16
    ) throws {
        self.fileSystem = fileSystem
        self.path = path
        self.currentDirectory = currentDirectory
        self.append = append
        self.notrunc = notrunc
        self.creationMode = creationMode
        let existingInfo = try? fileSystem.stat(path, from: currentDirectory)
        self.oldSize = existingInfo?.size ?? 0

        if append {
            self.temporaryPath = nil
            return
        }

        if notrunc, existingInfo != nil {
            let temp = ".msp-dd-\(UUID().uuidString)"
            self.temporaryPath = temp
            try copyMSPDdFileChunks(
                fileSystem: fileSystem,
                source: path,
                destination: temp,
                currentDirectory: currentDirectory,
                creationMode: creationMode
            )
        } else {
            self.temporaryPath = nil
        }

        try fileSystem.writeFile(
            path,
            data: Data(),
            from: currentDirectory,
            options: [.overwriteExisting, .createParentDirectories],
            creationMode: creationMode
        )

        if seekOffset > 0 {
            if let temporaryPath {
                try appendRange(from: temporaryPath, start: 0, count: min(seekOffset, Int(oldSize)))
                if seekOffset > oldSize {
                    try appendZeros(count: seekOffset - Int(oldSize))
                }
            } else {
                try appendZeros(count: seekOffset)
            }
            written = seekOffset
        }
    }

    mutating func write(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try fileSystem.appendFile(
            path,
            data: data,
            from: currentDirectory,
            options: [.createParentDirectories],
            creationMode: creationMode
        )
        written += data.count
    }

    mutating func finish() throws {
        defer {
            if let temporaryPath {
                try? fileSystem.remove(temporaryPath, from: currentDirectory, recursive: false)
            }
        }
        guard notrunc, let temporaryPath, Int(oldSize) > written else {
            return
        }
        try appendRange(from: temporaryPath, start: written, count: Int(oldSize) - written)
    }

    private func appendZeros(count: Int) throws {
        var remaining = count
        let zeroChunk = Data(repeating: 0, count: min(32 * 1024, max(remaining, 1)))
        while remaining > 0 {
            let size = min(remaining, zeroChunk.count)
            try fileSystem.appendFile(
                path,
                data: zeroChunk.subdata(in: 0..<size),
                from: currentDirectory,
                options: [.createParentDirectories],
                creationMode: creationMode
            )
            remaining -= size
        }
    }

    private func appendRange(from source: String, start: Int, count: Int) throws {
        var offset = UInt64(start)
        var remaining = count
        while remaining > 0 {
            let chunk = try fileSystem.readFileRange(
                source,
                from: currentDirectory,
                offset: offset,
                length: min(32 * 1024, remaining)
            )
            guard !chunk.isEmpty else {
                break
            }
            try fileSystem.appendFile(
                path,
                data: chunk,
                from: currentDirectory,
                options: [.createParentDirectories],
                creationMode: creationMode
            )
            offset += UInt64(chunk.count)
            remaining -= chunk.count
        }
    }
}

private func copyMSPDdFileChunks(
    fileSystem: any MSPWorkspaceFileSystem,
    source: String,
    destination: String,
    currentDirectory: String,
    creationMode: UInt16
) throws {
    try fileSystem.writeFile(
        destination,
        data: Data(),
        from: currentDirectory,
        options: [.overwriteExisting, .createParentDirectories],
        creationMode: creationMode
    )
    var offset: UInt64 = 0
    while true {
        let chunk = try fileSystem.readFileRange(source, from: currentDirectory, offset: offset, length: 32 * 1024)
        guard !chunk.isEmpty else {
            break
        }
        try fileSystem.appendFile(
            destination,
            data: chunk,
            from: currentDirectory,
            options: [.createParentDirectories],
            creationMode: creationMode
        )
        offset += UInt64(chunk.count)
    }
}
