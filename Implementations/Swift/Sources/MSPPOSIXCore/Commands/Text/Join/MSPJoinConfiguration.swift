import Foundation
import MSPCore

struct MSPJoinConfiguration {
    var separator: Data?
    var firstJoinField = 1
    var secondJoinField = 1
    var includeUnpairedFirst = false
    var includeUnpairedSecond = false
    var onlyUnpairedFirst = false
    var onlyUnpairedSecond = false
    var emptyReplacement: Data?
    var outputFields: [MSPJoinOutputField]?
    var autoFormat = false
    var ignoreCase = false
    var zeroTerminated = false
    var checkOrder: Bool?
    var header = false

    var recordDelimiter: UInt8 {
        zeroTerminated ? 0 : 0x0A
    }

    var outputDelimiter: UInt8 {
        zeroTerminated ? 0 : 0x0A
    }

    var outputSeparator: Data {
        separator ?? Data([0x20])
    }

    init(options: [MSPPOSIXOption]) throws {
        for option in options {
            switch option.name {
            case .short("i"), .long("ignore-case"):
                ignoreCase = true
            case .short("z"), .long("zero-terminated"):
                zeroTerminated = true
            case .long("check-order"):
                checkOrder = true
            case .long("nocheck-order"):
                checkOrder = false
            case .long("header"):
                header = true
            case .short("t"), .long("field-separator"):
                separator = try mspJoinFieldSeparator(option.value ?? "")
            case .short("a"):
                switch try mspJoinFileNumber(option.value) {
                case 1:
                    includeUnpairedFirst = true
                case 2:
                    includeUnpairedSecond = true
                default:
                    throw MSPCommandFailure.usage("join: invalid file number\n")
                }
            case .short("e"):
                emptyReplacement = Data((option.value ?? "").utf8)
            case .short("j"):
                let field = try mspJoinPositiveInteger(option.value)
                firstJoinField = field
                secondJoinField = field
            case .short("o"):
                if option.value == "auto" {
                    autoFormat = true
                    outputFields = nil
                } else {
                    outputFields = try mspJoinOutputFields(option.value ?? "")
                    autoFormat = false
                }
            case .short("v"):
                switch try mspJoinFileNumber(option.value) {
                case 1:
                    onlyUnpairedFirst = true
                case 2:
                    onlyUnpairedSecond = true
                default:
                    throw MSPCommandFailure.usage("join: invalid file number\n")
                }
            case .short("1"):
                firstJoinField = try mspJoinPositiveInteger(option.value)
            case .short("2"):
                secondJoinField = try mspJoinPositiveInteger(option.value)
            default:
                continue
            }
        }
    }
}

func mspJoinHelp() -> String {
    """
    Usage: join [OPTION]... FILE1 FILE2
    For each pair of input lines with identical join fields, write a line to standard output.

      -1 FIELD                join on this FIELD of file 1
      -2 FIELD                join on this FIELD of file 2
      -a FILENUM              also print unpairable lines from file FILENUM
      -e STRING               replace missing input fields with STRING
      -i, --ignore-case       ignore differences in case when comparing fields
      -j FIELD                equivalent to -1 FIELD -2 FIELD
      -o FORMAT               obey FORMAT while constructing output line
      -t CHAR                 use CHAR as input and output field separator
      -v FILENUM              like -a FILENUM, but suppress joined output lines
          --check-order       check that the input is correctly sorted
          --nocheck-order     do not check that the input is correctly sorted
          --header            treat the first line in each file as field headers
      -z, --zero-terminated   line delimiter is NUL, not newline
          --help              display this help and exit
          --version           output version information and exit

    """
}

func mspJoinGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private func mspJoinPositiveInteger(_ value: String?) throws -> Int {
    guard let value, let parsed = Int(value), parsed > 0 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "join: invalid field number: \(mspJoinGNUQuoted(value ?? ""))\n"
        ))
    }
    return parsed
}

private func mspJoinFileNumber(_ value: String?) throws -> Int {
    guard let value, let parsed = Int(value), parsed == 1 || parsed == 2 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "join: invalid field number: \(mspJoinGNUQuoted(value ?? ""))\n"
        ))
    }
    return parsed
}

private func mspJoinFieldSeparator(_ rawValue: String) throws -> Data {
    if rawValue.isEmpty {
        return Data([0x0A])
    }
    if rawValue == "\\0" {
        return Data([0x00])
    }
    let decoded = mspPOSIXDecodeBackslashEscapes(rawValue)
    guard decoded.utf8.count == 1 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "join: multi-character tab \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
        ))
    }
    return Data(decoded.utf8)
}

private func mspJoinOutputFields(_ rawValue: String) throws -> [MSPJoinOutputField] {
    let parts = rawValue
        .split { $0 == "," || $0.isWhitespace }
        .map(String.init)
    guard !parts.isEmpty else {
        throw MSPCommandFailure.usage("join: -o requires a field list\n")
    }
    return try parts.map { part in
        if part == "0" {
            return .joinField
        }
        let pieces = part.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let file = Int(pieces[0]),
              file == 1 || file == 2,
              let field = Int(pieces[1]),
              field >= 1 else {
            throw MSPCommandFailure.usage("join: invalid field spec: \(part)\n")
        }
        return .fileField(file: file, field: field)
    }
}
