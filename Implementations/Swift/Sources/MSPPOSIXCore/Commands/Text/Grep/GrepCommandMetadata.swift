import Foundation
import MSPCore

enum GrepCommandMetadata {
    static let spec = MSPPOSIXCommandSpec(
        name: "grep",
        allowedShortOptions: ["i", "v", "n", "l", "L", "G", "E", "P", "F", "w", "x", "r", "R", "I", "H", "h", "c", "o", "q", "s", "a", "b", "z", "Z", "y", "u", "U", "T"],
        allowedLongOptions: [
            "ignore-case",
            "no-ignore-case",
            "invert-match",
            "line-number",
            "files-with-matches",
            "files-without-match",
            "basic-regexp",
            "extended-regexp",
            "fixed-regexp",
            "perl-regexp",
            "fixed-strings",
            "word-regexp",
            "line-regexp",
            "recursive",
            "dereference-recursive",
            "with-filename",
            "no-filename",
            "count",
            "only-matching",
            "quiet",
            "silent",
            "no-messages",
            "text",
            "byte-offset",
            "binary-files",
            "color",
            "colour",
            "directories",
            "devices",
            "group-separator",
            "no-group-separator",
            "null-data",
            "null",
            "binary",
            "unix-byte-offsets",
            "initial-tab",
            "line-buffered"
        ],
        shortOptionsRequiringValue: ["A", "B", "C", "D", "d", "e", "f", "m"],
        longOptionsRequiringValue: [
            "after-context",
            "before-context",
            "binary-files",
            "context",
            "devices",
            "directories",
            "regexp",
            "file",
            "group-separator",
            "include",
            "exclude",
            "exclude-from",
            "exclude-dir",
            "max-count",
            "label"
        ],
        longOptionsWithOptionalValue: ["color", "colour"]
    )

    static func standardOptionResult(arguments: [String]) -> MSPCommandResult? {
        guard arguments.count == 1 else {
            return nil
        }
        switch arguments[0] {
        case "--help":
            return .success(stdout: helpText)
        case "-V", "--version":
            return .success(stdout: "grep (GNU grep) 3.8\n")
        default:
            return nil
        }
    }

    private static let helpText = """
    Usage: grep [OPTION]... PATTERNS [FILE]...
    Search for PATTERNS in each FILE.

      -E, --extended-regexp     PATTERNS are extended regular expressions
      -F, --fixed-strings       PATTERNS are strings
      -G, --basic-regexp        PATTERNS are basic regular expressions
      -P, --perl-regexp         PATTERNS are Perl regular expressions
      -e, --regexp=PATTERNS     use PATTERNS for matching
      -f, --file=FILE           take PATTERNS from FILE
      -i, --ignore-case         ignore case distinctions
      -v, --invert-match        select non-matching lines
      -n, --line-number         print line number with output lines
          --line-buffered       flush output on every line
      -H, --with-filename       print file name with output lines
      -h, --no-filename         suppress file name prefix
      -q, --quiet, --silent     suppress all normal output
      -r, --recursive           read all files under each directory
      -A, --after-context=NUM   print NUM lines of trailing context
      -B, --before-context=NUM  print NUM lines of leading context
      -C, --context=NUM         print NUM lines of output context
          --help                display this help and exit
      -V, --version             output version information and exit
    """
}
