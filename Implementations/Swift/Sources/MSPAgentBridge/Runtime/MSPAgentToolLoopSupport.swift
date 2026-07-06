import Foundation

extension MSPAgentToolLoop {
    static func replacingDynamicDeveloperContext(
        in input: [MSPAgentJSONValue],
        contentStartIndex: Int,
        texts: [String]
    ) -> [MSPAgentJSONValue] {
        guard !texts.isEmpty,
              input.indices.contains(0),
              var developerMessage = input[0].objectValue,
              developerMessage["role"]?.stringValue == "developer",
              var content = developerMessage["content"]?.arrayValue
        else {
            return input
        }

        for (offset, text) in texts.enumerated() {
            let contentIndex = contentStartIndex + offset
            guard content.indices.contains(contentIndex),
                  var contentItem = content[contentIndex].objectValue
            else {
                continue
            }
            contentItem["text"] = .string(text)
            content[contentIndex] = .object(contentItem)
        }

        developerMessage["content"] = .array(content)
        var updatedInput = input
        updatedInput[0] = .object(developerMessage)
        return updatedInput
    }

    static func preparationStatusText(for name: MSPAgentToolName) -> String {
        if name == .execCommand {
            return "正在执行工作区命令"
        }
        if name == .writeStdin {
            return "正在等待命令输出"
        }
        if name == .applyPatch {
            return "正在应用补丁"
        }
        if name == .updatePlan {
            return "正在更新计划"
        }
        return "正在执行工具"
    }

    static func statusText(for call: MSPAgentToolCall) -> String {
        if call.name == .execCommand {
            return "正在执行工作区命令"
        }
        if call.name == .writeStdin {
            return "正在等待命令输出"
        }
        if call.name == .applyPatch {
            return "正在应用补丁"
        }
        if call.name == .updatePlan {
            return "正在更新计划"
        }
        return "正在执行工具"
    }

    static func isCancellationLikeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        return nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cancelled"
    }

    static func isTransientModelStreamError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let retryableCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorSecureConnectionFailed,
                NSURLErrorCannotLoadFromNetwork,
                NSURLErrorResourceUnavailable
            ]
            return retryableCodes.contains(nsError.code)
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
            return true
        }
        let text = nsError.localizedDescription.lowercased()
        return [
            "timeout",
            "timed out",
            "network connection was lost",
            "temporarily unavailable",
            "stream error",
            "internal_error",
            "received from peer"
        ]
            .contains { text.contains($0) }
    }

    static func isContextWindowExceededError(_ error: Error) -> Bool {
        MSPAgentModelClientError.isLikelyContextWindowExceeded(error)
    }

    static func isLikelyContextWindowExceededError(_ error: Error) -> Bool {
        MSPAgentModelClientError.isLikelyContextWindowExceeded(error)
    }

    static let modelStreamRetryStatusText = "模型流式连接短暂中断，正在重试..."
    static let maxConsecutiveAssistantMessageCheckpoints = 2
    static let toolBudgetExhaustedMessage = "tool-call budget exhausted"
}
