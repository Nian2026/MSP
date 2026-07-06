import Foundation

enum MSPCodexOAuthQuotaError: LocalizedError {
    case missingAccessToken
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case invalidResponse
    case emptyWindows

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "请先登录 Codex。"
        case .invalidHTTPResponse:
            return "Codex 额度接口返回了无效 HTTP 响应。"
        case let .httpStatus(status, message):
            return message.isEmpty ? "Codex 额度接口返回 HTTP \(status)。" : message
        case .invalidResponse:
            return "Codex 额度接口返回了无法解析的数据。"
        case .emptyWindows:
            return "Codex 额度接口没有返回可显示的限额窗口。"
        }
    }
}

struct MSPCodexOAuthQuotaService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let usageUserAgent = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"

    var session: URLSession = .shared

    func refreshQuota(using configuration: MSPCodexOAuthConfiguration) async -> MSPCodexOAuthQuotaResult {
        let configuration = configuration.normalized()
        do {
            guard configuration.hasAccessToken else {
                throw MSPCodexOAuthQuotaError.missingAccessToken
            }

            var request = URLRequest(url: Self.usageURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.usageUserAgent, forHTTPHeaderField: "User-Agent")
            if !configuration.accountID.isEmpty {
                request.setValue(configuration.accountID, forHTTPHeaderField: "Chatgpt-Account-Id")
            }

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MSPCodexOAuthQuotaError.invalidHTTPResponse
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                throw MSPCodexOAuthQuotaError.httpStatus(httpResponse.statusCode, message)
            }

            let json = try JSONSerialization.jsonObject(with: data, options: [])
            let windows = Self.codexQuotaWindows(from: json)
            guard !windows.isEmpty else {
                throw MSPCodexOAuthQuotaError.emptyWindows
            }

            let planType = Self.firstString(in: json, keys: ["plan_type", "planType"])
                ?? configuration.planType.nilIfEmpty
            return MSPCodexOAuthQuotaResult(
                status: .success,
                message: "Codex 额度已刷新。",
                email: configuration.email.nilIfEmpty,
                planType: planType,
                windows: windows,
                checkedAt: .now
            )
        } catch {
            return MSPCodexOAuthQuotaResult(
                status: configuration.hasStoredCredential ? .failed : .signedOut,
                message: error.localizedDescription,
                email: configuration.email.nilIfEmpty,
                planType: configuration.planType.nilIfEmpty,
                windows: [],
                checkedAt: .now
            )
        }
    }

    private static func codexQuotaWindows(from payload: Any) -> [MSPCodexOAuthQuotaWindow] {
        guard let dictionary = payload as? [String: Any] else { return [] }
        let rateLimit = dictionaryValue(dictionary["rate_limit"] ?? dictionary["rateLimit"])
        let codeReviewLimit = dictionaryValue(dictionary["code_review_rate_limit"] ?? dictionary["codeReviewRateLimit"])
        let additionalRateLimits = arrayValue(dictionary["additional_rate_limits"] ?? dictionary["additionalRateLimits"])
        var windows: [MSPCodexOAuthQuotaWindow] = []

        let rateWindows = classifiedCodexWindows(from: rateLimit)
        appendCodexQuotaWindow(
            to: &windows,
            id: "five-hour",
            title: "5 小时限额",
            window: rateWindows.fiveHour,
            limitInfo: rateLimit
        )
        appendCodexQuotaWindow(
            to: &windows,
            id: "weekly",
            title: "周限额",
            window: rateWindows.weekly,
            limitInfo: rateLimit
        )

        let reviewWindows = classifiedCodexWindows(from: codeReviewLimit)
        appendCodexQuotaWindow(
            to: &windows,
            id: "code-review-five-hour",
            title: "代码审查 5 小时限额",
            window: reviewWindows.fiveHour,
            limitInfo: codeReviewLimit
        )
        appendCodexQuotaWindow(
            to: &windows,
            id: "code-review-weekly",
            title: "代码审查周限额",
            window: reviewWindows.weekly,
            limitInfo: codeReviewLimit
        )

        for (index, item) in additionalRateLimits.enumerated() {
            guard let item = item as? [String: Any],
                  let additionalRateLimit = dictionaryValue(item["rate_limit"] ?? item["rateLimit"]) else {
                continue
            }
            let name = firstString(in: item, keys: ["limit_name", "limitName", "metered_feature", "meteredFeature"])
                ?? "附加限额 \(index + 1)"
            appendCodexQuotaWindow(
                to: &windows,
                id: "additional-\(index)-five-hour",
                title: "\(name) 5 小时限额",
                window: dictionaryValue(additionalRateLimit["primary_window"] ?? additionalRateLimit["primaryWindow"]),
                limitInfo: additionalRateLimit
            )
            appendCodexQuotaWindow(
                to: &windows,
                id: "additional-\(index)-weekly",
                title: "\(name) 周限额",
                window: dictionaryValue(additionalRateLimit["secondary_window"] ?? additionalRateLimit["secondaryWindow"]),
                limitInfo: additionalRateLimit
            )
        }

        return windows
    }

    private static func classifiedCodexWindows(from limitInfo: [String: Any]?) -> (fiveHour: [String: Any]?, weekly: [String: Any]?) {
        guard let limitInfo else { return (nil, nil) }
        let primary = dictionaryValue(limitInfo["primary_window"] ?? limitInfo["primaryWindow"])
        let secondary = dictionaryValue(limitInfo["secondary_window"] ?? limitInfo["secondaryWindow"])
        var fiveHour: [String: Any]?
        var weekly: [String: Any]?

        for window in [primary, secondary].compactMap(\.self) {
            let seconds = intValue(window["limit_window_seconds"] ?? window["limitWindowSeconds"])
            if seconds == 18_000, fiveHour == nil {
                fiveHour = window
            } else if seconds == 604_800, weekly == nil {
                weekly = window
            }
        }

        return (fiveHour ?? primary, weekly ?? secondary)
    }

    private static func appendCodexQuotaWindow(
        to windows: inout [MSPCodexOAuthQuotaWindow],
        id: String,
        title: String,
        window: [String: Any]?,
        limitInfo: [String: Any]?
    ) {
        guard let window else { return }
        let resetAt = codexQuotaResetDate(from: window)
        let usedPercentRaw = doubleValue(window["used_percent"] ?? window["usedPercent"])
        let limitReached = boolValue(limitInfo?["limit_reached"] ?? limitInfo?["limitReached"]) ?? false
        let allowed = boolValue(limitInfo?["allowed"])
        let usedPercent = usedPercentRaw ?? ((limitReached || allowed == false) && resetAt != nil ? 100 : nil)
        let remainingPercent = usedPercent.map { min(max(100 - $0, 0), 100) }
        windows.append(
            MSPCodexOAuthQuotaWindow(
                id: id,
                title: title,
                remainingPercent: remainingPercent,
                usedPercent: usedPercent,
                resetAt: resetAt
            )
        )
    }

    private static func codexQuotaResetDate(from window: [String: Any]) -> Date? {
        if let resetAt = doubleValue(window["reset_at"] ?? window["resetAt"]), resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = doubleValue(window["reset_after_seconds"] ?? window["resetAfterSeconds"]), resetAfter > 0 {
            return Date(timeIntervalSinceNow: resetAfter)
        }
        return nil
    }

    private static func firstString(in value: Any, keys: [String]) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in keys {
            if let string = stringValue(dictionary[key]) {
                return string
            }
        }
        return nil
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func arrayValue(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.nilIfEmpty
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
