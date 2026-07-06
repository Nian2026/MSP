import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPUpdatePlanToolTests: MSPAgentConversationRequestTestCase {
    func testUpdatePlanToolDefinitionMatchesCodexFunctionContract() throws {
        let tool = MSPAgentRequestBuilder.updatePlanToolDefinition
        let encoded = try MSPAgentJSONValue(encoding: tool)
        let expected = Self.codexUpdatePlanToolDefinition

        XCTAssertEqual(tool.type, "function")
        XCTAssertEqual(tool.name, "update_plan")
        XCTAssertEqual(tool.description, MSPUpdatePlanToolSchema.description)
        XCTAssertEqual(tool.description, Self.codexDescription)
        XCTAssertFalse(tool.strict)
        XCTAssertEqual(tool.parameters, Self.codexParameters)
        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(
            try Self.canonicalJSONString(encoded),
            try Self.canonicalJSONString(expected)
        )
    }

    func testUpdatePlanSuccessOutputIsCodexFunctionCallOutputPlainString() throws {
        let call = MSPAgentToolCall(
            id: "call_plan",
            name: .updatePlan,
            arguments: Self.validArguments
        )

        let result = MSPUpdatePlanRuntime.modelToolResult(call: call)
        let items = try MSPResponsesStreamingModelClient.toolOutputInputItems(from: [result])
        let item = try XCTUnwrap(items.first?.objectValue)

        XCTAssertEqual(item["type"], .string("function_call_output"))
        XCTAssertEqual(item["call_id"], .string("call_plan"))
        XCTAssertEqual(item["output"], .string("Plan updated"))
        XCTAssertFalse(Self.isJSONObjectString(try XCTUnwrap(item["output"]?.stringValue)))
    }

    func testUpdatePlanRuntimeParsesCodexArgumentsAndRejectsNonCodexShape() throws {
        let parsed = try MSPUpdatePlanRuntime.parseArguments(Self.validArguments)

        XCTAssertEqual(parsed.explanation, "sync progress")
        XCTAssertEqual(parsed.plan, [
            MSPUpdatePlanItem(step: "Read Codex", status: .completed),
            MSPUpdatePlanItem(step: "Implement SDK", status: .inProgress)
        ])

        let parsedRaw = try MSPUpdatePlanRuntime.parseArguments(
            rawArguments: Self.validArgumentsJSONString,
            decodedArguments: [:]
        )
        XCTAssertEqual(parsedRaw, parsed)

        let parsedNullExplanation = try MSPUpdatePlanRuntime.parseArguments(
            #"{"explanation":null,"plan":[]}"#
        )
        XCTAssertNil(parsedNullExplanation.explanation)
        XCTAssertEqual(parsedNullExplanation.plan, [])

        XCTAssertThrowsError(try MSPUpdatePlanRuntime.parseArguments([
            "plan": .array([]),
            "extra": .bool(true)
        ])) { error in
            XCTAssertTrue("\(error)".contains("unknown field `extra`"))
        }
        XCTAssertThrowsError(try MSPUpdatePlanRuntime.parseArguments([
            "plan": .array([
                .object([
                    "step": .string("Bad"),
                    "status": .string("done")
                ])
            ])
        ])) { error in
            XCTAssertTrue("\(error)".contains("unknown variant `done`"))
        }
        XCTAssertThrowsError(try MSPUpdatePlanRuntime.parseArguments([
            "plan": .array([
                .object([
                    "step": .string("Bad"),
                    "status": .string("pending"),
                    "note": .string("not in Codex schema")
                ])
            ])
        ])) { error in
            XCTAssertTrue("\(error)".contains("unknown field `note`"))
        }
    }

    func testPlanProgressCapabilityControlsToolVisibility() {
        let disabled = MSPAgentConversationConfiguration(
            model: "test-model",
            tools: [
                MSPAgentRequestBuilder.execCommandToolDefinition,
                MSPAgentRequestBuilder.updatePlanToolDefinition
            ],
            planProgressCapability: .disabled
        )
        XCTAssertFalse(Self.toolNames(in: disabled).contains(MSPUpdatePlanToolSchema.name))

        let enabled = MSPAgentConversationConfiguration(
            model: "test-model",
            tools: [
                MSPAgentRequestBuilder.execCommandToolDefinition,
                MSPAgentRequestBuilder.updatePlanToolDefinition
            ],
            planProgressCapability: .enabled()
        )
        XCTAssertEqual(
            Self.toolNames(in: enabled).filter { $0 == MSPUpdatePlanToolSchema.name }.count,
            1
        )
    }

    func testUpdatePlanConversationOutputAndEventWhenCapabilityEnabled() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.updatePlanToolCallStream(callID: "call_plan"),
                Self.finalAnswerStream(
                    id: "resp_plan_final",
                    messageID: "msg_plan_final",
                    text: "计划已更新。"
                )
            ]
        )
        let events = PlanProgressEventLog()
        let conversation = harness.makeConversation(
            planProgressCapability: .enabled()
        )

        _ = try await conversation.send("更新计划", onEvent: { event in
            await events.append(event)
        })

        let initialBody = try await harness.capturedBody(at: 0)
        let tools = try XCTUnwrap(initialBody["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.filter { $0["name"] as? String == MSPUpdatePlanToolSchema.name }.count,
            1
        )

        let followupBody = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)
        XCTAssertTrue(signatures.contains("function_call:update_plan:call_plan"))
        XCTAssertTrue(signatures.contains("function_call_output:call_plan:Plan updated"))

        let functionCall = try XCTUnwrap(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_plan"
        })
        XCTAssertEqual(functionCall["name"] as? String, MSPUpdatePlanToolSchema.name)
        XCTAssertEqual(functionCall["arguments"] as? String, Self.validArgumentsJSONString)

        let output = try XCTUnwrap(input.first {
            $0["type"] as? String == "function_call_output"
                && $0["call_id"] as? String == "call_plan"
        })
        XCTAssertEqual(output["output"] as? String, "Plan updated")
        XCTAssertFalse(Self.isJSONObjectString(try XCTUnwrap(output["output"] as? String)))

        let updates = await events.updates()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].explanation, "sync progress")
        XCTAssertEqual(updates[0].plan.map(\.status), [.completed, .inProgress])
    }

    func testMalformedUpdatePlanArgumentsAreReturnedToModelAsPlainFunctionOutput() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.updatePlanToolCallStream(
                    callID: "call_bad_plan",
                    arguments: #"{"plan":["#
                ),
                Self.finalAnswerStream(
                    id: "resp_bad_plan_final",
                    messageID: "msg_bad_plan_final",
                    text: "参数错误已回传。"
                )
            ]
        )
        let conversation = harness.makeConversation(
            planProgressCapability: .enabled()
        )

        _ = try await conversation.send("更新计划", onEvent: { _ in })

        let followupBody = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let output = try XCTUnwrap(input.first {
            $0["type"] as? String == "function_call_output"
                && $0["call_id"] as? String == "call_bad_plan"
        })
        let text = try XCTUnwrap(output["output"] as? String)
        XCTAssertTrue(text.hasPrefix("failed to parse function arguments:"))
        XCTAssertFalse(Self.isJSONObjectString(text))
    }

    func testUpdatePlanPlainStringOutputSurvivesCompactionRewriteWithoutJSONEnvelope() throws {
        let result = MSPUpdatePlanRuntime.modelToolResult(call: MSPAgentToolCall(
            id: "call_plan",
            name: .updatePlan,
            arguments: Self.validArguments
        ))
        let outputItem = try XCTUnwrap(
            MSPResponsesStreamingModelClient.toolOutputInputItems(from: [result]).first
        )
        let output = try XCTUnwrap(outputItem.objectValue?["output"]?.stringValue)
        XCTAssertEqual(output, "Plan updated")
        XCTAssertFalse(Self.isJSONObjectString(output))

        let builder = MSPCompactionRequestBuilder()
        let rewritten = builder.remoteCompactInputByRewritingOutputsToFitContextWindow(
            [
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string("compact")
                        ])
                    ])
                ]),
                outputItem
            ],
            contextWindow: 10,
            estimatedTokenCount: { items in
                items.contains(outputItem) ? 50 : 1
            }
        )

        let compactedOutput = try XCTUnwrap(rewritten.input.last?.objectValue?["output"]?.stringValue)
        XCTAssertEqual(compactedOutput, MSPCompactionRequestBuilder.remoteCompactTruncatedOutputMessage)
        XCTAssertFalse(Self.isJSONObjectString(compactedOutput))
    }

    func testPackageManifestsIncludeUpdatePlanSourcesUnderToolsOwner() throws {
        let root = Self.repositoryRoot()
        let rootManifest = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let implementationManifest = try String(
            contentsOf: root.appendingPathComponent("Implementations/Swift/Package.swift")
        )
        let planProgressOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/MSPAgentBridge/Capabilities/PlanProgress")
        let updatePlanOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/Tools/MSP/update_plan")
        let misplacedPlanProgressOwner = planProgressOwner.appendingPathComponent("UpdatePlan")

        XCTAssertTrue(rootManifest.contains(#"path: "Implementations/Swift/Sources""#))
        XCTAssertTrue(implementationManifest.contains(#"path: "Sources""#))
        for manifest in [rootManifest, implementationManifest] {
            XCTAssertTrue(manifest.contains(#""MSPAgentBridge/Capabilities""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/update_plan/Contract""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/update_plan/Runtime""#))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: updatePlanOwner.appendingPathComponent("Contract/MSPUpdatePlanToolSchema.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: updatePlanOwner.appendingPathComponent("Runtime/MSPUpdatePlanRuntime.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedPlanProgressOwner.appendingPathComponent("MSPUpdatePlanToolSchema.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedPlanProgressOwner.appendingPathComponent("MSPUpdatePlanRuntime.swift").path
        ))
    }

    private static let codexDescription =
        "Updates the task plan.\n"
        + "Provide an optional explanation and a list of plan items, each with a step and status.\n"
        + "At most one step can be in_progress at a time.\n"

    private static let codexParameters: MSPAgentJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "explanation": .object([
                "type": .string("string"),
                "description": .string("Optional explanation for this plan update.")
            ]),
            "plan": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "step": .object([
                            "type": .string("string"),
                            "description": .string("Task step text.")
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("pending"),
                                .string("in_progress"),
                                .string("completed")
                            ]),
                            "description": .string("Step status.")
                        ])
                    ]),
                    "required": .array([
                        .string("step"),
                        .string("status")
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                "description": .string("The list of steps")
            ])
        ]),
        "required": .array([.string("plan")]),
        "additionalProperties": .bool(false)
    ])

    private static let codexUpdatePlanToolDefinition: MSPAgentJSONValue = .object([
        "type": .string("function"),
        "name": .string("update_plan"),
        "description": .string(codexDescription),
        "parameters": codexParameters,
        "strict": .bool(false)
    ])

    private static let validArguments: [String: MSPAgentJSONValue] = [
        "explanation": .string("sync progress"),
        "plan": .array([
            .object([
                "step": .string("Read Codex"),
                "status": .string("completed")
            ]),
            .object([
                "step": .string("Implement SDK"),
                "status": .string("in_progress")
            ])
        ])
    ]

    private static let validArgumentsJSONString =
        #"{"explanation":"sync progress","plan":[{"step":"Read Codex","status":"completed"},{"step":"Implement SDK","status":"in_progress"}]}"#

    private static func toolNames(
        in configuration: MSPAgentConversationConfiguration
    ) -> [String] {
        let context = configuration.requestContext(prompt: "test")
        return context.tools.map(\.name)
    }

    private static func updatePlanToolCallStream(callID: String) -> String {
        updatePlanToolCallStream(callID: callID, arguments: validArgumentsJSONString)
    }

    private static func updatePlanToolCallStream(
        callID: String,
        arguments: String
    ) -> String {
        return """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_plan","call_id":"\(callID)","name":"update_plan","arguments":\(jsonStringLiteral(arguments))}}

        data: {"type":"response.completed","response":{"id":"resp_plan","output":[{"type":"function_call","id":"fc_plan","call_id":"\(callID)","name":"update_plan","arguments":\(jsonStringLiteral(arguments))}]}}

        data: [DONE]

        """
    }

    private static func jsonStringLiteral(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(data: data, encoding: .utf8)!
    }

    private static func canonicalJSONString(_ value: MSPAgentJSONValue) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value.jsonObject,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func isJSONObjectString(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] else {
            return false
        }
        return true
    }

    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

private actor PlanProgressEventLog {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func updates() -> [MSPPlanProgressUpdatedEvent] {
        events.compactMap { event in
            if case .planProgressUpdated(let update) = event {
                return update
            }
            return nil
        }
    }
}
