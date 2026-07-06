import Foundation
import XCTest
import ModelShellProxy

final class ModelShellProxyRedirectionTests: ModelShellProxyIntegrationTestCase {
    func testRedirectionsRunThroughWorkspaceFSAndSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let outputAndInput = await shell.run("printf 'one\\n' > out.txt; printf 'two\\n' >> out.txt; cat < out.txt")
        let stderrFile = await shell.run("missing-command 2> err.txt; cat err.txt")
        let bothFile = await shell.run("printf 'merged\\n' &> both.txt; cat both.txt")
        let redirectionOnly = await shell.run("> empty.txt; stat -c %s empty.txt")
        let stderrToStdout = await shell.run("missing-command 2>&1")
        let stdoutToStderr = await shell.run("printf out 1>&2")
        let fdOrderKeepsStderrOnOriginalStdout = await shell.run("missing-command 2>&1 > order.txt; cat order.txt")
        let fdOrderMergesStderrIntoFile = await shell.run("missing-command > merged.txt 2>&1; cat merged.txt")
        let readWriteCreatesFile = await shell.run("cat <> created.txt; stat -c %s created.txt")
        let hereDocument = await shell.run("""
        cat <<EOF | wc -c
        abc
        EOF
        """)

        XCTAssertEqual(outputAndInput.stdout, "one\ntwo\n")
        XCTAssertEqual(outputAndInput.stderr, "")
        XCTAssertEqual(outputAndInput.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("out.txt"), encoding: .utf8),
            "one\ntwo\n"
        )
        XCTAssertEqual(stderrFile.stdout, "missing-command: command not found\n")
        XCTAssertEqual(stderrFile.stderr, "")
        XCTAssertEqual(stderrFile.exitCode, 0)
        XCTAssertEqual(bothFile.stdout, "merged\n")
        XCTAssertEqual(bothFile.stderr, "")
        XCTAssertEqual(bothFile.exitCode, 0)
        XCTAssertEqual(redirectionOnly.stdout, "0\n")
        XCTAssertEqual(redirectionOnly.stderr, "")
        XCTAssertEqual(redirectionOnly.exitCode, 0)
        XCTAssertEqual(stderrToStdout.stdout, "missing-command: command not found\n")
        XCTAssertEqual(stderrToStdout.stderr, "")
        XCTAssertEqual(stderrToStdout.exitCode, 127)
        XCTAssertEqual(stdoutToStderr.stdout, "")
        XCTAssertEqual(stdoutToStderr.stderr, "out")
        XCTAssertEqual(stdoutToStderr.exitCode, 0)
        XCTAssertEqual(fdOrderKeepsStderrOnOriginalStdout.stdout, "missing-command: command not found\n")
        XCTAssertEqual(fdOrderKeepsStderrOnOriginalStdout.stderr, "")
        XCTAssertEqual(fdOrderKeepsStderrOnOriginalStdout.exitCode, 0)
        XCTAssertEqual(fdOrderMergesStderrIntoFile.stdout, "missing-command: command not found\n")
        XCTAssertEqual(fdOrderMergesStderrIntoFile.stderr, "")
        XCTAssertEqual(fdOrderMergesStderrIntoFile.exitCode, 0)
        XCTAssertEqual(readWriteCreatesFile.stdout, "0\n")
        XCTAssertEqual(readWriteCreatesFile.stderr, "")
        XCTAssertEqual(readWriteCreatesFile.exitCode, 0)
        XCTAssertEqual(hereDocument.stdout, "4\n")
        XCTAssertEqual(hereDocument.stderr, "")
        XCTAssertEqual(hereDocument.exitCode, 0)
        XCTAssertFalse(outputAndInput.stdout.contains(rootURL.path))
        XCTAssertFalse(stderrFile.stdout.contains(rootURL.path))
        XCTAssertFalse(bothFile.stdout.contains(rootURL.path))
        XCTAssertFalse(stderrToStdout.stdout.contains(rootURL.path))
        XCTAssertFalse(fdOrderKeepsStderrOnOriginalStdout.stdout.contains(rootURL.path))
        XCTAssertFalse(fdOrderMergesStderrIntoFile.stdout.contains(rootURL.path))
    }

    func testAppendRedirectionDoesNotReadExistingFileBeforeWriting() async throws {
        let fileSystem = RedirectionRecordingFileSystem(files: [
            "/out.txt": Data("old\n".utf8)
        ])
        let shell = ModelShellProxy(configuration: MSPConfiguration(
            workspace: RedirectionRecordingWorkspace(fileSystem: fileSystem)
        ))
        try shell.register("emit") { _, _ in
            .success(stdout: "new\n")
        }

        let result = await shell.run("emit >> out.txt")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.string(at: "/out.txt"), "old\nnew\n")
        XCTAssertEqual(fileSystem.readFilePaths, [])
        XCTAssertEqual(fileSystem.appendFilePayloads, [Data("new\n".utf8)])
        XCTAssertEqual(fileSystem.writeFilePayloads, [])
    }

    func testStreamingFileRedirectionAppendsDirectlyToWorkspaceFile() async throws {
        let fileSystem = RedirectionRecordingFileSystem()
        let shell = try ModelShellProxy(configuration: MSPConfiguration(
            workspace: RedirectionRecordingWorkspace(fileSystem: fileSystem)
        ))
        .enable(.posixCore)

        let result = await shell.run("yes chunk | head -n 3 > out.txt")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.string(at: "/out.txt"), "chunk\nchunk\nchunk\n")
        XCTAssertEqual(fileSystem.readFilePaths, [])
        XCTAssertEqual(fileSystem.writeFilePayloads, [Data()])
        XCTAssertFalse(fileSystem.appendFilePayloads.isEmpty)
    }

    func testClosedStandardInputIsNotTreatedAsEmptyInput() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let catClosed = await shell.run("cat <&-")
        XCTAssertEqual(catClosed.stdout, "")
        XCTAssertEqual(catClosed.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(catClosed.exitCode, 1)

        let wcClosed = await shell.run("wc -c <&-")
        XCTAssertEqual(wcClosed.stdout, "")
        XCTAssertEqual(wcClosed.stderr, "wc: stdin: Bad file descriptor\n")
        XCTAssertEqual(wcClosed.exitCode, 1)

        let readClosed = await shell.run("read value <&-; printf 'status:%s value:%s\\n' \"$?\" \"$value\"")
        XCTAssertEqual(readClosed.stdout, "status:1 value:\n")
        XCTAssertEqual(readClosed.stderr, "read: 0: read error: Bad file descriptor\n")
        XCTAssertEqual(readClosed.exitCode, 0)

        let duplicatePersistentClosed = await shell.run("exec <&-; exec 3<&0")
        XCTAssertEqual(duplicatePersistentClosed.stdout, "")
        XCTAssertEqual(duplicatePersistentClosed.stderr, "shell: 0: Bad file descriptor\n")
        XCTAssertEqual(duplicatePersistentClosed.exitCode, 1)

        let duplicateScopedClosed = await shell.run("exec <&-; cat 3<&0")
        XCTAssertEqual(duplicateScopedClosed.stdout, "")
        XCTAssertEqual(duplicateScopedClosed.stderr, "shell: 0: Bad file descriptor\n")
        XCTAssertEqual(duplicateScopedClosed.exitCode, 1)

        let readDuplicateClosed = await shell.run("exec <&-; read -u 3 value 3<&0; printf 'status:%s value:%s\\n' \"$?\" \"$value\"")
        XCTAssertEqual(readDuplicateClosed.stdout, "status:1 value:\n")
        XCTAssertEqual(readDuplicateClosed.stderr, "shell: 0: Bad file descriptor\n")
        XCTAssertEqual(readDuplicateClosed.exitCode, 0)

        let groupClosed = await shell.run("{ cat; } <&-")
        XCTAssertEqual(groupClosed.stdout, "")
        XCTAssertEqual(groupClosed.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(groupClosed.exitCode, 1)

        let catClosedOutput = await shell.run("printf 'abc' > input.txt; cat input.txt >&-")
        XCTAssertEqual(catClosedOutput.stdout, "")
        XCTAssertEqual(catClosedOutput.stderr, "cat: standard output: Bad file descriptor\n")
        XCTAssertEqual(catClosedOutput.exitCode, 1)

        let nullOutput = await shell.run("printf 'abc' >/dev/null")
        XCTAssertEqual(nullOutput.stdout, "")
        XCTAssertEqual(nullOutput.stderr, "")
        XCTAssertEqual(nullOutput.exitCode, 0)

        let pipelineNullOutput = await shell.run("printf 'copy\\n' | tee copy.txt >/dev/null; cat copy.txt")
        XCTAssertEqual(pipelineNullOutput.stdout, "copy\n")
        XCTAssertEqual(pipelineNullOutput.stderr, "")
        XCTAssertEqual(pipelineNullOutput.exitCode, 0)

        let nullInput = await shell.run("cat < /dev/null")
        XCTAssertEqual(nullInput.stdout, "")
        XCTAssertEqual(nullInput.stderr, "")
        XCTAssertEqual(nullInput.exitCode, 0)
        XCTAssertFalse(catClosed.stderr.contains(rootURL.path))
        XCTAssertFalse(groupClosed.stderr.contains(rootURL.path))
        XCTAssertFalse(catClosedOutput.stderr.contains(rootURL.path))
    }

    func testExecPersistentRedirectionsRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "input\n".write(
            to: rootURL.appendingPathComponent("input.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "first\nsecond\n".write(
            to: rootURL.appendingPathComponent("lines.txt"),
            atomically: true,
            encoding: .utf8
        )

        let stdoutShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let redirectStdout = await stdoutShell.run("exec > out.txt; echo one")
        let redirectStdoutSecondRun = await stdoutShell.run("echo two")

        XCTAssertEqual(redirectStdout.stdout, "")
        XCTAssertEqual(redirectStdout.stderr, "")
        XCTAssertEqual(redirectStdout.exitCode, 0)
        XCTAssertEqual(redirectStdoutSecondRun.stdout, "")
        XCTAssertEqual(redirectStdoutSecondRun.stderr, "")
        XCTAssertEqual(redirectStdoutSecondRun.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("out.txt"), encoding: .utf8),
            "one\ntwo\n"
        )

        let mergedShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let merged = await mergedShell.run("exec > merged.txt 2>&1; echo out; missing-command")
        XCTAssertEqual(merged.stdout, "")
        XCTAssertEqual(merged.stderr, "")
        XCTAssertEqual(merged.exitCode, 127)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("merged.txt"), encoding: .utf8),
            "out\nmissing-command: command not found\n"
        )

        let pipelineShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let pipeline = await pipelineShell.run("exec > pipe.txt; printf 'abc' | wc -c")
        XCTAssertEqual(pipeline.stdout, "")
        XCTAssertEqual(pipeline.stderr, "")
        XCTAssertEqual(pipeline.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("pipe.txt"), encoding: .utf8),
            "3\n"
        )

        let stderrPipeShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        try stderrPipeShell.register("both") { _, _ in
            .failure(exitCode: 7, stdout: "out", stderr: "err")
        }
        let stderrPipe = await stderrPipeShell.run("exec 2> persistent-err.txt; both |& wc -c")
        XCTAssertEqual(stderrPipe.stdout, "6\n")
        XCTAssertEqual(stderrPipe.stderr, "")
        XCTAssertEqual(stderrPipe.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("persistent-err.txt"), encoding: .utf8),
            ""
        )

        let substitutionShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let substitution = await substitutionShell.run(#"exec > substitution.txt; printf '<%s>\n' "$(echo sub)""#)
        XCTAssertEqual(substitution.stdout, "")
        XCTAssertEqual(substitution.stderr, "")
        XCTAssertEqual(substitution.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("substitution.txt"), encoding: .utf8),
            "<sub>\n"
        )

        let stdinShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let stdin = await stdinShell.run("exec < input.txt; cat")
        XCTAssertEqual(stdin.stdout, "input\n")
        XCTAssertEqual(stdin.stderr, "")
        XCTAssertEqual(stdin.exitCode, 0)
        XCTAssertFalse(stdin.stdout.contains(rootURL.path))

        let outputFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let outputFd = await outputFdShell.run("exec 3> fd-out.txt; echo one >&3; printf two >&3; exec 3>&-; cat fd-out.txt")
        XCTAssertEqual(outputFd.stdout, "one\ntwo")
        XCTAssertEqual(outputFd.stderr, "")
        XCTAssertEqual(outputFd.exitCode, 0)
        XCTAssertFalse(outputFd.stdout.contains(rootURL.path))

        let pipelineExecFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let pipelineExecFd = await pipelineExecFdShell.run("exec 3> pipeline-leak.txt | cat; printf after >&3")
        XCTAssertEqual(pipelineExecFd.stdout, "")
        XCTAssertTrue(pipelineExecFd.stderr.contains("Bad file descriptor"))
        XCTAssertEqual(pipelineExecFd.exitCode, 1)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("pipeline-leak.txt"), encoding: .utf8),
            ""
        )

        let inputFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let inputFd = await inputFdShell.run("exec 3< lines.txt; read -u 3 a; read -u 3 b; printf '%s/%s/%s\\n' \"$a\" \"$b\" \"$?\"")
        XCTAssertEqual(inputFd.stdout, "first/second/0\n")
        XCTAssertEqual(inputFd.stderr, "")
        XCTAssertEqual(inputFd.exitCode, 0)
        XCTAssertFalse(inputFd.stdout.contains(rootURL.path))

        let duplicatedInputFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let duplicatedInputFd = await duplicatedInputFdShell.run("exec 3< lines.txt; exec 4<&3; read -u 3 a; read -u 4 b; printf '%s/%s\\n' \"$a\" \"$b\"")
        XCTAssertEqual(duplicatedInputFd.stdout, "first/second\n")
        XCTAssertEqual(duplicatedInputFd.stderr, "")
        XCTAssertEqual(duplicatedInputFd.exitCode, 0)
        XCTAssertFalse(duplicatedInputFd.stdout.contains(rootURL.path))

        let readWriteOffsetShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let readWriteOffset = await readWriteOffsetShell.run("printf abc > rw.txt; exec 3<> rw.txt; read -n 1 -u 3 a; printf Z >&3; exec 3<&-; cat rw.txt")
        XCTAssertEqual(readWriteOffset.stdout, "aZc")
        XCTAssertEqual(readWriteOffset.stderr, "")
        XCTAssertEqual(readWriteOffset.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("rw.txt"), encoding: .utf8),
            "aZc"
        )
        XCTAssertFalse(readWriteOffset.stdout.contains(rootURL.path))

        let readWriteCreatesWritableFileShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let readWriteCreatesWritableFile = await readWriteCreatesWritableFileShell.run("exec 3<> new-rw.txt; printf hi >&3; exec 3>&-; cat new-rw.txt")
        XCTAssertEqual(readWriteCreatesWritableFile.stdout, "hi")
        XCTAssertEqual(readWriteCreatesWritableFile.stderr, "")
        XCTAssertEqual(readWriteCreatesWritableFile.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("new-rw.txt"), encoding: .utf8),
            "hi"
        )
        XCTAssertFalse(readWriteCreatesWritableFile.stdout.contains(rootURL.path))

        let duplicatedReadWriteOutputFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let duplicatedReadWriteOutputFd = await duplicatedReadWriteOutputFdShell.run("printf abc > dup-output-rw.txt; exec 3<> dup-output-rw.txt; exec 4>&3; read -n 1 -u 4 a; printf X >&3; exec 3>&-; exec 4>&-; cat dup-output-rw.txt")
        XCTAssertEqual(duplicatedReadWriteOutputFd.stdout, "aXc")
        XCTAssertEqual(duplicatedReadWriteOutputFd.stderr, "")
        XCTAssertEqual(duplicatedReadWriteOutputFd.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("dup-output-rw.txt"), encoding: .utf8),
            "aXc"
        )
        XCTAssertFalse(duplicatedReadWriteOutputFd.stdout.contains(rootURL.path))

        let duplicatedReadWriteInputFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let duplicatedReadWriteInputFd = await duplicatedReadWriteInputFdShell.run("printf abc > dup-input-rw.txt; exec 3<> dup-input-rw.txt; exec 4<&3; read -n 1 -u 4 a; printf X >&4; exec 3>&-; exec 4>&-; cat dup-input-rw.txt")
        XCTAssertEqual(duplicatedReadWriteInputFd.stdout, "aXc")
        XCTAssertEqual(duplicatedReadWriteInputFd.stderr, "")
        XCTAssertEqual(duplicatedReadWriteInputFd.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("dup-input-rw.txt"), encoding: .utf8),
            "aXc"
        )
        XCTAssertFalse(duplicatedReadWriteInputFd.stdout.contains(rootURL.path))

        let readWriteStdoutShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let readWriteStdout = await readWriteStdoutShell.run("printf abc > stdout-rw.txt; printf Z 1<> stdout-rw.txt; cat stdout-rw.txt")
        XCTAssertEqual(readWriteStdout.stdout, "Zbc")
        XCTAssertEqual(readWriteStdout.stderr, "")
        XCTAssertEqual(readWriteStdout.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("stdout-rw.txt"), encoding: .utf8),
            "Zbc"
        )
        XCTAssertFalse(readWriteStdout.stdout.contains(rootURL.path))
    }

    func testScopedRedirectionsOverlayPersistentFileDescriptors() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "input\n".write(
            to: rootURL.appendingPathComponent("input.txt"),
            atomically: true,
            encoding: .utf8
        )

        let groupShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let group = await groupShell.run("exec > outer.txt; { echo group; } > group.txt; echo after")
        XCTAssertEqual(group.stdout, "")
        XCTAssertEqual(group.stderr, "")
        XCTAssertEqual(group.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("outer.txt"), encoding: .utf8),
            "after\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("group.txt"), encoding: .utf8),
            "group\n"
        )

        let nestedExecShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let nestedExec = await nestedExecShell.run("exec > scoped-outer.txt; { exec > scoped-inner.txt; echo inner; } > scoped-group.txt; echo after")
        XCTAssertEqual(nestedExec.stdout, "")
        XCTAssertEqual(nestedExec.stderr, "")
        XCTAssertEqual(nestedExec.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("scoped-outer.txt"), encoding: .utf8),
            "after\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("scoped-inner.txt"), encoding: .utf8),
            "inner\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("scoped-group.txt"), encoding: .utf8),
            ""
        )

        let inputOnlyShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let inputOnly = await inputOnlyShell.run("exec > input-outer.txt; { exec > input-inner.txt; cat; } < input.txt; echo after")
        XCTAssertEqual(inputOnly.stdout, "")
        XCTAssertEqual(inputOnly.stderr, "")
        XCTAssertEqual(inputOnly.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("input-outer.txt"), encoding: .utf8),
            ""
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("input-inner.txt"), encoding: .utf8),
            "input\nafter\n"
        )

        let functionDefinitionShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let functionDefinition = await functionDefinitionShell.run("exec > function-outer.txt; f() { echo fn; } > function-def.txt; f; echo after")
        XCTAssertEqual(functionDefinition.stdout, "")
        XCTAssertEqual(functionDefinition.stderr, "")
        XCTAssertEqual(functionDefinition.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("function-outer.txt"), encoding: .utf8),
            "after\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("function-def.txt"), encoding: .utf8),
            "fn\n"
        )

        let functionCallShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let functionCall = await functionCallShell.run("exec > function-call-outer.txt; f() { echo fn; }; f > function-call.txt; echo after")
        XCTAssertEqual(functionCall.stdout, "")
        XCTAssertEqual(functionCall.stderr, "")
        XCTAssertEqual(functionCall.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("function-call-outer.txt"), encoding: .utf8),
            "after\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("function-call.txt"), encoding: .utf8),
            "fn\n"
        )

        let definitionBeatsCallShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let definitionBeatsCall = await definitionBeatsCallShell.run("exec > definition-call-outer.txt; f() { echo fn; } > definition-wins.txt; f > call-loses.txt; echo after")
        XCTAssertEqual(definitionBeatsCall.stdout, "")
        XCTAssertEqual(definitionBeatsCall.stderr, "")
        XCTAssertEqual(definitionBeatsCall.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("definition-call-outer.txt"), encoding: .utf8),
            "after\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("definition-wins.txt"), encoding: .utf8),
            "fn\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("call-loses.txt"), encoding: .utf8),
            ""
        )

        let scopedFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let scopedFd = await scopedFdShell.run("echo scoped 3> scoped-fd.txt >&3; cat scoped-fd.txt")
        XCTAssertEqual(scopedFd.stdout, "scoped\n")
        XCTAssertEqual(scopedFd.stderr, "")
        XCTAssertEqual(scopedFd.exitCode, 0)
        XCTAssertFalse(scopedFd.stdout.contains(rootURL.path))

        let groupFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let groupFd = await groupFdShell.run("{ printf group >&3; } 3> group-fd.txt; cat group-fd.txt")
        XCTAssertEqual(groupFd.stdout, "group")
        XCTAssertEqual(groupFd.stderr, "")
        XCTAssertEqual(groupFd.exitCode, 0)
        XCTAssertFalse(groupFd.stdout.contains(rootURL.path))

        let groupFdLeakShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let groupFdLeak = await groupFdLeakShell.run("{ exec 4> group-inner-fd.txt; printf group >&3; } 3> group-fd-scope.txt; printf after >&4; cat group-fd-scope.txt; printf '|'; cat group-inner-fd.txt")
        XCTAssertEqual(groupFdLeak.stdout, "group|after")
        XCTAssertEqual(groupFdLeak.stderr, "")
        XCTAssertEqual(groupFdLeak.exitCode, 0)
        XCTAssertFalse(groupFdLeak.stdout.contains(rootURL.path))

        let groupReadWriteFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let groupReadWriteFd = await groupReadWriteFdShell.run("printf abc > group-rw.txt; { read -n 1 -u 3 a; printf Z >&3; } 3<> group-rw.txt; cat group-rw.txt")
        XCTAssertEqual(groupReadWriteFd.stdout, "aZc")
        XCTAssertEqual(groupReadWriteFd.stderr, "")
        XCTAssertEqual(groupReadWriteFd.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("group-rw.txt"), encoding: .utf8),
            "aZc"
        )
        XCTAssertFalse(groupReadWriteFd.stdout.contains(rootURL.path))

        let functionCallFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let functionCallFd = await functionCallFdShell.run("f() { printf fn >&3; }; f 3> function-call-fd.txt; cat function-call-fd.txt")
        XCTAssertEqual(functionCallFd.stdout, "fn")
        XCTAssertEqual(functionCallFd.stderr, "")
        XCTAssertEqual(functionCallFd.exitCode, 0)
        XCTAssertFalse(functionCallFd.stdout.contains(rootURL.path))

        let functionDefinitionFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let functionDefinitionFd = await functionDefinitionFdShell.run("f() { printf fddef >&3; } 3> function-def-fd.txt; f; cat function-def-fd.txt")
        XCTAssertEqual(functionDefinitionFd.stdout, "fddef")
        XCTAssertEqual(functionDefinitionFd.stderr, "")
        XCTAssertEqual(functionDefinitionFd.exitCode, 0)
        XCTAssertFalse(functionDefinitionFd.stdout.contains(rootURL.path))

        let evalFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let evalFd = await evalFdShell.run("eval 'printf eval >&3' 3> eval-fd.txt; cat eval-fd.txt")
        XCTAssertEqual(evalFd.stdout, "eval")
        XCTAssertEqual(evalFd.stderr, "")
        XCTAssertEqual(evalFd.exitCode, 0)
        XCTAssertFalse(evalFd.stdout.contains(rootURL.path))

        let sourceFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let sourceFd = await sourceFdShell.run("printf 'printf source >&3\\n' > script.sh; . script.sh 3> source-fd.txt; cat source-fd.txt")
        XCTAssertEqual(sourceFd.stdout, "source")
        XCTAssertEqual(sourceFd.stderr, "")
        XCTAssertEqual(sourceFd.exitCode, 0)
        XCTAssertFalse(sourceFd.stdout.contains(rootURL.path))

        let shellLauncherFdShell = try ModelShellProxy.iOS(workspaceURL: rootURL).enable(.posixCore)
        let shellLauncherFd = await shellLauncherFdShell.run("sh -c 'printf shell >&3' 3> shell-launcher-fd.txt; cat shell-launcher-fd.txt")
        XCTAssertEqual(shellLauncherFd.stdout, "shell")
        XCTAssertEqual(shellLauncherFd.stderr, "")
        XCTAssertEqual(shellLauncherFd.exitCode, 0)
        XCTAssertFalse(shellLauncherFd.stdout.contains(rootURL.path))
    }

}

private struct RedirectionRecordingWorkspace: MSPWorkspace {
    var rootPath: String { "/" }
    let fileSystem: any MSPWorkspaceFileSystem
}

private final class RedirectionRecordingFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private var files: [String: Data]

    private(set) var readFilePaths: [String] = []
    private(set) var writeFilePayloads: [Data] = []
    private(set) var appendFilePayloads: [Data] = []

    init(files: [String: Data] = [:]) {
        self.files = files
    }

    func string(at path: String) -> String? {
        files[path].map { String(decoding: $0, as: UTF8.self) }
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: normalized(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = normalized(path, from: currentDirectory)
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: "/", type: .directory, permissions: 0o755)
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
        let virtualPath = normalized(path, from: currentDirectory)
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        return files.keys.sorted().map { filePath in
            let name = String(filePath.dropFirst())
            return MSPDirectoryEntry(
                name: name,
                info: MSPFileInfo(
                    virtualPath: filePath,
                    type: .regularFile,
                    size: Int64(files[filePath]?.count ?? 0),
                    permissions: 0o644
                )
            )
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(normalized(path, from: currentDirectory))
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = normalized(path, from: currentDirectory)
        readFilePaths.append(virtualPath)
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func writeFile(_ path: String, data: Data, from currentDirectory: String, options: MSPFileWriteOptions) throws {
        let virtualPath = normalized(path, from: currentDirectory)
        try ensureRootParent(for: virtualPath)
        if files[virtualPath] != nil, !options.contains(.overwriteExisting) {
            throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
        }
        writeFilePayloads.append(data)
        files[virtualPath] = data
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        let virtualPath = normalized(path, from: currentDirectory)
        try ensureRootParent(for: virtualPath)
        appendFilePayloads.append(data)
        var existing = files[virtualPath] ?? Data()
        existing.append(data)
        files[virtualPath] = existing
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = normalized(path, from: currentDirectory)
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = normalized(path, from: currentDirectory)
        try ensureRootParent(for: virtualPath)
        files[virtualPath, default: Data()] = files[virtualPath] ?? Data()
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = normalized(path, from: currentDirectory)
        guard files.removeValue(forKey: virtualPath) != nil else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
    }

    func copy(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileCopyOptions) throws {
        let source = normalized(sourcePath, from: currentDirectory)
        let destination = normalized(destinationPath, from: currentDirectory)
        guard let data = files[source] else {
            throw MSPWorkspaceFileSystemError.notFound(source)
        }
        files[destination] = data
    }

    func move(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileMoveOptions) throws {
        try copy(sourcePath, to: destinationPath, from: currentDirectory, options: [])
        try remove(sourcePath, from: currentDirectory, recursive: false)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try copy(sourcePath, to: linkPath, from: currentDirectory, options: [])
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: normalized(linkPath, from: currentDirectory), operation: "symlink")
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {}

    private func normalized(_ path: String, from currentDirectory: String) -> String {
        MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
    }

    private func ensureRootParent(for path: String) throws {
        let parent = parentPath(of: path)
        guard parent == "/" else {
            throw MSPWorkspaceFileSystemError.notDirectory(parent)
        }
    }

    private func parentPath(of path: String) -> String {
        guard path != "/" else {
            return "/"
        }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.contains("/") else {
            let components = path.split(separator: "/").dropLast()
            return "/" + components.joined(separator: "/")
        }
        return "/"
    }
}
