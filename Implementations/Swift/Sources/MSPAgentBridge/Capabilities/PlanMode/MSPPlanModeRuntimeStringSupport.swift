import Foundation

extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop(while: { $0.isWhitespace }))
    }

    func trimmingTrailingWhitespace() -> String {
        var result = self
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }

    func removingSingleTrailingNewline() -> String {
        if hasSuffix("\n") {
            return String(dropLast())
        }
        return self
    }
}
