import MSPCore

extension MSPHeadTailCommand {
    func standardOptionResult(arguments: [String]) -> MSPCommandResult? {
        if arguments.contains("--help") {
            return .success(stdout: command == "head" ? Self.headHelpText : Self.tailHelpText)
        }
        if arguments.contains("--version") {
            return .success(stdout: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: command))
        }
        return nil
    }

    private static let headHelpText = """
    Usage: head [OPTION]... [FILE]...
    Print the first 10 lines of each FILE to standard output.
    With more than one FILE, precede each with a header giving the file name.

      -c, --bytes=[-]NUM       print the first NUM bytes of each file
      -n, --lines=[-]NUM       print the first NUM lines instead of the first 10
      -q, --quiet, --silent    never print headers giving file names
      -v, --verbose            always print headers giving file names
      -z, --zero-terminated    line delimiter is NUL, not newline
          --help     display this help and exit
          --version  output version information and exit
    """

    private static let tailHelpText = """
    Usage: tail [OPTION]... [FILE]...
    Print the last 10 lines of each FILE to standard output.
    With more than one FILE, precede each with a header giving the file name.

      -c, --bytes=[+]NUM       output the last NUM bytes
      -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10
      -q, --quiet, --silent    never print headers giving file names
      -v, --verbose            always print headers giving file names
      -z, --zero-terminated    line delimiter is NUL, not newline
          --help     display this help and exit
          --version  output version information and exit
    """
}
