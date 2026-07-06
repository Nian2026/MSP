import Foundation
import XCTest
import MSPCore
import ModelShellProxy

final class ModelShellProxyRuntimeBuiltinAdapterTests: ModelShellProxyIntegrationTestCase {
    func testMapfileLimitedReadsAdvanceFileDescriptorCursor() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "zero\none\ntwo\nthree\n".write(
            to: rootURL.appendingPathComponent("input.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let limited = await shell.run("""
        exec 3< input.txt
        mapfile -t -n 2 -u 3 chunk
        read -r -u 3 next
        printf 'chunk:<%s>\\n' "${chunk[@]}"
        printf 'next:%s\\n' "$next"
        """)
        let skipped = await shell.run("""
        exec 3< input.txt
        mapfile -t -s 1 -n 2 -u 3 chunk
        read -r -u 3 next
        printf 'chunk:<%s>\\n' "${chunk[@]}"
        printf 'next:%s\\n' "$next"
        """)

        XCTAssertEqual(limited.stdout, "chunk:<zero>\nchunk:<one>\nnext:two\n")
        XCTAssertEqual(limited.stderr, "")
        XCTAssertEqual(limited.exitCode, 0)
        XCTAssertEqual(skipped.stdout, "chunk:<one>\nchunk:<two>\nnext:three\n")
        XCTAssertEqual(skipped.stderr, "")
        XCTAssertEqual(skipped.exitCode, 0)
    }

    func testExitTrapPreservesModelContentItems() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        try shell.register("emit-model") { _, _ in
            .success(modelContentItems: [.inputText("trap-model")])
        }

        let result = await shell.run("trap 'emit-model' EXIT; echo body")

        XCTAssertEqual(result.stdout, "body\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.modelContentItems, [.inputText("trap-model")])
    }

    func testLoadedScriptExitTrapPreservesModelContentItems() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try """
        trap 'emit-model' EXIT
        echo loaded
        """.write(
            to: rootURL.appendingPathComponent("scripts/model.sh"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        try shell.register("emit-model") { _, _ in
            .success(modelContentItems: [.inputText("loaded-trap-model")])
        }

        let result = await shell.run("sh scripts/model.sh")

        XCTAssertEqual(result.stdout, "loaded\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.modelContentItems, [.inputText("loaded-trap-model")])
    }

    func testLoadedDashDiagnosticPreservesModelContentItems() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try """
        trap 'emit-model' EXIT
        echo before
        echo ${value/a/b}
        """.write(
            to: rootURL.appendingPathComponent("scripts/badsubst.sh"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        try shell.register("emit-model") { _, _ in
            .success(modelContentItems: [.inputText("dash-trap-model")])
        }

        let result = await shell.run("sh scripts/badsubst.sh")

        XCTAssertEqual(result.stdout, "before\n")
        XCTAssertEqual(result.stderr, "scripts/badsubst.sh: 1: Bad substitution\n")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.modelContentItems, [.inputText("dash-trap-model")])
    }
}
