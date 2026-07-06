import Foundation
import MSPCore

struct FindItem {
    var info: MSPFileInfo
    var displayPath: String
    var basePath: String
    var displayBasePath: String
    var depth: Int
}

struct FindEvaluation {
    var matches: Bool
    var prunes: Bool
    var quits = false
}

struct FindRuntimePredicateContext {
    var newerReferenceDates: [String: Date] = [:]
}
