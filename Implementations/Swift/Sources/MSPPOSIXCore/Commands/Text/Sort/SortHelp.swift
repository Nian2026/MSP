func mspSortHelp() -> String {
    """
    Usage: sort [OPTION]... [FILE]...
    Write sorted concatenation of all FILE(s) to standard output.

      -c, --check[=diagnose-first]  check for sorted input
      -C, --check=quiet, --check=silent  check without reporting first bad line
      -b, --ignore-leading-blanks  ignore leading blanks
      -d, --dictionary-order        consider only blanks and alphanumeric characters
      -f, --ignore-case             fold lower case to upper case characters
      -g, --general-numeric-sort    compare according to general numerical value
      -h, --human-numeric-sort      compare human readable numbers
      -i, --ignore-nonprinting      consider only printable characters
      -k, --key=KEYDEF              sort via a key
      -M, --month-sort              compare month names
      -m, --merge                   merge already sorted files; do not sort
      -n, --numeric-sort            compare according to string numerical value
      -R, --random-sort             shuffle, but group identical keys
      -o, --output=FILE             write result to FILE
      -r, --reverse                 reverse the result of comparisons
      -S, --buffer-size=SIZE        use SIZE for the main memory buffer
      -s, --stable                  stabilize sort by disabling last-resort comparison
          --sort=WORD               sort by general-numeric, human-numeric, month, numeric, random, or version
          --debug                   annotate the part of the line used to sort
          --random-source=FILE      get random bytes from FILE
      -t, --field-separator=SEP     use SEP instead of non-blank to blank transition
      -T, --temporary-directory=DIR use DIR for temporaries
      -u, --unique                  output only the first of an equal run
      -V, --version-sort            natural sort of version numbers within text
      -z, --zero-terminated         line delimiter is NUL, not newline
          --batch-size=NMERGE       merge at most NMERGE inputs at once
          --files0-from=FILE        read input from NUL-terminated file names
          --parallel=N              change the number of sorts run concurrently
          --help                    display this help and exit
          --version                 output version information and exit

    """
}
