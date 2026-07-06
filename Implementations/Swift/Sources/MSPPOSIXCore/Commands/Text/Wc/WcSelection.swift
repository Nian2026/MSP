import Foundation
import MSPCore

struct WcSelection {
    var lines: Bool
    var words: Bool
    var bytes: Bool
    var characters: Bool
    var maxLineLength: Bool

    init(options: [MSPPOSIXOption]) {
        lines = options.contains { $0.matches(short: "l") || $0.matches(long: "lines") }
        words = options.contains { $0.matches(short: "w") || $0.matches(long: "words") }
        bytes = options.contains { $0.matches(short: "c") || $0.matches(long: "bytes") }
        characters = options.contains { $0.matches(short: "m") || $0.matches(long: "chars") }
        maxLineLength = options.contains { $0.matches(short: "L") || $0.matches(long: "max-line-length") }
        if !lines && !words && !bytes && !characters && !maxLineLength {
            lines = true
            words = true
            bytes = true
        }
    }

    var selectedCount: Int {
        [lines, words, bytes, characters, maxLineLength].filter { $0 }.count
    }
}
