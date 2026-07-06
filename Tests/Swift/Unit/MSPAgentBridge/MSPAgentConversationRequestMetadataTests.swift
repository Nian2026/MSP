import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationRequestMetadataTests: MSPAgentConversationRequestTestCase {
    func testHTTPBodyDoesNotSendClientMetadataFields() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()

        _ = try await conversation.send("只回复一句")

        let body = try await harness.capturedBody(at: 0)
        XCTAssertNil(body["metadata"])
        XCTAssertNil(body["client_metadata"])

        let payloadData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let payloadText = String(decoding: payloadData, as: UTF8.self)
        XCTAssertFalse(payloadText.contains("x-msp"))
        XCTAssertFalse(payloadText.contains("x-agent-runtime"))
    }
}
