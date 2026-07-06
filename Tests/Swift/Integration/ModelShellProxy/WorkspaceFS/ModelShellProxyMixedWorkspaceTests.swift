import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonRuntime

final class ModelShellProxyMixedWorkspaceTests: ModelShellProxyIntegrationTestCase {
    func testShellPythonAndSubprocessShareMixedHostAndVirtualBackends() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for mixed workspace Python tests.")
        }

        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("host-doc\n".utf8).write(to: rootURL.appendingPathComponent("docs/host.txt"))

        let virtualMedia = MixedWorkspaceMemoryFileSystem(files: [
            "/clip.txt": Data("virtual-media\n".utf8)
        ])
        let hostWorkspace = try MSPAppleWorkspace(rootURL: rootURL)
        let mixedWorkspace = MSPCompositeWorkspace(
            baseFileSystem: hostWorkspace.fileSystem,
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: virtualMedia)
            ]
        )
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: mixedWorkspace))
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        cat /docs/host.txt /media/clip.txt
        printf 'generated\\n' > /tmp/generated.txt
        python3 -S - <<'PY'
        from pathlib import Path
        import subprocess

        print('py-doc=' + Path('/docs/host.txt').read_text(encoding='utf-8').strip())
        print('py-media=' + Path('/media/clip.txt').read_text(encoding='utf-8').strip())
        Path('/media/from-python.txt').write_text('virtual-write\\n', encoding='utf-8')
        child = subprocess.check_output(['cat', '/media/from-python.txt'], text=True)
        print('subprocess=' + child.strip())
        listing = subprocess.check_output(
            ['find', '/media', '-maxdepth', '1', '-type', 'f'],
            text=True
        ).splitlines()
        print('find=' + ','.join(sorted(listing)))
        Path('/tmp/chain').mkdir(exist_ok=True)
        Path('/tmp/chain/z.txt').write_text('z\\n', encoding='utf-8')
        Path('/tmp/chain/a.txt').write_text('a\\n', encoding='utf-8')
        p1 = subprocess.Popen(
            ['find', '.', '-maxdepth', '1', '-type', 'f'],
            cwd='/tmp/chain',
            stdout=subprocess.PIPE,
            text=True
        )
        p2 = subprocess.Popen(
            ['sort'],
            cwd='/tmp/chain',
            stdin=p1.stdout,
            stdout=subprocess.PIPE,
            text=True
        )
        p1.stdout.close()
        pipe_out, _ = p2.communicate(timeout=5)
        print('pipe-chain=%r' % ((p1.wait(timeout=5), p2.returncode, pipe_out),))
        after = subprocess.check_output(['python3', '-S', '-c', 'print(789)'], text=True).strip()
        print('after-chain=' + after)
        PY
        cat /media/from-python.txt
        cat /tmp/generated.txt
        printf 'temp\\n' > /media/delete-me.tmp
        find /media -maxdepth 1 -type f -name '*.tmp' -delete
        test ! -e /media/delete-me.tmp
        printf 'delete-ok\\n'
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        host-doc
        virtual-media
        py-doc=host-doc
        py-media=virtual-media
        subprocess=virtual-write
        find=/media/clip.txt,/media/from-python.txt
        pipe-chain=(0, 0, './a.txt\\n./z.txt\\n')
        after-chain=789
        virtual-write
        generated
        delete-ok

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/generated.txt"), encoding: .utf8),
            "generated\n"
        )
        XCTAssertEqual(
            try String(decoding: virtualMedia.readFile("/from-python.txt", from: "/"), as: UTF8.self),
            "virtual-write\n"
        )
        XCTAssertThrowsError(try virtualMedia.readFile("/delete-me.tmp", from: "/"))
    }

    func testShellRangeReadsLazyRemoteMountBeforePythonFullRead() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for lazy remote workspace Python tests.")
        }

        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )

        let prefix = "remote-lazy-start\n"
        let suffix = "remote-lazy-end\n"
        var remoteData = Data(prefix.utf8)
        remoteData.append(Data(repeating: UInt8(ascii: "x"), count: 128 * 1024))
        remoteData.append(Data(suffix.utf8))
        let lazyRemote = LazyRemoteWorkspaceFileSystem(files: [
            "/big.txt": remoteData
        ])
        let hostWorkspace = try MSPAppleWorkspace(rootURL: rootURL)
        let mixedWorkspace = MSPCompositeWorkspace(
            baseFileSystem: hostWorkspace.fileSystem,
            mounts: [
                MSPWorkspaceMount(path: "/remote", fileSystem: lazyRemote)
            ]
        )
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: mixedWorkspace))
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: rootURL
            )))

        let shellResult = await shell.run("""
        printf 'stat='
        stat -c %s /remote/big.txt
        printf 'head='
        head -c \(prefix.utf8.count) /remote/big.txt
        printf 'tail='
        tail -c \(suffix.utf8.count) /remote/big.txt
        find /remote -maxdepth 1 -type f | sort
        """)

        XCTAssertEqual(shellResult.stderr, "")
        XCTAssertEqual(shellResult.exitCode, 0, shellResult.stderr)
        XCTAssertEqual(shellResult.stdout, """
        stat=\(remoteData.count)
        head=remote-lazy-start
        tail=remote-lazy-end
        /remote/big.txt

        """)
        XCTAssertEqual(lazyRemote.readFileCallCount, 0)
        XCTAssertGreaterThanOrEqual(lazyRemote.readFileRangeCallCount, 2)
        XCTAssertLessThan(lazyRemote.maxReadFileRangeLength, remoteData.count)

        let subprocessRangeResult = await shell.run("""
        python3 -S - <<'PY'
        import subprocess

        head = subprocess.check_output(
            ['head', '-c', '\(prefix.utf8.count)', '/remote/big.txt'],
            text=True
        )
        tail = subprocess.check_output(
            ['tail', '-c', '\(suffix.utf8.count)', '/remote/big.txt'],
            text=True
        )
        print('subprocess-head=' + head, end='')
        print('subprocess-tail=' + tail, end='')
        PY
        """)

        XCTAssertEqual(subprocessRangeResult.stderr, "")
        XCTAssertEqual(subprocessRangeResult.exitCode, 0, subprocessRangeResult.stderr)
        XCTAssertEqual(subprocessRangeResult.stdout, """
        subprocess-head=remote-lazy-start
        subprocess-tail=remote-lazy-end

        """)
        XCTAssertEqual(lazyRemote.readFileCallCount, 0)
        XCTAssertGreaterThanOrEqual(lazyRemote.readFileRangeCallCount, 4)
        XCTAssertLessThan(lazyRemote.maxReadFileRangeLength, remoteData.count)

        let pythonResult = await shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path
        text = Path('/remote/big.txt').read_text(encoding='utf-8')
        print('py-prefix=' + text.splitlines()[0])
        print('py-bytes=' + str(len(text.encode('utf-8'))))
        PY
        """)

        XCTAssertEqual(pythonResult.stderr, "")
        XCTAssertEqual(pythonResult.exitCode, 0, pythonResult.stderr)
        XCTAssertEqual(pythonResult.stdout, """
        py-prefix=remote-lazy-start
        py-bytes=\(remoteData.count)

        """)
        XCTAssertEqual(lazyRemote.readFileCallCount, 1)

        let modelVisibleOutput = shellResult.stdout + shellResult.stderr
            + subprocessRangeResult.stdout + subprocessRangeResult.stderr
            + pythonResult.stdout + pythonResult.stderr
        XCTAssertFalse(modelVisibleOutput.contains(rootURL.path))
        XCTAssertFalse(modelVisibleOutput.contains("vfs-broker"))
        XCTAssertFalse(modelVisibleOutput.contains("vfs-materialized"))
        XCTAssertFalse(modelVisibleOutput.contains("subprocess-broker"))
        XCTAssertFalse(modelVisibleOutput.contains("remoteData"))
    }
}

private final class LazyRemoteWorkspaceFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private let files: [String: Data]
    private let directories: Set<String>
    private let counterLock = NSLock()
    private var storedReadFileCallCount = 0
    private var storedReadFileRangeCallCount = 0
    private var storedMaxReadFileRangeLength = 0

    var readFileCallCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return storedReadFileCallCount
    }

    var readFileRangeCallCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return storedReadFileRangeCallCount
    }

    var maxReadFileRangeLength: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return storedMaxReadFileRangeLength
    }

    init(files: [String: Data]) {
        self.files = Dictionary(uniqueKeysWithValues: files.map { path, data in
            (MSPWorkspacePathResolver.normalize(path), data)
        })
        var directories: Set<String> = ["/"]
        for path in self.files.keys {
            var parent = Self.parentPath(of: path)
            while parent != "/" {
                directories.insert(parent)
                parent = Self.parentPath(of: parent)
            }
        }
        self.directories = directories
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory, permissions: 0o755)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPFileInfo(
            virtualPath: virtualPath,
            type: .regularFile,
            size: Int64(data.count),
            permissions: 0o644
        )
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard directories.contains(virtualPath) else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        let childPaths = Set(
            files.keys.filter { Self.parentPath(of: $0) == virtualPath }
                + directories.filter { $0 != "/" && Self.parentPath(of: $0) == virtualPath }
        )
        return policy.directoryOrdering.ordered(try childPaths.map { childPath in
            MSPDirectoryEntry(name: Self.name(of: childPath), info: try stat(childPath, from: "/"))
        })
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        counterLock.lock()
        storedReadFileCallCount += 1
        counterLock.unlock()
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func readFileRange(
        _ path: String,
        from currentDirectory: String,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        counterLock.lock()
        storedReadFileRangeCallCount += 1
        storedMaxReadFileRangeLength = max(storedMaxReadFileRangeLength, length)
        counterLock.unlock()
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        guard length > 0, offset < UInt64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(path, from: currentDirectory).virtualPath)
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(path, from: currentDirectory).virtualPath)
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(path, from: currentDirectory).virtualPath)
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(path, from: currentDirectory).virtualPath)
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(destinationPath, from: currentDirectory).virtualPath)
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(destinationPath, from: currentDirectory).virtualPath)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(linkPath, from: currentDirectory).virtualPath)
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(try resolve(linkPath, from: currentDirectory).virtualPath)
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        _ = try stat(path, from: currentDirectory)
    }

    private static func parentPath(of path: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard normalized != "/" else {
            return "/"
        }
        let components = MSPWorkspacePathResolver.components(in: normalized).dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func name(of path: String) -> String {
        MSPWorkspacePathResolver.components(in: path).last ?? ""
    }
}

private final class MixedWorkspaceMemoryFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private var directories: Set<String>
    private var files: [String: Data]

    init(files: [String: Data] = [:]) {
        self.files = Dictionary(uniqueKeysWithValues: files.map { key, value in
            (MSPWorkspacePathResolver.normalize(key), value)
        })
        self.directories = ["/"]
        for path in self.files.keys {
            var parent = Self.parentPath(of: path)
            while parent != "/" {
                directories.insert(parent)
                parent = Self.parentPath(of: parent)
            }
        }
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory, permissions: 0o755)
        }
        if let data = files[virtualPath] {
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .regularFile,
                size: Int64(data.count),
                permissions: 0o644
            )
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard directories.contains(virtualPath) else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        let childPaths = Set(
            files.keys.filter { Self.parentPath(of: $0) == virtualPath }
                + directories.filter { $0 != "/" && Self.parentPath(of: $0) == virtualPath }
        )
        return policy.directoryOrdering.ordered(try childPaths.map { childPath in
            MSPDirectoryEntry(name: Self.name(of: childPath), info: try stat(childPath, from: "/"))
        })
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        let parent = Self.parentPath(of: virtualPath)
        if options.contains(.createParentDirectories) {
            try createDirectory(parent, from: "/", intermediates: true)
        }
        guard directories.contains(parent) else {
            throw MSPWorkspaceFileSystemError.notDirectory(parent)
        }
        if files[virtualPath] != nil, !options.contains(.overwriteExisting) {
            throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
        }
        files[virtualPath] = data
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if virtualPath == "/" {
            return
        }
        let parent = Self.parentPath(of: virtualPath)
        if !directories.contains(parent) {
            guard intermediates else {
                throw MSPWorkspaceFileSystemError.notDirectory(parent)
            }
            try createDirectory(parent, from: "/", intermediates: true)
        }
        directories.insert(virtualPath)
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if files[virtualPath] == nil {
            try writeFile(virtualPath, data: Data(), from: "/", options: [])
        }
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if files.removeValue(forKey: virtualPath) != nil {
            return
        }
        guard directories.contains(virtualPath), virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        let hasChildren = files.keys.contains { Self.parentPath(of: $0) == virtualPath }
            || directories.contains(where: { $0 != virtualPath && Self.parentPath(of: $0) == virtualPath })
        if hasChildren, !recursive {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        files = files.filter { !$0.key.hasPrefix(virtualPath + "/") }
        directories = directories.filter { $0 == "/" || ($0 != virtualPath && !$0.hasPrefix(virtualPath + "/")) }
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        let data = try readFile(sourcePath, from: currentDirectory)
        try writeFile(
            destinationPath,
            data: data,
            from: currentDirectory,
            options: options.contains(.overwriteExisting) ? [.overwriteExisting] : []
        )
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        try copy(
            sourcePath,
            to: destinationPath,
            from: currentDirectory,
            options: options.contains(.overwriteExisting) ? [.overwriteExisting] : []
        )
        try remove(sourcePath, from: currentDirectory, recursive: false)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try copy(sourcePath, to: linkPath, from: currentDirectory, options: [])
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(
            path: try resolve(linkPath, from: currentDirectory).virtualPath,
            operation: "symlink"
        )
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        _ = try stat(path, from: currentDirectory)
    }

    private static func parentPath(of path: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard normalized != "/" else {
            return "/"
        }
        let components = MSPWorkspacePathResolver.components(in: normalized).dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func name(of path: String) -> String {
        MSPWorkspacePathResolver.components(in: path).last ?? ""
    }
}
