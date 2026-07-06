import Foundation
import MSPAgentBridge
import Photos
import XCTest
@testable import PhotoSorter

final class PhotoSorterPythonRuntimeTests: XCTestCase {
    @MainActor
    func testPhotoSorterShellRegistersPython3ThroughSDKRuntime() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: ["--msp-cpython-library-path="],
            environment: [:]
        )

        let result = await runtime.run("python3 -c 'print(42)'")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.exitCode, 126)
        XCTAssertTrue(result.stderr.contains("python3: embedded Python engine unavailable"))
        XCTAssertTrue(result.stderr.contains("CPython library is not configured"))
        XCTAssertFalse(result.stderr.contains("command not found"))
    }

    @MainActor
    func testPhotoSorterShellRunsConfiguredCPythonRuntime() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for this smoke test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterConfiguredPythonRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let python3 = await runtime.run("python3 -c 'print(42)'")
        let python = await runtime.run("python -c 'print(43)'")

        XCTAssertEqual(python3.stdout, "42\n")
        XCTAssertEqual(python3.stderr, "")
        XCTAssertEqual(python3.exitCode, 0)
        XCTAssertEqual(python.stdout, "43\n")
        XCTAssertEqual(python.stderr, "")
        XCTAssertEqual(python.exitCode, 0)
    }

    @MainActor
    func testPhotoSorterExecSessionPythonReceivesLiveWriteStdin() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter exec-session stdin test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonExecSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )
        let bridge = runtime.execCommandBridge()
        let command = """
        python3 -u -c 'import sys,time; print("READY", flush=True); line=sys.stdin.readline().strip(); print("GOT:" + line, flush=True); time.sleep(0.1); print("DONE", flush=True)'
        """

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            yieldTimeMilliseconds: 250
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.exitCode, nil)
        var transcript = start.result.stdout
        var stderr = start.result.stderr
        var readySessionID: Int? = sessionID
        var readyPollCount = 0
        while !transcript.contains("READY\n"),
              let runningSessionID = readySessionID,
              readyPollCount < 8 {
            let poll = await bridge.readSession(
                sessionID: runningSessionID,
                waitMilliseconds: 250
            )
            transcript += poll.result.stdout
            stderr += poll.result.stderr
            readySessionID = poll.runningSessionID
            readyPollCount += 1
        }

        let liveSessionID = try XCTUnwrap(readySessionID, transcript + stderr)
        XCTAssertEqual(stderr, "")
        XCTAssertTrue(transcript.contains("READY\n"), transcript)
        XCTAssertFalse(transcript.contains("GOT:"), transcript)

        var final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: liveSessionID,
            chars: "hello from photosorter\n",
            yieldTimeMilliseconds: 1_000
        ))
        transcript += final.result.stdout
        stderr += final.result.stderr
        var pollCount = 0
        while let runningSessionID = final.runningSessionID, pollCount < 8 {
            final = await bridge.readSession(
                sessionID: runningSessionID,
                waitMilliseconds: 1_000
            )
            transcript += final.result.stdout
            stderr += final.result.stderr
            pollCount += 1
        }

        XCTAssertNil(final.runningSessionID, transcript + stderr)
        XCTAssertEqual(final.exitCode, 0, transcript + stderr)
        XCTAssertEqual(stderr, "")
        XCTAssertTrue(transcript.contains("GOT:hello from photosorter\n"), transcript)
        XCTAssertTrue(transcript.contains("DONE\n"), transcript)
    }

    @MainActor
    func testPhotoSorterExecSessionInteractivePythonReceivesLiveWriteStdin() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter interactive exec-session test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonInteractiveExecSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )
        let bridge = runtime.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "python3 -i -q",
            yieldTimeMilliseconds: 100
        ))
        let sessionID: Int = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.exitCode, nil)
        XCTAssertEqual(start.result.stderr, "")

        var final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "print(\"PHOTOSORTER_INTERACTIVE_READY\")\nprint(6 * 7)\nexit()\n",
            yieldTimeMilliseconds: 1_000
        ))
        var transcript = start.result.stdout + final.result.stdout
        var stderr = final.result.stderr
        var pollCount = 0
        while let runningSessionID = final.runningSessionID, pollCount < 8 {
            final = await bridge.readSession(
                sessionID: runningSessionID,
                waitMilliseconds: 1_000
            )
            transcript += final.result.stdout
            stderr += final.result.stderr
            pollCount += 1
        }

        XCTAssertNil(final.runningSessionID, transcript + stderr)
        XCTAssertEqual(final.exitCode, 0, transcript + stderr)
        XCTAssertEqual(stderr, "")
        XCTAssertTrue(transcript.contains("PHOTOSORTER_INTERACTIVE_READY\n"), transcript)
        XCTAssertTrue(transcript.contains("42\n"), transcript)
    }

    @MainActor
    func testPhotoSorterPythonUsesVirtualWorkspaceForTmpPhotoReadsAndSubprocesses() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter Python VFS integration test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonVFSIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let indexURL = rootURL
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("photo-library-index.json")
        let ocrCacheURL = rootURL
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("photo-library-ocr-cache.json")
        let placeCacheURL = rootURL
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("photo-library-place-cache.json")
        let overlayURL = rootURL
            .appendingPathComponent("Overlay", isDirectory: true)
            .appendingPathComponent("photo-library-workspace-overlay.json")
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let assetIdentifier = "asset-a"
        let assetRecord = Self.manifestAssetRecord(identifier: assetIdentifier, fileExtension: "jpg")
        let fileName = try XCTUnwrap(PhotoLibraryMount.assetFileNames(for: [assetRecord])[assetIdentifier])
        let savedToken = Data([0x01])
        let indexStore = PhotoLibraryIndexPersistentStore(fileURL: indexURL)
        try indexStore.save(Self.snapshot(assetRecord: assetRecord, fileName: fileName, tokenData: savedToken))

        let manifestProvider = CountingPhotoLibraryManifestProvider()
        manifestProvider.currentTokenData = savedToken
        manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: savedToken,
            changeCount: 0
        )
        manifestProvider.resourceDataByLocalIdentifier[assetIdentifier] = Data("photo-bytes".utf8)
        let mount = PhotoLibraryMount(
            indexStore: indexStore,
            ocrCache: PhotoSorterMediaOCRCache(fileURL: ocrCacheURL),
            placeCache: PhotoSorterMediaPlaceCache(fileURL: placeCacheURL),
            workspaceOverlay: PhotoLibraryWorkspaceOverlay(
                store: PhotoLibraryWorkspaceOverlayStore(fileURL: overlayURL)
            ),
            diagnosticsLog: nil,
            manifestProvider: manifestProvider
        )

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: mount,
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let directFind = await runtime.run("find /图库 -maxdepth 1 -type f")
        XCTAssertEqual(directFind.exitCode, 0, directFind.stderr)
        XCTAssertEqual(directFind.stderr, "")
        XCTAssertEqual(directFind.stdout, "/图库/\(fileName)\n")

        let script = """
        python3 - <<'PY'
        from pathlib import Path
        import subprocess

        Path("/tmp/a.txt").write_text("scratch", encoding="utf-8")
        print(Path("/tmp/a.txt").read_text(encoding="utf-8").strip())
        print(open("/图库/\(fileName)", "rb").read().decode("utf-8"))
        print(subprocess.check_output(["find", "/图库", "-maxdepth", "1", "-type", "f"]).decode("utf-8").strip())
        PY
        """

        let result = await runtime.run(script)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "scratch\nphoto-bytes\n/图库/\(fileName)\n")
        XCTAssertEqual(manifestProvider.resourceDataRequestLocalIdentifiers, [assetIdentifier])
        XCTAssertEqual(manifestProvider.makeManifestCallCount, 0)
        XCTAssertFalse(result.stdout.contains(workspaceURL.path))
        XCTAssertFalse(result.stderr.contains(workspaceURL.path))
    }

    @MainActor
    func testPhotoSorterPythonVFSCanRunRepeatedEmbeddedInvocations() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the repeated Python VFS test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterRepeatedPythonVFSTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let first = await runtime.run("""
        python3 - <<'PY'
        from pathlib import Path
        Path("/tmp/first.txt").write_text("first", encoding="utf-8")
        print(Path("/tmp/first.txt").read_text(encoding="utf-8"))
        PY
        """)
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        XCTAssertEqual(first.stderr, "")
        XCTAssertEqual(first.stdout, "first\n")

        let second = await runtime.run("""
        python3 - <<'PY'
        from pathlib import Path
        import subprocess

        Path("/tmp/second.txt").write_text("second", encoding="utf-8")
        print(Path("/tmp/second.txt").read_text(encoding="utf-8"))
        find_output = subprocess.check_output(
            ["find", "/tmp", "-maxdepth", "1", "-type", "f"],
            text=True
        )
        print("find=" + ",".join(sorted(find_output.splitlines())))
        print("host=\(workspaceURL.path)/tmp/second.txt")
        PY
        """)

        XCTAssertEqual(second.exitCode, 0, second.stderr)
        XCTAssertEqual(second.stderr, "")
        XCTAssertEqual(second.stdout, """
        second
        find=/tmp/first.txt,/tmp/second.txt
        host=/tmp/second.txt

        """)
        XCTAssertFalse((first.stdout + first.stderr + second.stdout + second.stderr).contains(workspaceURL.path))
    }

    @MainActor
    func testPhotoSorterPythonVirtualizesCoreWorkspaceAPIs() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the core Python VFS surface test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonCoreVFSTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let pipedInput = await runtime.run(
            "printf 'pipe-data' | python3 -S -E -I -c 'import sys; print(sys.stdin.read())'"
        )
        XCTAssertEqual(pipedInput.stdout, "pipe-data\n")
        XCTAssertEqual(pipedInput.stderr, "")
        XCTAssertEqual(pipedInput.exitCode, 0)

        let result = await runtime.run("""
        python3 -S -E -I - arg1 <<'PY'
        from pathlib import Path
        import os
        import shutil
        import sys

        Path("/regular.txt").write_text("regular\\n", encoding="utf-8")
        Path("/tmp/nested").mkdir(parents=True, exist_ok=True)
        Path("/tmp/a.txt").write_text("alpha\\n", encoding="utf-8")
        with os.scandir("/tmp") as entries:
            scan = sorted(entry.name + ":" + ("d" if entry.is_dir() else "f") for entry in entries)

        print("cwd=" + os.getcwd())
        print("home=" + os.environ.get("HOME", ""))
        print("tmpdir=" + os.environ.get("TMPDIR", ""))
        print("path=" + os.environ.get("PATH", ""))
        print("argv0=" + sys.argv[0])
        print("regular=" + Path("/regular.txt").read_text(encoding="utf-8").strip())
        print("list=" + ",".join(sorted(os.listdir("/tmp"))))
        print("scan=" + ",".join(scan))
        print("stat=" + str(os.stat("/tmp/a.txt").st_size))
        print("exists=" + str(Path("/tmp/a.txt").exists()))
        os.chdir("/tmp/nested")
        print("cwd2=" + os.getcwd())
        shutil.copyfile("../a.txt", "copy.txt")
        print("copy=" + Path("/tmp/nested/copy.txt").read_text(encoding="utf-8").strip())
        print("glob=" + ",".join(sorted(str(path) for path in Path("/tmp").glob("*.txt"))))
        print("rglob=" + ",".join(sorted(str(path) for path in Path("/tmp").rglob("*.txt"))))
        PY
        """)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, """
        cwd=/
        home=/
        tmpdir=/tmp
        path=/usr/bin:/bin
        argv0=-
        regular=regular
        list=a.txt,nested
        scan=a.txt:f,nested:d
        stat=6
        exists=True
        cwd2=/tmp/nested
        copy=alpha
        glob=/tmp/a.txt
        rglob=/tmp/a.txt,/tmp/nested/copy.txt

        """)
        XCTAssertFalse(result.stdout.contains(workspaceURL.path))
        XCTAssertEqual(
            try String(contentsOf: workspaceURL.appendingPathComponent("regular.txt"), encoding: .utf8),
            "regular\n"
        )
    }

    @MainActor
    func testPhotoSorterPythonScriptFileUsesVirtualWorkspace() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter Python script-entrypoint test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonScriptFileTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let result = await runtime.run("""
        cat > /tmp/photo-script.py <<'PY'
        from pathlib import Path
        import os
        import subprocess
        import sys

        Path("/tmp/script-output.txt").write_text("script:" + sys.argv[1], encoding="utf-8")
        print("argv0=" + sys.argv[0])
        print("cwd=" + os.getcwd())
        print("read=" + Path("/tmp/script-output.txt").read_text(encoding="utf-8"))
        print("internal_env=" + ",".join(sorted(key for key in os.environ if key.startswith("MSP_PYTHON_"))))
        find_output = subprocess.check_output(
            ["find", "/tmp", "-maxdepth", "1", "-type", "f"],
            text=True
        )
        print("find=" + ",".join(sorted(find_output.splitlines())))
        print("host=\(workspaceURL.path)/tmp/photo-script.py")
        print("err=\(workspaceURL.path)/tmp/script-output.txt", file=sys.stderr)
        sys.stdout.flush()
        sys.stderr.flush()
        sys.stdout.buffer.write(b"buffer_out=\(workspaceURL.path)/tmp/photo-script.py\\n")
        sys.stderr.buffer.write(b"buffer_err=\(workspaceURL.path)/tmp/script-output.txt\\n")
        PY
        python3 -S -E -I /tmp/photo-script.py value
        """)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        argv0=/tmp/photo-script.py
        cwd=/
        read=script:value
        internal_env=
        find=/tmp/photo-script.py,/tmp/script-output.txt
        host=/tmp/photo-script.py
        buffer_out=/tmp/photo-script.py

        """)
        XCTAssertEqual(result.stderr, """
        err=/tmp/script-output.txt
        buffer_err=/tmp/script-output.txt

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(workspaceURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))
    }

    @MainActor
    func testPhotoSorterPythonTracebackHidesBootstrapFrames() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the traceback virtualization test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonTracebackTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let result = await runtime.run("""
        python3 - <<'PY'
        open("/tmp/missing.txt")
        PY
        """)

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Traceback (most recent call last):"), result.stderr)
        XCTAssertTrue(result.stderr.contains("File \"<stdin>\", line 1, in <module>"), result.stderr)
        XCTAssertTrue(result.stderr.contains("FileNotFoundError"), result.stderr)
        XCTAssertTrue(result.stderr.contains("'/tmp/missing.txt'"), result.stderr)
        XCTAssertFalse(result.stderr.contains(workspaceURL.path), result.stderr)
        XCTAssertFalse(result.stderr.contains("File \"<string>\""), result.stderr)
        XCTAssertFalse(result.stderr.contains("_msp_vfs"), result.stderr)
        XCTAssertFalse(result.stderr.contains("_msp_cpython"), result.stderr)
    }

    @MainActor
    func testPhotoSorterPythonRejectsDirectPhotoBinaryOverwriteWithVirtualPathError() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter Python write-denial test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonWriteDenialTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        let indexURL = rootURL
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("photo-library-index.json")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let assetIdentifier = "asset-a"
        let assetRecord = Self.manifestAssetRecord(identifier: assetIdentifier, fileExtension: "jpg")
        let fileName = try XCTUnwrap(PhotoLibraryMount.assetFileNames(for: [assetRecord])[assetIdentifier])
        try PhotoLibraryIndexPersistentStore(fileURL: indexURL).save(Self.snapshot(
            assetRecord: assetRecord,
            fileName: fileName
        ))

        let manifestProvider = CountingPhotoLibraryManifestProvider()
        let mount = PhotoLibraryMount(
            indexStore: PhotoLibraryIndexPersistentStore(fileURL: indexURL),
            ocrCache: PhotoSorterMediaOCRCache(fileURL: rootURL.appendingPathComponent("ocr-cache.json")),
            placeCache: PhotoSorterMediaPlaceCache(fileURL: rootURL.appendingPathComponent("place-cache.json")),
            workspaceOverlay: PhotoLibraryWorkspaceOverlay(store: nil),
            diagnosticsLog: nil,
            manifestProvider: manifestProvider
        )
        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: mount,
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let result = await runtime.run("""
        python3 - <<'PY'
        from pathlib import Path
        Path("/图库/\(fileName)").write_bytes(b"overwrite")
        PY
        """)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("/图库/\(fileName)"), result.stderr)
        XCTAssertFalse(result.stderr.contains(workspaceURL.path))
        XCTAssertEqual(manifestProvider.resourceDataRequestLocalIdentifiers, [])
    }

    @MainActor
    func testPhotoSorterPythonAssetTrashAndRestoreUseWorkspaceOverlay() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter Python overlay mutation test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonAssetOverlayTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        let indexURL = rootURL
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("photo-library-index.json")
        let overlayURL = rootURL
            .appendingPathComponent("Overlay", isDirectory: true)
            .appendingPathComponent("photo-library-workspace-overlay.json")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileName = "4f4fb263cf16.jpg"
        let savedToken = Data([0x01])
        try PhotoLibraryIndexPersistentStore(fileURL: indexURL).save(Self.snapshot(
            assetRecords: [(identifier: "asset-a", fileName: fileName, mediaType: .image)],
            tokenData: savedToken
        ))

        let manifestProvider = CountingPhotoLibraryManifestProvider()
        manifestProvider.currentTokenData = savedToken
        manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: savedToken,
            changeCount: 0
        )
        manifestProvider.resourceDataByLocalIdentifier["asset-a"] = Data("photo-bytes".utf8)
        let mount = PhotoLibraryMount(
            indexStore: PhotoLibraryIndexPersistentStore(fileURL: indexURL),
            ocrCache: PhotoSorterMediaOCRCache(fileURL: rootURL.appendingPathComponent("ocr-cache.json")),
            placeCache: PhotoSorterMediaPlaceCache(fileURL: rootURL.appendingPathComponent("place-cache.json")),
            workspaceOverlay: PhotoLibraryWorkspaceOverlay(
                store: PhotoLibraryWorkspaceOverlayStore(fileURL: overlayURL)
            ),
            diagnosticsLog: nil,
            manifestProvider: manifestProvider
        )

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: mount,
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let result = await runtime.run("""
        python3 - <<'PY'
        from pathlib import Path
        import os
        import shutil

        path = "/图库/\(fileName)"
        os.remove(path)
        print("gallery_exists=" + str(Path(path).exists()))
        print("trash_list=" + ",".join(sorted(os.listdir("/最近删除"))))
        print("trash_read=" + open("/最近删除/\(fileName)", "rb").read().decode("utf-8"))
        shutil.move("/最近删除/\(fileName)", path)
        print("restored=" + str(Path(path).exists()))
        print("trash_root=" + ",".join(sorted(os.listdir("/最近删除"))))
        PY
        """)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, """
        gallery_exists=False
        trash_list=\(fileName)
        trash_read=photo-bytes
        restored=True
        trash_root=

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(workspaceURL.path))
        XCTAssertFalse(mount.photoLibraryWorkspaceChangeSummary.hasChanges)
        XCTAssertEqual(manifestProvider.applyWorkspaceChangesCallCount, 0)
        XCTAssertEqual(manifestProvider.resourceDataRequestLocalIdentifiers, ["asset-a"])
    }

    @MainActor
    func testPhotoSorterPythonAlbumAndMembershipMutationsUseWorkspaceOverlay() async throws {
        guard let library = Self.availableCPythonLibrary() else {
            throw XCTSkip("A bundled or configured CPython runtime is required for the PhotoSorter Python album overlay test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterPythonAlbumOverlayTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
        let indexURL = rootURL
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("photo-library-index.json")
        let overlayURL = rootURL
            .appendingPathComponent("Overlay", isDirectory: true)
            .appendingPathComponent("photo-library-workspace-overlay.json")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let albumPath = "/相册/用户/旅行"
        let targetAlbumPath = "/相册/用户/整理"
        let imageFileName = "4f4fb263cf16.jpg"
        let videoFileName = "ca8d29b0d08a.mov"
        let savedToken = Data([0x01])
        try PhotoLibraryIndexPersistentStore(fileURL: indexURL).save(Self.snapshot(
            assetRecords: [
                (identifier: "asset-a", fileName: imageFileName, mediaType: .image),
                (identifier: "asset-b", fileName: videoFileName, mediaType: .video)
            ],
            tokenData: savedToken,
            additionalAssetDirectoryPaths: [albumPath],
            userAlbumPaths: [albumPath]
        ))

        let manifestProvider = CountingPhotoLibraryManifestProvider()
        manifestProvider.currentTokenData = savedToken
        manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: savedToken,
            changeCount: 0
        )
        let mount = PhotoLibraryMount(
            indexStore: PhotoLibraryIndexPersistentStore(fileURL: indexURL),
            ocrCache: PhotoSorterMediaOCRCache(fileURL: rootURL.appendingPathComponent("ocr-cache.json")),
            placeCache: PhotoSorterMediaPlaceCache(fileURL: rootURL.appendingPathComponent("place-cache.json")),
            workspaceOverlay: PhotoLibraryWorkspaceOverlay(
                store: PhotoLibraryWorkspaceOverlayStore(fileURL: overlayURL)
            ),
            diagnosticsLog: nil,
            manifestProvider: manifestProvider
        )

        var environment = [
            "MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PHOTOSORTER_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: workspaceURL,
            photoLibraryMount: mount,
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: [],
            environment: environment
        )

        let result = await runtime.run("""
        python3 - <<'PY'
        from pathlib import Path
        import os
        import shutil

        source_album = "\(albumPath)"
        target_album = "\(targetAlbumPath)"
        print("initial=" + ",".join(sorted(os.listdir(source_album))))
        shutil.rmtree(source_album)
        print("album_exists=" + str(Path(source_album).exists()))
        print("trash_album=" + ",".join(sorted(os.listdir("/最近删除/旅行"))))
        shutil.move("/最近删除/旅行", source_album)
        print("restored=" + ",".join(sorted(os.listdir(source_album))))
        os.makedirs(target_album)
        shutil.move("/图库/\(imageFileName)", target_album + "/\(imageFileName)")
        print("user_albums=" + ",".join(sorted(os.listdir("/相册/用户"))))
        print("target=" + ",".join(sorted(os.listdir(target_album))))
        PY
        """)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, """
        initial=\(imageFileName),\(videoFileName)
        album_exists=False
        trash_album=\(imageFileName),\(videoFileName)
        restored=\(imageFileName),\(videoFileName)
        user_albums=整理,旅行
        target=\(imageFileName)

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(workspaceURL.path))
        XCTAssertEqual(mount.photoLibraryWorkspaceChangeSummary.pendingAlbumCreationCount, 1)
        XCTAssertEqual(mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 1)
        XCTAssertEqual(mount.photoLibraryWorkspaceChangeSummary.deletedAlbumCount, 0)
        XCTAssertEqual(mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 0)
        XCTAssertEqual(manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    private static func configuredCPythonLibrary() -> ConfiguredCPythonLibrary? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawPath = environment["MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        let homeURL = environment["MSP_PHOTOSORTER_CPYTHON_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            .map(URL.init(fileURLWithPath:))
        return ConfiguredCPythonLibrary(
            libraryURL: URL(fileURLWithPath: rawPath),
            homeURL: homeURL
        )
    }

    private static func availableCPythonLibrary() -> ConfiguredCPythonLibrary? {
        configuredCPythonLibrary() ?? bundledCPythonLibrary()
    }

    private static func bundledCPythonLibrary() -> ConfiguredCPythonLibrary? {
        let candidateBundleURLs = [
            containingAppBundleURL(startingAt: Bundle.main.bundleURL),
            containingAppBundleURL(startingAt: Bundle(for: PhotoSorterPythonRuntimeTests.self).bundleURL)
        ].compactMap { $0 }
        for bundleURL in candidateBundleURLs {
            let libraryURL = bundleURL
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent("Python.framework", isDirectory: true)
                .appendingPathComponent("Python")
            guard FileManager.default.fileExists(atPath: libraryURL.path) else {
                continue
            }
            let homeURL = bundleURL.appendingPathComponent("python", isDirectory: true)
            return ConfiguredCPythonLibrary(
                libraryURL: libraryURL,
                homeURL: FileManager.default.fileExists(atPath: homeURL.path) ? homeURL : nil
            )
        }
        return nil
    }

    private static func containingAppBundleURL(startingAt url: URL) -> URL? {
        var current = url
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func snapshot(
        assetRecord: PhotoLibraryManifestAssetRecord,
        fileName: String,
        tokenData: Data? = nil
    ) -> PhotoLibraryIndexSnapshot {
        let galleryPath = "/图库"
        let directories = [
            galleryPath: PhotoLibraryIndexDirectory(
                name: "图库",
                path: galleryPath,
                parentPath: "/",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: [],
                assetLocalIdentifiers: [assetRecord.localIdentifier],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            )
        ]
        let asset = PhotoLibraryIndexAsset(
            localIdentifier: assetRecord.localIdentifier,
            fileName: fileName,
            fileExtension: assetRecord.fileExtension,
            mediaTypeRawValue: assetRecord.mediaTypeRawValue,
            mediaSubtypesRawValue: assetRecord.mediaSubtypesRawValue,
            pixelWidth: assetRecord.pixelWidth,
            pixelHeight: assetRecord.pixelHeight,
            creationDate: assetRecord.creationDate,
            modificationDate: assetRecord.modificationDate
        )
        return PhotoLibraryIndexSnapshot.make(
            authorizationStatusRawValue: PHAuthorizationStatus.authorized.rawValue,
            version: 1,
            directories: directories,
            assetsByLocalIdentifier: [assetRecord.localIdentifier: asset],
            photoLibraryChangeTokenData: tokenData
        )
    }

    private static func snapshot(
        assetRecords: [(identifier: String, fileName: String, mediaType: PHAssetMediaType)],
        tokenData: Data? = nil,
        additionalAssetDirectoryPaths: [String] = [],
        userAlbumPaths: [String] = []
    ) -> PhotoLibraryIndexSnapshot {
        let normalizedUserAlbumPaths = Array(Set(
            userAlbumPaths
                + additionalAssetDirectoryPaths.filter { path in
                    PhotoLibraryMount.normalizeVirtualPath(path)
                        .hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/")
                }
        ))
        .map(PhotoLibraryMount.normalizeVirtualPath)
        .sorted()
        let assetIdentifiers = assetRecords.map(\.identifier)
        var directories: [String: PhotoLibraryIndexDirectory] = [
            "/图库": PhotoLibraryIndexDirectory(
                name: "图库",
                path: "/图库",
                parentPath: "/",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: [],
                assetLocalIdentifiers: assetIdentifiers,
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            ),
            "/相册": PhotoLibraryIndexDirectory(
                name: "相册",
                path: "/相册",
                parentPath: "/",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: [PhotoLibraryMount.systemAlbumRootPath, PhotoLibraryMount.userAlbumRootPath],
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: true
            ),
            PhotoLibraryMount.systemAlbumRootPath: PhotoLibraryIndexDirectory(
                name: "系统",
                path: PhotoLibraryMount.systemAlbumRootPath,
                parentPath: PhotoLibraryMount.albumRootPath,
                collectionLocalIdentifier: nil,
                childDirectoryPaths: PhotoLibraryMount.systemAlbumDirectoryPaths,
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: true
            ),
            PhotoLibraryMount.userAlbumRootPath: PhotoLibraryIndexDirectory(
                name: "用户",
                path: PhotoLibraryMount.userAlbumRootPath,
                parentPath: PhotoLibraryMount.albumRootPath,
                collectionLocalIdentifier: nil,
                childDirectoryPaths: normalizedUserAlbumPaths,
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: !normalizedUserAlbumPaths.isEmpty
            )
        ]
        for path in PhotoLibraryMount.systemAlbumDirectoryPaths {
            directories[path] = PhotoLibraryIndexDirectory(
                name: path.split(separator: "/").last.map(String.init) ?? "系统相册",
                path: path,
                parentPath: PhotoLibraryMount.systemAlbumRootPath,
                collectionLocalIdentifier: nil,
                childDirectoryPaths: [],
                assetLocalIdentifiers: additionalAssetDirectoryPaths
                    .map(PhotoLibraryMount.normalizeVirtualPath)
                    .contains(path) ? assetIdentifiers : [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            )
        }
        for path in normalizedUserAlbumPaths {
            directories[path] = PhotoLibraryIndexDirectory(
                name: path.split(separator: "/").last.map(String.init) ?? "用户相册",
                path: path,
                parentPath: PhotoLibraryMount.userAlbumRootPath,
                collectionLocalIdentifier: "album:\(path)",
                childDirectoryPaths: [],
                assetLocalIdentifiers: additionalAssetDirectoryPaths
                    .map(PhotoLibraryMount.normalizeVirtualPath)
                    .contains(path) ? assetIdentifiers : [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            )
        }

        let assetsByLocalIdentifier = Dictionary(uniqueKeysWithValues: assetRecords.enumerated().map { index, record in
            let fileExtension = URL(fileURLWithPath: record.fileName).pathExtension.lowercased()
            return (
                record.identifier,
                PhotoLibraryIndexAsset(
                    localIdentifier: record.identifier,
                    fileName: record.fileName,
                    fileExtension: fileExtension.isEmpty ? "jpg" : fileExtension,
                    mediaTypeRawValue: record.mediaType.rawValue,
                    mediaSubtypesRawValue: 0,
                    pixelWidth: 4032,
                    pixelHeight: 3024,
                    creationDate: Date(timeIntervalSince1970: Double(index)),
                    modificationDate: nil
                )
            )
        })
        return PhotoLibraryIndexSnapshot.make(
            authorizationStatusRawValue: PHAuthorizationStatus.authorized.rawValue,
            version: 1,
            directories: directories,
            assetsByLocalIdentifier: assetsByLocalIdentifier,
            photoLibraryChangeTokenData: tokenData
        )
    }

    private static func manifestAssetRecord(
        identifier: String,
        fileExtension: String
    ) -> PhotoLibraryManifestAssetRecord {
        PhotoLibraryManifestAssetRecord(
            localIdentifier: identifier,
            fileExtension: fileExtension,
            mediaTypeRawValue: PHAssetMediaType.image.rawValue,
            mediaSubtypesRawValue: 0,
            pixelWidth: 4032,
            pixelHeight: 3024,
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: nil
        )
    }
}

private struct ConfiguredCPythonLibrary {
    var libraryURL: URL
    var homeURL: URL?
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
