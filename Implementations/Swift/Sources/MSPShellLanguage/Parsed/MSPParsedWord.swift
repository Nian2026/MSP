import Foundation

public struct MSPParsedWord: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var text: String
        public var isExpandable: Bool
        public var isQuoted: Bool

        public init(text: String, isExpandable: Bool, isQuoted: Bool) {
            self.text = text
            self.isExpandable = isExpandable
            self.isQuoted = isQuoted
        }
    }

    public var parts: [Part]
    public var hasExplicitEmptyQuotedFragment: Bool

    public init(parts: [Part], hasExplicitEmptyQuotedFragment: Bool = false) {
        self.parts = parts
        self.hasExplicitEmptyQuotedFragment = hasExplicitEmptyQuotedFragment
    }

    public var rawText: String {
        parts.map(\.text).joined()
    }
}
