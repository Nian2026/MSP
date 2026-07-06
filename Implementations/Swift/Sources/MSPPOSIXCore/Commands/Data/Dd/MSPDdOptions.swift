import MSPCore

struct MSPDdOptions {
    var inputPath: String?
    var outputPath: String?
    var inputBlockSize = 512
    var outputBlockSize = 512
    var count: Int?
    var skipRecords = 0
    var seekRecords = 0
    var notrunc = false
    var sync = false
    var swab = false
    var fullblock = false
    var append = false
    var status: MSPDdStatus = .default
}

enum MSPDdStatus {
    case none
    case noxfer
    case `default`
}

func parseMSPDdOptions(_ arguments: [String]) throws -> MSPDdOptions {
    var options = MSPDdOptions()
    for argument in arguments {
        let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "dd: unrecognized operand \(MSPPOSIXCommandSupport.gnuQuote(argument))\nTry 'dd --help' for more information.\n"
            ))
        }
        let key = String(parts[0])
        let value = String(parts[1])
        switch key {
        case "if":
            options.inputPath = value
        case "of":
            options.outputPath = value
        case "ibs":
            options.inputBlockSize = try parseMSPDdPositiveByteCount(value, diagnosticName: "invalid number")
        case "obs":
            options.outputBlockSize = try parseMSPDdPositiveByteCount(value, diagnosticName: "invalid number")
        case "bs":
            let blockSize = try parseMSPDdPositiveByteCount(value, diagnosticName: "invalid number")
            options.inputBlockSize = blockSize
            options.outputBlockSize = blockSize
        case "count":
            options.count = try parseMSPDdNonnegativeCount(value)
        case "skip", "iseek":
            options.skipRecords = try parseMSPDdNonnegativeCount(value)
        case "seek", "oseek":
            options.seekRecords = try parseMSPDdNonnegativeCount(value)
        case "conv":
            for symbol in value.split(separator: ",").map(String.init) {
                switch symbol {
                case "notrunc":
                    options.notrunc = true
                case "sync":
                    options.sync = true
                case "swab":
                    options.swab = true
                case "":
                    continue
                default:
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "dd: invalid conversion: \(MSPPOSIXCommandSupport.gnuQuote(symbol))\n"
                    ))
                }
            }
        case "iflag":
            for symbol in value.split(separator: ",").map(String.init) where !symbol.isEmpty {
                if symbol == "fullblock" {
                    options.fullblock = true
                } else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "dd: invalid input flag: \(MSPPOSIXCommandSupport.gnuQuote(symbol))\n"
                    ))
                }
            }
        case "oflag":
            for symbol in value.split(separator: ",").map(String.init) where !symbol.isEmpty {
                if symbol == "append" {
                    options.append = true
                } else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "dd: invalid output flag: \(MSPPOSIXCommandSupport.gnuQuote(symbol))\n"
                    ))
                }
            }
        case "status":
            switch value {
            case "none":
                options.status = .none
            case "noxfer":
                options.status = .noxfer
            default:
                options.status = .default
            }
        default:
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "dd: unrecognized operand \(MSPPOSIXCommandSupport.gnuQuote(argument))\nTry 'dd --help' for more information.\n"
            ))
        }
    }
    return options
}

func mspDdHelp() -> String {
    """
    Usage: dd [OPERAND]...
      or:  dd OPTION
    Copy a file, converting and formatting according to the operands.

      bs=BYTES        read and write up to BYTES bytes at a time
      cbs=BYTES       convert BYTES bytes at a time
      conv=CONVS      convert the file as per the comma separated symbol list
      count=N         copy only N input blocks
      ibs=BYTES       read up to BYTES bytes at a time
      if=FILE         read from FILE instead of stdin
      iflag=FLAGS     read as per the comma separated symbol list
      obs=BYTES       write BYTES bytes at a time
      of=FILE         write to FILE instead of stdout
      oflag=FLAGS     write as per the comma separated symbol list
      seek=N          skip N obs-sized output blocks
      skip=N          skip N ibs-sized input blocks
      status=LEVEL    control diagnostic output

          --help        display this help and exit
          --version     output version information and exit

    """
}

private func parseMSPDdPositiveByteCount(_ value: String, diagnosticName: String) throws -> Int {
    guard let count = Int(value), count > 0 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "dd: \(diagnosticName): \(MSPPOSIXCommandSupport.gnuQuote(value))\n"
        ))
    }
    return count
}

private func parseMSPDdNonnegativeCount(_ value: String) throws -> Int {
    guard let count = Int(value), count >= 0 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "dd: invalid number: \(MSPPOSIXCommandSupport.gnuQuote(value))\n"
        ))
    }
    return count
}
