@testable import MSPAgentBridge
import XCTest

final class MSPPlanModeProposedPlanParserTests: XCTestCase {
    func testProposedPlanParserUsesCodexLineTagSemantics() {
        let valid = MSPPlanModeRuntime.parseCompletedText("""
        Before
        <proposed_plan>
        - Step
        </proposed_plan>
        After
        """)
        XCTAssertEqual(valid.visibleText, "Before\nAfter")
        XCTAssertEqual(valid.proposedPlanContent, "- Step\n")

        let extraText = MSPPlanModeRuntime.parseCompletedText("""
        <proposed_plan> extra
        - not a plan
        </proposed_plan>
        """)
        XCTAssertEqual(extraText.visibleText, "<proposed_plan> extra\n- not a plan\n</proposed_plan>")
        XCTAssertNil(extraText.proposedPlanContent)

        let inline = MSPPlanModeRuntime.parseCompletedText(
            "Use <proposed_plan> literally in prose."
        )
        XCTAssertEqual(inline.visibleText, "Use <proposed_plan> literally in prose.")
        XCTAssertNil(inline.proposedPlanContent)
    }
}
