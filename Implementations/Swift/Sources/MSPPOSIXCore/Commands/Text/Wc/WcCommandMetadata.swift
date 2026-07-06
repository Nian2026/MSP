import Foundation
import MSPCore

extension MSPWcCommand {
    static let spec = MSPPOSIXCommandSpec(
        name: "wc",
        allowedShortOptions: ["l", "w", "c", "m", "L"],
        allowedLongOptions: [
            "lines",
            "words",
            "bytes",
            "chars",
            "max-line-length",
            "files0-from",
            "debug",
            "help",
            "version"
        ],
        longOptionsRequiringValue: ["files0-from"],
        unsupportedOptionAdjective: "illegal"
    )

    static let helpText = """
    Usage: wc [OPTION]... [FILE]...
      or:  wc [OPTION]... --files0-from=F
    Print newline, word, and byte counts for each FILE.

      -c, --bytes            print the byte counts
      -m, --chars            print the character counts
      -l, --lines            print the newline counts
      -L, --max-line-length  print the maximum display width
      -w, --words            print the word counts
          --files0-from=F    read input from NUL-terminated names in F
          --debug            emit counter implementation diagnostics
          --help             display this help and exit
          --version          output version information and exit
    """
}
