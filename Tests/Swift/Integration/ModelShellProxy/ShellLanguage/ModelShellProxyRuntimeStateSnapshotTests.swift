import Foundation
import XCTest
import ModelShellProxy

final class ModelShellProxyRuntimeStateSnapshotTests: ModelShellProxyIntegrationTestCase {
    func testCommandSubstitutionRestoresFullRuntimeMutableState() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("""
        set -- parent1 parent2
        arr=(parent)
        declare -A map=([k]=parent)
        f() { printf 'parent-function'; }
        set -o pipefail
        shopt -s nullglob
        inner=$(
          set -- child
          arr=(child)
          map[k]=child
          f() { printf 'child-function'; }
          set +o pipefail
          shopt -u nullglob
          printf 'inner:%s/%s/%s/%s/' "$#" "${arr[0]}" "${map[k]}" "$(f)"
          false | true
          printf 'pipe:%s/' "$?"
          set -- __msp_missing_*
          printf 'glob:%s:%s' "$#" "$1"
        )
        printf '%s\\n' "$inner"
        printf 'parent:%s/%s/%s/%s/' "$#" "${arr[0]}" "${map[k]}" "$(f)"
        false | true
        printf 'pipe:%s/' "$?"
        set -- __msp_missing_*
        printf 'glob:%s\\n' "$#"
        """)

        XCTAssertEqual(
            result.stdout,
            "inner:1/child/child/child-function/pipe:0/glob:1:__msp_missing_*\n"
                + "parent:2/parent/parent/parent-function/pipe:1/glob:0\n"
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPipelineSourceRestoresFullRuntimeMutableState() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try """
        set -- child
        arr=(child)
        declare -A map=([k]=child)
        f() { printf 'child-function'; }
        set +o pipefail
        shopt -u nullglob
        printf 'source:%s/%s/%s/%s/' "$#" "${arr[0]}" "${map[k]}" "$(f)"
        false | true
        printf 'pipe:%s/' "$?"
        set -- __msp_missing_*
        printf 'glob:%s:%s\\n' "$#" "$1"
        """.write(
            to: rootURL.appendingPathComponent("state.sh"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("""
        set -- parent1 parent2
        arr=(parent)
        declare -A map=([k]=parent)
        f() { printf 'parent-function'; }
        set -o pipefail
        shopt -s nullglob
        . state.sh | cat
        printf 'parent:%s/%s/%s/%s/' "$#" "${arr[0]}" "${map[k]}" "$(f)"
        false | true
        printf 'pipe:%s/' "$?"
        set -- __msp_missing_*
        printf 'glob:%s\\n' "$#"
        """)

        XCTAssertEqual(
            result.stdout,
            "source:1/child/child/child-function/pipe:0/glob:1:__msp_missing_*\n"
                + "parent:2/parent/parent/parent-function/pipe:1/glob:0\n"
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCommandSubstitutionInsideFunctionRestoresFunctionDepth() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("""
        f() {
          inner=$(g() { local CHILD=inner; printf '%s' "$CHILD"; return 3; }; g; printf ':after:%s' "$?")
          local OUTER=ok
          printf 'inner:%s outer:%s before-return\\n' "$inner" "$OUTER"
          return 7
          printf 'never\\n'
        }
        f
        printf 'status:%s\\n' "$?"
        """)

        XCTAssertEqual(
            result.stdout,
            "inner:inner:after:3 outer:ok before-return\nstatus:7\n"
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }
}
