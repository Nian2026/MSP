import XCTest

final class ModelShellProxyDebian12OracleFixtureTests: XCTestCase {
    func testMSPV1Debian12OracleFixturesLoadAndStayPublicSafe() throws {
        let fixture = try Debian12OracleTestSupport.noninteractiveFixture()
        let ptyFixture = try Debian12OracleTestSupport.ptyFixture()

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.artifactKind, "msp-debian12-noninteractive-oracle")
        XCTAssertEqual(fixture.profile, "msp-v1-linux-command-layer")
        XCTAssertEqual(fixture.cases.count, 50)
        XCTAssertEqual(fixture.evidenceSummary.caseCount, 50)
        XCTAssertEqual(fixture.evidenceSummary.linuxAndCandidateParityPassCount, 41)
        XCTAssertEqual(fixture.evidenceSummary.linuxCaptureOnlyCount, 9)
        XCTAssertEqual(fixture.evidenceSummary.mismatchCountForParityPassSubset, 0)
        XCTAssertEqual(ptyFixture.schemaVersion, 1)
        XCTAssertEqual(ptyFixture.artifactKind, "msp-debian12-pty-oracle")
        XCTAssertEqual(ptyFixture.profile, "msp-v1-shell-runtime")
        XCTAssertEqual(ptyFixture.cases.count, 157)
        XCTAssertEqual(ptyFixture.evidenceSummary.findingCount, 0)

        try Debian12OracleTestSupport.assertPublicSafe(Debian12OracleTestSupport.oracleRootURL())
    }
}
