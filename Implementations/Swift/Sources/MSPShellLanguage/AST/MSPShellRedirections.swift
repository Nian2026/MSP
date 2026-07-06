import Foundation

enum ShellRedirectionOperator: String, Equatable {
    case input = "<"
    case output = ">"
    case appendOutput = ">>"
    case duplicateOutput = ">&"
    case duplicateInput = "<&"
    case readWrite = "<>"
    case clobberOutput = ">|"
    case outputBoth = "&>"
    case appendOutputBoth = "&>>"
    case hereString = "<<<"
    case hereDocument = "<<"
    case hereDocumentStripTabs = "<<-"
}

struct ShellRedirection: Equatable {
    var fd: Int?
    var operation: ShellRedirectionOperator
    var target: String

    func hereDocument() throws -> ShellHereDocument? {
        guard operation == .hereDocument || operation == .hereDocumentStripTabs else {
            return nil
        }
        return try MSPShellHereDocumentMarker.decoded(
            target,
            operation: operation
        )
    }
}

struct ShellRedirectionClause: Equatable {
    var fd: Int?
    var operation: ShellRedirectionOperator
    var target: ShellWord

    func hereDocument() throws -> ShellHereDocument? {
        guard operation == .hereDocument || operation == .hereDocumentStripTabs else {
            return nil
        }
        return try MSPShellHereDocumentMarker.decoded(
            target.rawText,
            operation: operation
        )
    }
}

struct ShellHereDocument: Equatable {
    var body: String
    var expandable: Bool
    var stripsLeadingTabs: Bool
    var markerText: String

    var quotedDelimiter: Bool {
        !expandable
    }
}

enum MSPShellHereDocumentMarker {
    static let prefix = "__MSP_HEREDOC_"

    static func encoded(body: String, expandable: Bool) -> String {
        let payload = body.data(using: .utf8)?.base64EncodedString() ?? ""
        return "\(prefix)\(expandable ? "E" : "L")_\(payload)"
    }

    static func decoded(
        _ marker: String,
        operation: ShellRedirectionOperator
    ) throws -> ShellHereDocument? {
        guard marker.hasPrefix(prefix) else { return nil }
        let payloadStart = marker.index(marker.startIndex, offsetBy: prefix.count)
        guard payloadStart < marker.endIndex else {
            throw invalidMarker()
        }
        let mode = marker[payloadStart]
        let separator = marker.index(after: payloadStart)
        guard separator < marker.endIndex, marker[separator] == "_" else {
            throw invalidMarker()
        }
        let encodedStart = marker.index(after: separator)
        let encoded = String(marker[encodedStart...])
        guard let data = Data(base64Encoded: encoded),
              let body = String(data: data, encoding: .utf8) else {
            throw ShellExit.usage("<<: invalid here-document body")
        }
        return ShellHereDocument(
            body: body,
            expandable: try expandableMode(mode),
            stripsLeadingTabs: operation == .hereDocumentStripTabs,
            markerText: marker
        )
    }

    private static func expandableMode(_ mode: Character) throws -> Bool {
        switch mode {
        case "E":
            return true
        case "L":
            return false
        default:
            throw invalidMarker()
        }
    }

    private static func invalidMarker() -> ShellExit {
        ShellExit.usage("<<: invalid here-document marker")
    }
}

enum ShellRedirectionOutputSink: Equatable {
    case stdout
    case stderr
    case null
    case closed
    case file(path: String, append: Bool)
    case openFileDescription(Int)
    case processSubstitution(path: String)
}

struct ShellStageRedirections: Equatable {
    var operations: [ShellRedirection] = []
}
