import Foundation

enum MSPPOSIXSedScriptSource {
    case expression(String)
    case file(String)
}

struct MSPPOSIXSedInvocation {
    var suppressAutomaticPrint: Bool
    var inPlace: Bool
    var extendedRegex: Bool
    var scriptSources: [MSPPOSIXSedScriptSource]
    var paths: [String]
}

struct MSPPOSIXSedSubstitution {
    var pattern: String
    var replacement: String
    var global: Bool
    var occurrence: Int?
    var print: Bool
    var caseInsensitive: Bool
    var extendedRegex: Bool
}

enum MSPPOSIXSedAddress {
    case line(Int)
    case step(first: Int, stride: Int)
    case last
    case regex(pattern: String, extendedRegex: Bool)
}

struct MSPPOSIXSedProgramCommand {
    var start: MSPPOSIXSedAddress?
    var end: MSPPOSIXSedAddress?
    var negated = false
    var kind: MSPPOSIXSedProgramKind
}

enum MSPPOSIXSedProgramKind {
    case substitution(MSPPOSIXSedSubstitution)
    case print
    case list
    case quit
    case delete
    case append(String)
    case insert(String)
    case change(String)
    case hold
    case holdAppend
    case get
    case getAppend
    case exchange
    case label(String)
    case branch(String?)
    case branchIfSubstitution(String?)
    case group([MSPPOSIXSedProgramCommand])
}
