import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


class MSPAgentConversationRequestTestCase: XCTestCase {
    static func signatures(from input: [[String: Any]]) -> [String] {
        input.map { item in
            let type = item["type"] as? String
            if type == "function_call" {
                return [
                    "function_call",
                    item["name"] as? String ?? "",
                    item["call_id"] as? String ?? ""
                ].joined(separator: ":")
            }
            if type == "function_call_output" {
                let output = item["output"] as? String ?? ""
                return [
                    "function_call_output",
                    item["call_id"] as? String ?? "",
                    normalizedExecOutputSignature(output) ?? output
                ].joined(separator: ":")
            }
            if type == "custom_tool_call" {
                return [
                    "custom_tool_call",
                    item["name"] as? String ?? "",
                    item["call_id"] as? String ?? "",
                    item["input"] as? String ?? ""
                ].joined(separator: ":")
            }
            if type == "custom_tool_call_output" {
                return [
                    "custom_tool_call_output",
                    item["call_id"] as? String ?? "",
                    item["output"] as? String ?? ""
                ].joined(separator: ":")
            }
            let role = item["role"] as? String ?? ""
            let text = messageText(item)
            if role == "developer" {
                return "message:developer"
            }
            if role == "assistant" {
                return [
                    "message",
                    role,
                    item["phase"] as? String ?? "",
                    text
                ].joined(separator: ":")
            }
            return [
                "message",
                role,
                text
            ].joined(separator: ":")
        }
    }

    static func assertProviderMessageIDsAreSafe(
        _ input: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for item in input where item["type"] as? String == "message" {
            guard let id = item["id"] as? String else {
                continue
            }
            XCTAssertTrue(
                id.hasPrefix("msg"),
                "provider-bound message id must be provider-authored, got \(id)",
                file: file,
                line: line
            )
        }
    }

    static func assertProviderMessagePhasesAreSafe(
        _ input: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let allowedPhases = Set(["commentary", "final_answer"])
        for item in input where item["type"] as? String == "message" {
            guard let phase = item["phase"] as? String else {
                continue
            }
            XCTAssertTrue(
                allowedPhases.contains(phase),
                "provider-bound message phase must be commentary or final_answer, got \(phase)",
                file: file,
                line: line
            )
        }
    }

    static func assertMessage(
        containing text: String,
        in input: [[String: Any]],
        hasID: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let item = message(containing: text, in: input) else {
            XCTFail("missing message containing \(text)", file: file, line: line)
            return
        }
        if hasID {
            XCTAssertNotNil(item["id"], file: file, line: line)
        } else {
            XCTAssertNil(item["id"], file: file, line: line)
        }
    }

    static func message(
        containing text: String,
        in input: [[String: Any]]
    ) -> [String: Any]? {
        input.first { item in
            item["type"] as? String == "message"
                && messageText(item).contains(text)
        }
    }

    static func transcriptMessage(
        id: String?,
        role: String,
        phase: String?,
        contentType: String,
        text: String
    ) -> MSPAgentJSONValue {
        var object: [String: MSPAgentJSONValue] = [
            "type": .string("message"),
            "role": .string(role),
            "content": .array([
                .object([
                    "type": .string(contentType),
                    "text": .string(text)
                ])
            ])
        ]
        if let id {
            object["id"] = .string(id)
        }
        if let phase {
            object["phase"] = .string(phase)
        }
        return .object(object)
    }

    static func messageText(_ item: [String: Any]) -> String {
        guard let content = item["content"] as? [[String: Any]] else {
            return ""
        }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func developerText(from input: [[String: Any]]) -> String {
        input
            .filter { $0["role"] as? String == "developer" }
            .map(messageText)
            .joined(separator: "\n")
    }

    static func messageTexts(from input: [[String: Any]]) -> [String] {
        input.map(messageText)
    }

    static func normalizedExecOutputSignature(_ output: String) -> String? {
        guard let outputRange = output.range(of: "\nOutput:\n") else {
            return nil
        }
        let header = output[..<outputRange.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
        let body = String(output[outputRange.upperBound...])
        let exitCode = header.first { $0.hasPrefix("Process exited with code ") }
            .map { $0.dropFirst("Process exited with code ".count) }
            .map(String.init)
        let runningSessionID = header.first { $0.hasPrefix("Process running with session ID ") }
            .map { $0.dropFirst("Process running with session ID ".count) }
            .map(String.init)
        if let runningSessionID {
            return "exec_output;running=\(runningSessionID);output=\(body)"
        }
        guard let exitCode else {
            return nil
        }
        return "exec_output;exit=\(exitCode);output=\(body)"
    }

    static func assertDeveloperPromptIsWorkspaceNative(
        _ input: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let developers = input.filter { $0["role"] as? String == "developer" }
        XCTAssertEqual(developers.count, 1, file: file, line: line)
        let text = developers.map(messageText).joined(separator: "\n")
        XCTAssertTrue(text.contains("Linux workspace"), file: file, line: line)
        XCTAssertFalse(text.contains("Linux-like workspace"), file: file, line: line)
        XCTAssertTrue(text.contains("Workspace root visible to you: /"), file: file, line: line)
        XCTAssertFalse(text.contains("Model Shell Proxy"), file: file, line: line)
        XCTAssertFalse(text.contains("MSP"), file: file, line: line)
        XCTAssertFalse(text.contains("iOS app sandbox"), file: file, line: line)
    }

    static var interruptedMarkerSignature: String {
        "message:user:\(MSPAgentInterruptedTurnMarker.text)"
    }

    static let codexSummaryPrefix = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"

    static let codexSummarizationPrompt = """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

    Include:
    - Current progress and key decisions made
    - Important context, constraints, or user preferences
    - What remains to be done (clear next steps)
    - Any critical data, examples, or references needed to continue

    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    """
}
