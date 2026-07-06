import Foundation
import MSPCore

struct MSPDigestOptions {
    var modeMarker: Character = " "
    var tagged = false
    var delimiter: UInt8 = 0x0a
    var statusOnly = false
    var quiet = false
    var warn = false
    var strict = false
    var ignoreMissing = false

    init(options: [MSPPOSIXOption], defaultTagged: Bool = false) {
        tagged = defaultTagged
        if defaultTagged {
            modeMarker = "*"
        }
        for option in options {
            if option.matches(short: "b", long: "binary") {
                modeMarker = "*"
            } else if option.matches(short: "t", long: "text") {
                modeMarker = " "
            } else if option.matches(long: "tag") {
                tagged = true
                modeMarker = "*"
            } else if option.matches(long: "untagged") {
                tagged = false
                modeMarker = " "
            } else if option.matches(short: "z", long: "zero") {
                delimiter = 0x00
            } else if option.matches(long: "status") {
                statusOnly = true
                quiet = false
                warn = false
            } else if option.matches(long: "quiet") {
                quiet = true
                statusOnly = false
                warn = false
            } else if option.matches(short: "w", long: "warn") {
                warn = true
                statusOnly = false
                quiet = false
            } else if option.matches(long: "strict") {
                strict = true
            } else if option.matches(long: "ignore-missing") {
                ignoreMissing = true
            }
        }
    }
}

enum MSPCksumAlgorithm: Equatable {
    case crc
    case bsd
    case sysv
    case digest(MSPDigestAlgorithm)

    var supportsChecking: Bool {
        if case .digest = self {
            return true
        }
        return false
    }

    var usesTaggedOutputByDefault: Bool {
        if case .digest = self {
            return true
        }
        return false
    }
}

enum MSPCksumSumAlgorithm {
    case bsd
    case sysv
}

struct MSPCksumAlgorithmSelection {
    var algorithm: MSPCksumAlgorithm = .crc
    var algorithmWasSpecified = false
    var debugEnabled = false

    init(options: [MSPPOSIXOption], command: String) throws {
        for option in options {
            if option.matches(short: "a", long: "algorithm") {
                algorithmWasSpecified = true
                algorithm = try Self.algorithm(named: option.value ?? "", command: command)
            } else if option.matches(long: "debug") {
                debugEnabled = true
            }
        }

        let hasLength = options.contains { $0.matches(short: "l", long: "length") }
        if hasLength {
            guard case .digest(.blake2b) = algorithm else {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "\(command): --length is only supported with --algorithm=blake2b\n"
                ))
            }
            algorithm = .digest(try MSPDigestAlgorithm.blake2b(byteCount: 64).effectiveAlgorithm(
                from: options,
                command: command
            ))
        }
    }

    private static func algorithm(named rawName: String, command: String) throws -> MSPCksumAlgorithm {
        switch rawName {
        case "bsd":
            return .bsd
        case "sysv":
            return .sysv
        case "crc":
            return .crc
        case "md5":
            return .digest(.md5)
        case "sha1":
            return .digest(.sha1)
        case "sha224":
            return .digest(.sha224)
        case "sha256":
            return .digest(.sha256)
        case "sha384":
            return .digest(.sha384)
        case "sha512":
            return .digest(.sha512)
        case "blake2b":
            return .digest(.blake2b(byteCount: 64))
        case "sm3":
            return .digest(.sm3)
        default:
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "\(command): invalid argument \(MSPPOSIXCommandSupport.gnuQuote(rawName)) for '--algorithm'\n"
            ))
        }
    }
}

func mspPOSIXValidateDigestModeOptions(
    _ parsedOptions: [MSPPOSIXOption],
    options: MSPDigestOptions,
    command: String,
    isChecking: Bool,
    allowsTaggedCheckOption: Bool,
    allowsBinaryTextCheckOptions: Bool
) throws {
    if options.delimiter != 0x0a, isChecking {
        throw mspPOSIXDigestUsageFailure(
            command: command,
            message: "the --zero option is not supported when verifying checksums"
        )
    }
    if parsedOptions.contains(where: { $0.matches(long: "tag") }),
       isChecking,
       !allowsTaggedCheckOption {
        throw mspPOSIXDigestUsageFailure(
            command: command,
            message: "the --tag option is meaningless when verifying checksums"
        )
    }
    if parsedOptions.contains(where: { $0.matches(short: "b", long: "binary") || $0.matches(short: "t", long: "text") }),
       isChecking,
       !allowsBinaryTextCheckOptions {
        throw mspPOSIXDigestUsageFailure(
            command: command,
            message: "the --binary and --text options are meaningless when verifying checksums"
        )
    }
    if !isChecking {
        let checkOnlyOptions: [(Bool, String)] = [
            (options.ignoreMissing, "the --ignore-missing option is meaningful only when verifying checksums"),
            (options.statusOnly, "the --status option is meaningful only when verifying checksums"),
            (options.warn, "the --warn option is meaningful only when verifying checksums"),
            (options.quiet, "the --quiet option is meaningful only when verifying checksums"),
            (options.strict, "the --strict option is meaningful only when verifying checksums")
        ]
        if let message = checkOnlyOptions.first(where: { $0.0 })?.1 {
            throw mspPOSIXDigestUsageFailure(command: command, message: message)
        }
    }
}

func mspPOSIXDigestUsageFailure(command: String, message: String) -> MSPCommandFailure {
    MSPCommandFailure(result: .failure(
        exitCode: 1,
        stderr: "\(command): \(message)\nTry '\(command) --help' for more information.\n"
    ))
}
