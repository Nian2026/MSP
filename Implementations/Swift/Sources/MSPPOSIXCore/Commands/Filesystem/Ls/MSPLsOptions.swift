import Foundation
import MSPCore

let mspLsCommandSpec = MSPPOSIXCommandSpec(
    name: "ls",
    allowedShortOptions: ["1", "R", "l", "a", "A", "d", "f", "h", "r", "t", "S", "U"],
    allowedLongOptions: [
        "all",
        "almost-all",
        "recursive",
        "directory",
        "human-readable",
        "reverse",
        "zero"
    ],
    longOptionsRequiringValue: ["sort"],
    unsupportedOptionAdjective: "illegal"
)

struct MSPLsListingOptions {
    var recursive = false
    var long = false
    var directoryAsSelf = false
    var humanReadable = false
    var reverseSort = false
    var dotfileMode = MSPLsDotfileMode.visibleOnly
    var sortMode = MSPLsSortMode.name
    var lineTerminator = "\n"
}

enum MSPLsSortMode {
    case none
    case name
    case modifiedDate
    case size
}

enum MSPLsDotfileMode {
    case visibleOnly
    case almostAll
    case all
}

func mspLsListingOptions(from parsedOptions: [MSPPOSIXOption]) throws -> MSPLsListingOptions {
    var options = MSPLsListingOptions()
    for option in parsedOptions {
        switch option.name {
        case .short("1"), .short("a"), .short("A"), .long("all"), .long("almost-all"):
            if option.matches(short: "a") || option.matches(long: "all") {
                options.dotfileMode = .all
            } else if option.matches(short: "A") || option.matches(long: "almost-all") {
                options.dotfileMode = .almostAll
            }
        case .short("R"), .long("recursive"):
            options.recursive = true
        case .short("l"):
            options.long = true
        case .short("d"), .long("directory"):
            options.directoryAsSelf = true
        case .short("f"):
            options.sortMode = .none
            options.dotfileMode = .all
            options.long = false
        case .short("U"):
            options.sortMode = .none
        case .short("h"), .long("human-readable"):
            options.humanReadable = true
        case .short("r"), .long("reverse"):
            options.reverseSort = true
        case .long("zero"):
            options.lineTerminator = "\0"
        case .short("t"):
            options.sortMode = .modifiedDate
        case .short("S"):
            options.sortMode = .size
        case .long("sort"):
            switch option.value {
            case "time":
                options.sortMode = .modifiedDate
            case "size":
                options.sortMode = .size
            case "name":
                options.sortMode = .name
            case "none":
                options.sortMode = .none
            default:
                throw MSPCommandFailure.usage("ls: unsupported --sort value \(option.value ?? "")\n")
            }
        default:
            continue
        }
    }
    return options
}
