import XCTest
import MSPCore
@testable import MSPPOSIXCore

final class MSPRgGlobTests: XCTestCase {
    func testCharacterClassesMatchDebian12RipgrepOracle() throws {
        let pdfRule = try RgGlobRule(rawPattern: "*.[pP][dD][fF]")
        let numericRangeRule = try RgGlobRule(rawPattern: "a[0-9].txt")
        let negatedRangeRule = try RgGlobRule(rawPattern: "a[!0-9].txt")

        XCTAssertTrue(pdfRule.matches("docs/book.pdf"))
        XCTAssertTrue(pdfRule.matches("docs/book.PDF"))
        XCTAssertTrue(pdfRule.matches("docs/book.Pdf"))
        XCTAssertTrue(pdfRule.matches("docs/book.pDf"))
        XCTAssertFalse(pdfRule.matches("docs/book.txt"))

        XCTAssertTrue(numericRangeRule.matches("docs/a1.txt"))
        XCTAssertFalse(numericRangeRule.matches("docs/aA.txt"))

        XCTAssertFalse(negatedRangeRule.matches("docs/a1.txt"))
        XCTAssertTrue(negatedRangeRule.matches("docs/aA.txt"))
        XCTAssertTrue(negatedRangeRule.matches("docs/ax.txt"))
    }

    func testCharacterClassesApplyToExclusionRules() throws {
        let query = try RgQuery(arguments: [
            "--files",
            "docs",
            "-g", "*.txt",
            "-g", "!a[0-9].txt"
        ])

        XCTAssertFalse(query.includes("docs/a1.txt"))
        XCTAssertTrue(query.includes("docs/aA.txt"))
        XCTAssertTrue(query.includes("docs/sub/chapter.txt"))
        XCTAssertFalse(query.includes("docs/book.pdf"))
    }

    func testUnclosedCharacterClassMatchesDebian12RipgrepDiagnostic() {
        XCTAssertThrowsError(
            try RgQuery(arguments: ["--files", "docs", "-g", "*.[pP"])
        ) { error in
            guard let failure = error as? MSPCommandFailure else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(failure.result.stdout, "")
            XCTAssertEqual(
                failure.result.stderr,
                "error parsing glob '*.[pP': unclosed character class; missing ']'\n"
            )
            XCTAssertEqual(failure.result.exitCode, 2)
        }
    }
}
