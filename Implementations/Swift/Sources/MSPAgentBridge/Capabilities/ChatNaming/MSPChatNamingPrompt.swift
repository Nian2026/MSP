import Foundation

public enum MSPChatNamingPrompt {
    public static let codexRequestWrapper = "## My request for Codex:"

    public static func preparedPrompt(
        from input: MSPChatNamingInput,
        maximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleInputMaximumCharacters
    ) -> String {
        let combined = input.parts
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let unwrapped = contentAfterLastRequestWrapper(in: combined)
        return String(
            unwrapped
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(max(1, maximumCharacters))
        )
    }

    public static func titleInstructions(
        titleMaximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleTitleMaximumCharacters,
        descriptionMaximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleDescriptionMaximumCharacters
    ) -> String {
        """
        Create retrieval metadata for the software task described by the user.

        Fill the structured title field with one concise, single-line title of at
        most \(max(1, titleMaximumCharacters)) characters. Start with a concrete
        action or investigation verb when natural, preserve ticket identifiers
        and code symbols, use the user's language, and omit markdown, quotes, and
        ending punctuation. Do not answer or perform the task.

        Fill the structured description field with a compact search description
        of at most \(max(1, descriptionMaximumCharacters)) characters. Preserve
        distinctive project names, files, APIs, artifacts, people, and recurring
        responsibility terms that would help retrieve the Chat later. Avoid
        generic filler and do not invent details absent from the prompt.

        Examples:
        - "Add retry handling to UploadClient" -> Add UploadClient retries
        - "登录后为什么会返回 500" -> 排查登录 500 错误
        - "Where is cacheKey generated?" -> Locate cacheKey generation

        User prompt:
        """
    }

    public static func searchDescriptionInstructions(
        descriptionMaximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleDescriptionMaximumCharacters
    ) -> String {
        """
        You are working from an existing chat's persisted context.
        Fill the structured description field with a compact, search-oriented summary (up to \(max(1, descriptionMaximumCharacters)) characters) of the chat's current purpose.
        This is a keyword retrieval index, not a broad prose summary.
        Prioritize the most recent active purpose over older topics if the chat has shifted.
        Repeat 3 to 6 distinctive nouns or short phrases from the most recent relevant user messages verbatim. Do not generalize technical terms into broader categories.
        Write in the user's locale.
        Do not include quotes, markdown, formatting characters, or trailing punctuation.
        Do not respond to the user or do any other work; only fill the description field.
        """
    }

    public static func fallbackTitle(
        from input: MSPChatNamingInput,
        maximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleFallbackMaximumCharacters,
        inputMaximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleInputMaximumCharacters
    ) -> String {
        fallbackTitle(
            fromPreparedPrompt: preparedPrompt(
                from: input,
                maximumCharacters: inputMaximumCharacters
            ),
            maximumCharacters: maximumCharacters
        )
    }

    /// Converts the already unwrapped and input-bounded naming seed to MSP's
    /// provider-neutral plain single-line fallback.
    public static func fallbackTitle(
        fromPreparedPrompt prompt: String,
        maximumCharacters: Int = MSPChatNamingLimits
            .codexCompatibleFallbackMaximumCharacters
    ) -> String {
        var text = prompt
        text = text.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?s)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?m)^\s{0,3}(?:#{1,6}\s+|[-*+]\s+|>\s*|\d+[.)]\s+)"#,
            with: "",
            options: .regularExpression
        )
        for marker in ["```", "`", "**", "__", "~~"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let limit = max(1, maximumCharacters)
        guard text.count > limit else {
            return text
        }
        guard limit > 1 else {
            return "…"
        }
        return String(text.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func contentAfterLastRequestWrapper(in text: String) -> String {
        guard let range = text.range(
            of: codexRequestWrapper,
            options: .backwards
        ) else {
            return text
        }
        return String(text[range.upperBound...])
    }
}

enum MSPChatNamingTextNormalizer {
    static func title(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else {
            return nil
        }
        var title = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return nil
        }
        title = title.replacingOccurrences(
            of: #"(?i)^title[:\s]+"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"^[`\"'“”‘’]+|[`\"'“”‘’]+$"#,
            with: "",
            options: .regularExpression
        )
        title = collapsedWhitespace(title)
        title = removingTrailingTitlePunctuation(from: title)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }

        let limit = max(1, maximumCharacters)
        guard title.count > limit else {
            return title
        }
        guard limit > 1 else {
            return "…"
        }
        return String(title.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func description(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else {
            return nil
        }
        let normalized = collapsedWhitespace(value)
        guard !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(max(1, maximumCharacters)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func removingTrailingTitlePunctuation(
        from value: String
    ) -> String {
        let punctuation = CharacterSet(charactersIn: ".?!")
        var result = value
        while let scalar = result.unicodeScalars.last,
              punctuation.contains(scalar) {
            result.removeLast()
        }
        return result
    }

}
