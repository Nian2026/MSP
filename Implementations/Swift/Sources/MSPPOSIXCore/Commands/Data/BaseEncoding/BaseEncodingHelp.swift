func mspBaseEncodingHelpHint(_ command: String) -> String {
    "Try '\(command) --help' for more information.\n"
}

func mspBaseEncodingUsage(_ command: String) -> String {
    """
    Usage: \(command) [OPTION]... [FILE]
    Encode or decode FILE, or standard input, to standard output.

    """
}
