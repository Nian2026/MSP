import XCTest
import ModelShellProxy

final class ModelShellProxyFunctionLocalAttributeTests: ModelShellProxyIntegrationTestCase {
    func testFunctionLocalExportAndReadonlyAttributesAreRestored() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let exportState = await shell.run("""
        MSP_S8J_PARENT=parent
        export MSP_S8J_PARENT
        f() {
          local MSP_S8J_PARENT=inner
          export -n MSP_S8J_PARENT
          local MSP_S8J_TEMP=inner
          export MSP_S8J_TEMP
          printf 'inside:%s/%s\\n' "$MSP_S8J_PARENT" "$MSP_S8J_TEMP"
        }
        f
        printf 'after:%s/%s\\n' "$MSP_S8J_PARENT" "${MSP_S8J_TEMP:-missing}"
        export -p
        """)

        XCTAssertEqual(exportState.stderr, "")
        XCTAssertEqual(exportState.exitCode, 0)
        XCTAssertTrue(exportState.stdout.contains("inside:inner/inner\n"))
        XCTAssertTrue(exportState.stdout.contains("after:parent/missing\n"))
        XCTAssertTrue(exportState.stdout.contains("declare -x MSP_S8J_PARENT=\"parent\"\n"))
        XCTAssertFalse(exportState.stdout.contains("MSP_S8J_TEMP"))

        let readonlyState = await shell.run("""
        f() {
          local MSP_S8J_LOCK=inner
          readonly MSP_S8J_LOCK
          printf 'inside:%s\\n' "$MSP_S8J_LOCK"
        }
        f
        MSP_S8J_LOCK=after
        printf 'after:%s status:%s\\n' "$MSP_S8J_LOCK" "$?"
        readonly -p
        """)

        XCTAssertEqual(readonlyState.stderr, "")
        XCTAssertEqual(readonlyState.exitCode, 0)
        XCTAssertTrue(readonlyState.stdout.contains("inside:inner\n"))
        XCTAssertTrue(readonlyState.stdout.contains("after:after status:0\n"))
        XCTAssertFalse(readonlyState.stdout.contains("MSP_S8J_LOCK"))
    }

    func testNestedFunctionLocalExportAttributesRestorePerFrame() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("""
        MSP_S8J_NESTED=parent
        outer() {
          local MSP_S8J_NESTED=outer
          export MSP_S8J_NESTED
          inner() {
            local MSP_S8J_NESTED=inner
            export -n MSP_S8J_NESTED
            printf 'inner:%s\\n' "$MSP_S8J_NESTED"
            printf 'BEGIN-inner\\n'
            export -p
            printf 'END-inner\\n'
          }
          inner
          printf 'outer:%s\\n' "$MSP_S8J_NESTED"
          printf 'BEGIN-outer\\n'
          export -p
          printf 'END-outer\\n'
        }
        outer
        printf 'after:%s\\n' "$MSP_S8J_NESTED"
        printf 'BEGIN-after\\n'
        export -p
        printf 'END-after\\n'
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("inner:inner\n"))
        XCTAssertTrue(result.stdout.contains("outer:outer\n"))
        XCTAssertTrue(result.stdout.contains("after:parent\n"))
        XCTAssertFalse(markedSection("inner", in: result.stdout).contains("MSP_S8J_NESTED"))
        XCTAssertTrue(markedSection("outer", in: result.stdout).contains("declare -x MSP_S8J_NESTED=\"outer\"\n"))
        XCTAssertFalse(markedSection("after", in: result.stdout).contains("MSP_S8J_NESTED"))
    }

    func testFunctionLocalUnsetRestoresExportAttributes() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("""
        MSP_S8J_UNSET_PARENT=parent
        export MSP_S8J_UNSET_PARENT
        parent_case() {
          local MSP_S8J_UNSET_PARENT=inner
          unset MSP_S8J_UNSET_PARENT
          printf 'parent-inside:%s\\n' "${MSP_S8J_UNSET_PARENT:-missing}"
        }
        temp_case() {
          local MSP_S8J_UNSET_TEMP=inner
          export MSP_S8J_UNSET_TEMP
          unset MSP_S8J_UNSET_TEMP
          printf 'temp-inside:%s\\n' "${MSP_S8J_UNSET_TEMP:-missing}"
        }
        parent_case
        temp_case
        printf 'after:%s/%s\\n' "$MSP_S8J_UNSET_PARENT" "${MSP_S8J_UNSET_TEMP:-missing}"
        printf 'BEGIN-after\\n'
        export -p
        printf 'END-after\\n'
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("parent-inside:missing\n"))
        XCTAssertTrue(result.stdout.contains("temp-inside:missing\n"))
        XCTAssertTrue(result.stdout.contains("after:parent/missing\n"))
        let exportedAfter = markedSection("after", in: result.stdout)
        XCTAssertTrue(exportedAfter.contains("declare -x MSP_S8J_UNSET_PARENT=\"parent\"\n"))
        XCTAssertFalse(exportedAfter.contains("MSP_S8J_UNSET_TEMP"))
    }

    private func markedSection(
        _ name: String,
        in output: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let begin = "BEGIN-\(name)\n"
        let end = "END-\(name)\n"
        guard let start = output.range(of: begin)?.upperBound,
              let finish = output[start...].range(of: end)?.lowerBound else {
            XCTFail("missing marked section \(name)", file: file, line: line)
            return ""
        }
        return String(output[start..<finish])
    }
}
