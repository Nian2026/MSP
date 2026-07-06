import MSPShell
import XCTest

extension MSPShellParserTests {
    func testReportsSyntaxErrorsFromFullParser() {
        XCTAssertThrowsError(try MSPShellParser().parse("echo |")) { error in
            guard case MSPShellParserError.syntax(let exitCode, let message) = error else {
                return XCTFail("expected syntax error, got \(error)")
            }
            XCTAssertEqual(exitCode, 2)
            XCTAssertEqual(message, "|: missing command")
        }
    }
}
