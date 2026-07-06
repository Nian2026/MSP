import Foundation
import MSPChat

#if os(Linux)
import Glibc
#elseif os(Windows)
import CRT
#else
import Darwin
#endif

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    Usage:
      msp-chat-validate [--json] <package.chat>

    Validates an MSP .chat directory package and exits non-zero on errors.
    """)
}

var emitJSON = false
var packagePath: String?

for argument in arguments {
    switch argument {
    case "--json":
        emitJSON = true
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        if packagePath == nil {
            packagePath = argument
        } else {
            fputs("Unexpected argument: \(argument)\n", stderr)
            printUsage()
            exit(2)
        }
    }
}

guard let packagePath else {
    printUsage()
    exit(2)
}

let validator = MSPChatValidator()
let report = validator.validate(packageAt: URL(fileURLWithPath: packagePath))

if emitJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fputs("Could not encode validation report: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
} else {
    print(report.renderedText())
}

exit(report.isValid ? 0 : 1)
