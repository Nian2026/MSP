import Foundation
import MSPChat

enum MSPChatReadMarkdownRenderer {
    static func markdown(
        for projection: MSPChatReadProjection,
        title: String = "对话归档"
    ) -> String {
        var lines = [
            "# \(title)",
            "",
            "标题：\(nonEmpty(projection.conversation.title, fallback: "未命名对话"))",
            "路径：\(projection.conversation.path)"
        ]

        if projection.page.hasMore, let nextCursor = projection.page.nextCursor {
            lines.append("")
            lines.append("还有更多内容。")
            lines.append("继续读取：--cursor \(nextCursor)")
        }

        if projection.turns.isEmpty {
            lines.append("")
            lines.append("（没有可显示的对话内容。）")
            return lines.joined(separator: "\n")
        }

        for (turnIndex, turn) in projection.turns.enumerated() {
            lines.append("")
            lines.append("## 回合 \(turnIndex + 1)")
            if turn.items.isEmpty {
                lines.append("")
                lines.append("（本回合没有可显示内容。）")
                continue
            }

            for item in turn.items {
                append(item, to: &lines)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func append(
        _ item: MSPChatReadProjection.Item,
        to lines: inout [String]
    ) {
        switch item.type {
        case "userMessage":
            appendUserMessage(item, to: &lines)
        case "agentMessage":
            appendAssistantMessage(item, to: &lines)
        case "toolCall", "commandExecution":
            if let toolCall = item.toolCall {
                appendToolCall(toolCall, to: &lines)
            } else if let result = item.toolResult {
                appendToolResult(result, to: &lines)
            }
        case "toolResult", "commandOutput":
            if let result = item.toolResult {
                appendToolResult(result, to: &lines)
            }
        case "artifact":
            if let artifact = item.artifact {
                appendArtifact(artifact, to: &lines)
            }
        case "error":
            if let event = item.event {
                appendError(event, to: &lines)
            }
        default:
            if let event = item.event {
                appendEvent(event, to: &lines)
            }
        }
    }

    private static func appendUserMessage(
        _ item: MSPChatReadProjection.Item,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("### 用户")
        appendText(item.text ?? "", to: &lines)
        guard !item.attachments.isEmpty else { return }
        lines.append("")
        lines.append("附件：")
        lines.append(contentsOf: item.attachments.map { "- \(attachmentSummary($0))" })
    }

    private static func appendAssistantMessage(
        _ item: MSPChatReadProjection.Item,
        to lines: inout [String]
    ) {
        lines.append("")
        let phase = item.phase?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lines.append((phase == "commentary" || phase == "intermediate") ? "### AI（中间回复）" : "### AI")
        appendText(item.text ?? "", to: &lines)
    }

    private static func appendToolCall(
        _ toolCall: MSPChatReadProjection.ToolCall,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("### 工具调用")
        if let command = shellCommand(from: toolCall.arguments) {
            lines.append("")
            lines.append(fencedBlock(command, language: "sh"))
        } else {
            lines.append("")
            lines.append("工具：\(toolCall.name)")
            if let arguments = toolCall.arguments {
                lines.append("")
                lines.append("参数：")
                lines.append(fencedBlock(jsonString(for: arguments), language: "json"))
            }
        }
    }

    private static func appendToolResult(
        _ result: MSPChatReadProjection.ToolResult,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("### 工具结果")
        if !result.success {
            let exitCode = result.exitCode.map { "，退出码 \($0)" } ?? ""
            lines.append("")
            lines.append("结果：失败\(exitCode)")
        } else if let exitCode = result.exitCode {
            lines.append("")
            lines.append("结果：成功，退出码 \(exitCode)")
        }
        if let stream = result.stream?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stream.isEmpty {
            lines.append("")
            lines.append("流：\(stream)")
        }
        if let output = result.output {
            if result.outputTruncated == true,
               let originalOutputCharCount = result.originalOutputCharCount {
                lines.append("")
                lines.append("（已截断，原始长度 \(originalOutputCharCount) 字符。）")
            }
            lines.append("")
            lines.append(fencedBlock(output, language: "text"))
        } else if let payload = result.payload {
            lines.append("")
            lines.append(fencedBlock(jsonString(for: payload), language: "json"))
        } else if result.success {
            lines.append("")
            lines.append("（无输出。）")
        }
        if !result.images.isEmpty {
            lines.append("")
            lines.append("图片：")
            lines.append(contentsOf: result.images.enumerated().map { index, image in
                let filePath = image.filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let url = image.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let target = (!filePath.isEmpty ? filePath : nil)
                    ?? (!url.isEmpty ? url : nil)
                    ?? "image-\(index + 1)"
                return "- \(target)"
            })
        }
    }

    private static func appendArtifact(
        _ artifact: MSPChatReadProjection.Attachment,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("### 附件")
        lines.append("")
        lines.append("- \(attachmentSummary(artifact))")
    }

    private static func appendError(
        _ event: MSPChatReadProjection.Event,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("### 错误")
        appendText(event.text ?? "", to: &lines)
    }

    private static func appendEvent(
        _ event: MSPChatReadProjection.Event,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("### 事件")
        lines.append("")
        lines.append("类型：\(event.type)")
        if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            lines.append("")
            lines.append(text)
        }
        if let payload = event.payload {
            lines.append("")
            lines.append("载荷：")
            lines.append(fencedBlock(jsonString(for: payload), language: "json"))
        }
    }

    private static func appendText(
        _ text: String,
        to lines: inout [String]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("")
        lines.append(trimmed.isEmpty ? "（空）" : trimmed)
    }

    private static func shellCommand(
        from arguments: MSPChatJSONValue?
    ) -> String? {
        guard case .object(let object) = arguments else { return nil }
        for key in ["cmd", "command"] {
            if case .string(let command)? = object[key] {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func attachmentSummary(
        _ attachment: MSPChatReadProjection.Attachment
    ) -> String {
        var parts = [nonEmpty(attachment.displayName, fallback: "附件")]
        if let mimeType = attachment.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mimeType.isEmpty {
            parts.append(mimeType)
        }
        if !attachment.pageNumbers.isEmpty {
            parts.append("书页 \(attachment.pageNumbers.map(String.init).joined(separator: ", "))")
        }
        if let localPath = attachment.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localPath.isEmpty {
            parts.append("路径 \(localPath)")
        }
        return parts.joined(separator: "，")
    }

    private static func jsonString(for value: MSPChatJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fencedBlock(_ text: String, language: String) -> String {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func nonEmpty(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
