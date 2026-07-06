import Foundation

extension PhotoSorterMediaCommand {
    struct PhotoSorterMediaSearchMatch: Sendable, Equatable {
        var path: String
        var source: String
        var queryKind: String
        var query: String
        var match: String
        var snippet: String
    }

    struct PhotoSorterMediaUnavailableSample: Sendable, Equatable {
        var path: String
        var message: String
    }

    struct PhotoSorterMediaSearchUsageError: Error {
        var message: String
    }

    struct PhotoSorterMediaSearchArguments {
        var mode: PhotoSorterMediaSearchMode
        var rawPaths: [String]
        var pathListFile: String?
        var limit: Int?
        var format: PhotoSorterMediaSearchFormat = .snippets
    }

    enum PhotoSorterMediaSearchFormat: String {
        case snippets
        case paths
        case jsonl
    }

    enum PhotoSorterMediaSearchMode {
        case keyword(String)
        case regex(pattern: String, regex: NSRegularExpression)

        var descriptionLine: String {
            switch self {
            case .keyword(let keyword):
                return "Keyword: \(keyword)"
            case .regex(let pattern, _):
                return "Regex: \(pattern)"
            }
        }

        var jsonQueryKind: String {
            switch self {
            case .keyword:
                return "keyword"
            case .regex:
                return "regex"
            }
        }

        var queryText: String {
            switch self {
            case .keyword(let keyword):
                return keyword
            case .regex(let pattern, _):
                return pattern
            }
        }

        func firstMatchRange(in text: String) -> NSRange? {
            switch self {
            case .keyword(let keyword):
                guard let range = text.range(
                    of: keyword,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) else {
                    return nil
                }
                return NSRange(range, in: text)
            case .regex(_, let regex):
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                return regex.firstMatch(in: text, range: range)?.range
            }
        }
    }
}
