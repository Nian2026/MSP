import Foundation
import XCTest

final class ModelShellProxyCore100OracleConformanceTests: XCTestCase {
    func testMSPV1Core100OracleFixtureLoadsAndStaysPublicSafe() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.artifactKind, "msp-core100-debian12-noninteractive-oracle")
        XCTAssertEqual(fixture.profile, "msp-core100-linux-command-layer")
        XCTAssertEqual(fixture.evidenceSummary.caseCount, 905)
        XCTAssertEqual(fixture.evidenceSummary.linuxCaptureOnlyCount, 905)
        XCTAssertEqual(fixture.evidenceSummary.timeoutCount, 0)
        XCTAssertEqual(fixture.evidenceSummary.limitExceededCount, 0)
        XCTAssertEqual(fixture.evidenceSummary.core100CommandCount, 100)
        XCTAssertEqual(fixture.evidenceSummary.coveredCore100CommandCount, 100)
        XCTAssertEqual(fixture.evidenceSummary.missingCore100Commands, [])
        XCTAssertEqual(fixture.evidenceSummary.shellStressCaseCount, 57)
        XCTAssertEqual(fixture.cases.count, 905)
        XCTAssertEqual(fixture.cases.filter { $0.category == "core100-shell-stress" }.count, 57)
        XCTAssertEqual(fixture.cases.filter { $0.commands.contains("tree") }.count, 14)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["base64"], 6)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["bc"], 5)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["cd"], 3)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["grep"], 25)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["head"], 8)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["pwd"], 3)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["tail"], 9)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["timeout"], 4)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["which"], 3)
        XCTAssertEqual(fixture.evidenceSummary.perCommandCaseCount["yes"], 4)

        let treePresence = try XCTUnwrap(fixture.cases.first { $0.id == "core100-tree-presence" })
        let treePresenceStdout = String(decoding: treePresence.expected.stdoutData, as: UTF8.self)
        XCTAssertTrue(treePresenceStdout.contains("/usr/bin/tree"))
        XCTAssertTrue(treePresenceStdout.contains("status:0"))

        try Self.assertPublicSafe(Self.oracleRootURL())
    }

    func testMSPV1Core100OracleNoninteractiveConformanceRunner() async throws {
        guard Self.environmentFlag("MSP_RUN_CORE100_ORACLE") else {
            throw XCTSkip("Set MSP_RUN_CORE100_ORACLE=1 to execute Core100 oracle cases.")
        }

        let fixture = try Self.fixture()
        let selectedCases = Self.selectedCases(from: fixture.cases)
        XCTAssertFalse(selectedCases.isEmpty)

        let failures = await collectFailures(for: selectedCases)
        let reportURL = try writeReport(selectedCases: selectedCases, failures: failures)
        guard failures.isEmpty else {
            XCTFail(Self.failureSummary(failures: failures, reportURL: reportURL))
            return
        }
    }
}
