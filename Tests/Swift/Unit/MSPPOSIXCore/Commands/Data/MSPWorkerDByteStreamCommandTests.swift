import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPWorkerDByteStreamCommandTests: XCTestCase {
    func testDdCopiesConvertsAndPreservesNotruncTail() async throws {
        let workspace = Core100DWorkspace(files: [
            "/in.bin": Data("abcdef".utf8),
            "/short.bin": Data("ab".utf8),
            "/out.bin": Data("123456".utf8)
        ])

        let copy = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["if=in.bin", "of=copy.bin", "bs=2", "count=2", "status=none"]),
            context: context(workspace: workspace)
        )
        let skip = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["if=in.bin", "bs=1", "skip=2", "count=3", "status=none"]),
            context: context(workspace: workspace)
        )
        let notrunc = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["if=short.bin", "of=out.bin", "bs=1", "seek=2", "conv=notrunc", "status=none"]),
            context: context(workspace: workspace)
        )
        let swab = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["conv=swab", "status=none"]),
            context: context(workspace: workspace, standardInput: Data("abcd".utf8))
        )
        let sync = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["bs=4", "conv=sync", "status=none"]),
            context: context(workspace: workspace, standardInput: Data("ab".utf8))
        )
        let help = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["--help"]),
            context: context(workspace: workspace)
        )
        let version = try await MSPDdCommand().run(
            invocation: MSPCommandInvocation(name: "dd", arguments: ["--version"]),
            context: context(workspace: workspace)
        )

        XCTAssertEqual(copy.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/copy.bin"], Data("abcd".utf8))
        XCTAssertEqual(skip.stdoutData, Data("cde".utf8))
        XCTAssertEqual(notrunc.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/out.bin"], Data("12ab56".utf8))
        XCTAssertEqual(swab.stdoutData, Data("badc".utf8))
        XCTAssertEqual(sync.stdoutData, Data([0x61, 0x62, 0x00, 0x00]))
        XCTAssertTrue(help.stdout.hasPrefix("Usage: dd [OPERAND]...\n"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertEqual(version.stdout, "dd (GNU coreutils) 9.1\n")
        XCTAssertEqual(version.exitCode, 0)
    }

    func testSplitWritesLineByteAndRoundRobinOutputs() async throws {
        let workspace = Core100DWorkspace(files: [
            "/in.txt": Data("1\n2\n3\n4\n".utf8)
        ])

        let lines = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(name: "split", arguments: ["-l", "2", "in.txt", "part-"]),
            context: context(workspace: workspace)
        )
        let bytes = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(name: "split", arguments: ["-b", "2", "-d", "-", "chunk-"]),
            context: context(workspace: workspace, standardInput: Data("abcdef".utf8))
        )
        let roundRobin = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(name: "split", arguments: ["-n", "r/3", "-", "rr-"]),
            context: context(workspace: workspace, standardInput: Data("abc".utf8))
        )

        XCTAssertEqual(lines.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/part-aa"], Data("1\n2\n".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/part-ab"], Data("3\n4\n".utf8))
        XCTAssertEqual(bytes.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/chunk-00"], Data("ab".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/chunk-01"], Data("cd".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/chunk-02"], Data("ef".utf8))
        XCTAssertEqual(roundRobin.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/rr-aa"], Data("abc".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/rr-ab"], Data())
        XCTAssertEqual(workspace.fileSystemBox.files["/rr-ac"], Data())
    }

    func testSplitSupportsLongAliasesSizeSuffixesLineBytesStartsAndElideEmpty() async throws {
        let workspace = Core100DWorkspace(files: [
            "/big.bin": Data(repeating: 0x61, count: 2050),
            "/records.txt": Data("aa\nbb\ncccc\n".utf8)
        ])

        let bytes = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(name: "split", arguments: ["--bytes=2K", "big.bin", "b-"]),
            context: context(workspace: workspace)
        )
        let lineBytes = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(name: "split", arguments: ["--line-bytes", "4", "records.txt", "lb-"]),
            context: context(workspace: workspace)
        )
        let numericStart = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(
                name: "split",
                arguments: ["--numeric-suffixes=3", "--suffix-length=2", "--bytes", "2", "-", "num-"]
            ),
            context: context(workspace: workspace, standardInput: Data("abcd".utf8))
        )
        let hexStart = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(
                name: "split",
                arguments: ["--hex-suffixes=10", "--suffix-length=2", "--bytes=2", "-", "hex-"]
            ),
            context: context(workspace: workspace, standardInput: Data("abcd".utf8))
        )
        let elideEmpty = try await MSPSplitCommand().run(
            invocation: MSPCommandInvocation(
                name: "split",
                arguments: ["--elide-empty-files", "--number=r/3", "-", "el-"]
            ),
            context: context(workspace: workspace, standardInput: Data("abc".utf8))
        )

        XCTAssertEqual(bytes.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/b-aa"]?.count, 2048)
        XCTAssertEqual(workspace.fileSystemBox.files["/b-ab"], Data("aa".utf8))
        XCTAssertEqual(lineBytes.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/lb-aa"], Data("aa\n".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/lb-ab"], Data("bb\n".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/lb-ac"], Data("cccc\n".utf8))
        XCTAssertEqual(numericStart.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/num-03"], Data("ab".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/num-04"], Data("cd".utf8))
        XCTAssertEqual(hexStart.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/hex-0a"], Data("ab".utf8))
        XCTAssertEqual(workspace.fileSystemBox.files["/hex-0b"], Data("cd".utf8))
        XCTAssertEqual(elideEmpty.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/el-aa"], Data("abc".utf8))
        XCTAssertNil(workspace.fileSystemBox.files["/el-ab"])
        XCTAssertNil(workspace.fileSystemBox.files["/el-ac"])
    }

    func testShufRandomSourceMatchesGNUReservoirSubset() async throws {
        let workspace = Core100DWorkspace(files: [
            "/random.bin": Data("0123456789abcdef".utf8),
            "/in.txt": Data("a\nb\nc\n".utf8)
        ])

        let file = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(name: "shuf", arguments: ["--random-source=random.bin", "in.txt"]),
            context: context(workspace: workspace)
        )
        let range = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(name: "shuf", arguments: ["--random-source=random.bin", "-i", "1-5"]),
            context: context(workspace: workspace)
        )
        let repeatOutput = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(name: "shuf", arguments: ["--random-source=random.bin", "-r", "-n", "5", "-e", "a", "b"]),
            context: context(workspace: workspace)
        )
        let reservoir = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(name: "shuf", arguments: ["--random-source=random.bin", "-n", "5"]),
            context: context(workspace: workspace, standardInput: Data("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n".utf8))
        )

        XCTAssertEqual(file.stdout, "a\nb\nc\n")
        XCTAssertEqual(range.stdout, "4\n3\n5\n1\n2\n")
        XCTAssertEqual(repeatOutput.stdout, "a\na\na\na\nb\n")
        XCTAssertEqual(reservoir.stdout, "10\n8\n9\n6\n4\n")
    }

    func testShufSupportsLongAliasesSpaceSeparatedValuesAndZeroTermination() async throws {
        let workspace = Core100DWorkspace(files: [
            "/random.bin": Data("0123456789abcdef".utf8)
        ])

        let repeatOutput = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(
                name: "shuf",
                arguments: ["--random-source", "random.bin", "--repeat", "--head-count", "3", "--echo", "a", "b"]
            ),
            context: context(workspace: workspace)
        )
        let range = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(
                name: "shuf",
                arguments: ["--random-source", "random.bin", "--input-range", "1-3", "--output", "out.txt"]
            ),
            context: context(workspace: workspace)
        )
        let zeroTerminated = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(
                name: "shuf",
                arguments: ["--random-source=random.bin", "--zero-terminated", "--echo", "only"]
            ),
            context: context(workspace: workspace)
        )
        let help = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(name: "shuf", arguments: ["--help"]),
            context: context(workspace: workspace)
        )
        let version = try await MSPShufCommand().run(
            invocation: MSPCommandInvocation(name: "shuf", arguments: ["--version"]),
            context: context(workspace: workspace)
        )

        XCTAssertEqual(repeatOutput.stdout, "a\na\na\n")
        XCTAssertEqual(range.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.files["/out.txt"], Data("1\n2\n3\n".utf8))
        XCTAssertEqual(zeroTerminated.stdoutData, Data("only\0".utf8))
        XCTAssertTrue(help.stdout.hasPrefix("Usage: shuf"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("shuf (GNU coreutils) 9.1"))
        XCTAssertEqual(version.exitCode, 0)
    }

    func testTsortSortsAndReportsCycleAndOddInput() async throws {
        let dag = try await MSPTsortCommand().run(
            invocation: MSPCommandInvocation(name: "tsort"),
            context: context(standardInput: Data("a b\nb c\n".utf8))
        )
        let cycle = try await MSPTsortCommand().run(
            invocation: MSPCommandInvocation(name: "tsort"),
            context: context(standardInput: Data("a b\nb a\n".utf8))
        )
        let odd = try await MSPTsortCommand().run(
            invocation: MSPCommandInvocation(name: "tsort"),
            context: context(standardInput: Data("a b c\n".utf8))
        )

        XCTAssertEqual(dag.stdout, "a\nb\nc\n")
        XCTAssertEqual(dag.exitCode, 0)
        XCTAssertEqual(cycle.stdout, "a\nb\n")
        XCTAssertEqual(cycle.stderr, "tsort: -: input contains a loop:\ntsort: a\ntsort: b\n")
        XCTAssertEqual(cycle.exitCode, 1)
        XCTAssertEqual(odd.stderr, "tsort: -: input contains an odd number of tokens\n")
        XCTAssertEqual(odd.exitCode, 1)
    }

    func testTsortDeduplicatesEdgesAndSupportsHelpVersion() async throws {
        let duplicateEdge = try await MSPTsortCommand().run(
            invocation: MSPCommandInvocation(name: "tsort"),
            context: context(standardInput: Data("a b\na b\n".utf8))
        )
        let help = try await MSPTsortCommand().run(
            invocation: MSPCommandInvocation(name: "tsort", arguments: ["--help"]),
            context: context()
        )
        let version = try await MSPTsortCommand().run(
            invocation: MSPCommandInvocation(name: "tsort", arguments: ["--version"]),
            context: context()
        )

        XCTAssertEqual(duplicateEdge.stdout, "a\nb\n")
        XCTAssertEqual(duplicateEdge.stderr, "")
        XCTAssertEqual(duplicateEdge.exitCode, 0)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tsort"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("tsort (GNU coreutils) 9.1"))
        XCTAssertEqual(version.exitCode, 0)
    }

    private func context(
        workspace: Core100DWorkspace? = nil,
        standardInput: Data = Data()
    ) -> MSPCommandContext {
        MSPCommandContext(workspace: workspace, standardInput: standardInput)
    }
}

private final class Core100DWorkspace: MSPWorkspace, @unchecked Sendable {
    let rootPath = "/"
    let fileSystemBox: Core100DWorkspaceFileSystem
    var fileSystem: any MSPWorkspaceFileSystem { fileSystemBox }

    init(files: [String: Data] = [:]) {
        self.fileSystemBox = Core100DWorkspaceFileSystem(files: files)
    }
}

private final class Core100DWorkspaceFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if let data = files[virtualPath] {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count), permissions: 0o644)
        }
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory, permissions: 0o755)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return files.keys.sorted().map { path in
            let name = String(path.dropFirst())
            return MSPDirectoryEntry(
                name: name,
                info: MSPFileInfo(virtualPath: path, type: .regularFile, size: Int64(files[path]?.count ?? 0), permissions: 0o644)
            )
        }
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        for entry in try listDirectory(path, from: currentDirectory) {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data {
        let data = try readFile(path, from: currentDirectory)
        guard length > 0, offset < UInt64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func writeFile(_ path: String, data: Data, from currentDirectory: String, options: MSPFileWriteOptions) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath] = data
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        try writeFile(path, data: data, from: currentDirectory, options: options)
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath, default: Data()].append(data)
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {}

    func createDirectory(
        _ path: String,
        from currentDirectory: String,
        intermediates: Bool,
        creationMode: UInt16?
    ) throws {}

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath, default: Data()] = files[virtualPath, default: Data()]
    }

    func touch(_ path: String, from currentDirectory: String, creationMode: UInt16?) throws {
        try touch(path, from: currentDirectory)
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files.removeValue(forKey: virtualPath)
    }

    func copy(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileCopyOptions) throws {
        files[try resolve(destinationPath, from: currentDirectory).virtualPath] = try readFile(sourcePath, from: currentDirectory)
    }

    func move(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileMoveOptions) throws {
        let data = try readFile(sourcePath, from: currentDirectory)
        try remove(sourcePath, from: currentDirectory, recursive: false)
        files[try resolve(destinationPath, from: currentDirectory).virtualPath] = data
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try copy(sourcePath, to: linkPath, from: currentDirectory, options: [])
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: linkPath, operation: "symlink")
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {}
}
