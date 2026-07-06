import Foundation

let mspXargsUsageText = """
Usage: xargs [OPTION]... COMMAND [INITIAL-ARGS]...
Run COMMAND with arguments read from standard input.

  -0, --null                   items are separated by a null, not whitespace
  -a, --arg-file=FILE          read items from FILE instead of standard input
  -d, --delimiter=CHARACTER    items are separated by CHARACTER
  -E, -e, --eof=END            set logical EOF string
  -I, --replace=R              replace R in INITIAL-ARGS with input items
  -L, --max-lines=MAX-LINES    use at most MAX-LINES input lines per command
  -n, --max-args=MAX-ARGS      use at most MAX-ARGS arguments per command
  -s, --max-chars=MAX-CHARS    limit command line length
  -P, --max-procs=MAX-PROCS    run at most MAX-PROCS processes at once
  -r, --no-run-if-empty        do not run command if standard input is empty
  -t, --verbose                print commands before executing them
      --help                   display this help and exit
     --version                output version information and exit

"""
