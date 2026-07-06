import Foundation
import MSPCore

struct MSPFmtConfiguration {
    var width = 75
    var goalWidth: Int?
    var splitOnly = false
    var taggedParagraph = false
    var uniformSpacing = false
    var prefix: String?
    var crownMargin = false
    var operands: [String] = []

    static let helpText = """
    Usage: fmt [-WIDTH] [OPTION]... [FILE]...
    Reformat each paragraph in the FILE(s), writing to standard output.

      -c, --crown-margin        preserve indentation of first two lines
      -p, --prefix=STRING       reformat only lines beginning with STRING
      -s, --split-only          split long lines, but do not refill
      -t, --tagged-paragraph    indentation of first line different from second
      -u, --uniform-spacing     one space between words, two after sentences
      -w, --width=WIDTH         maximum line width
      -g, --goal=WIDTH          goal width
          --help                display this help and exit
          --version             output version information and exit
    """

    init(arguments: [String]) throws {
        var index = 0
        var widthOptionProvided = false
        var pendingGoalWidth: Int?
        while index < arguments.count {
            let argument = arguments[index]
            if index == 0,
               argument.count > 1,
               argument.hasPrefix("-"),
               argument.dropFirst().allSatisfy(\.isNumber) {
                width = try parseWidth(String(argument.dropFirst()))
                widthOptionProvided = true
                index += 1
                continue
            }
            if argument == "--" {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument == "-s" || argument == "--split-only" {
                splitOnly = true
                index += 1
                continue
            }
            if argument == "-t" || argument == "--tagged-paragraph" {
                taggedParagraph = true
                index += 1
                continue
            }
            if argument == "-u" || argument == "--uniform-spacing" {
                uniformSpacing = true
                index += 1
                continue
            }
            if argument == "-c" || argument == "--crown-margin" {
                crownMargin = true
                index += 1
                continue
            }
            if argument == "-w" || argument == "--width" {
                index += 1
                guard index < arguments.count else {
                    throw invalidWidth("")
                }
                width = try parseWidth(arguments[index])
                widthOptionProvided = true
                index += 1
                continue
            }
            if argument.hasPrefix("-w"), argument.count > 2 {
                width = try parseWidth(String(argument.dropFirst(2)))
                widthOptionProvided = true
                index += 1
                continue
            }
            if argument.hasPrefix("--width=") {
                width = try parseWidth(String(argument.dropFirst("--width=".count)))
                widthOptionProvided = true
                index += 1
                continue
            }
            if argument == "-g" || argument == "--goal" {
                index += 1
                guard index < arguments.count else {
                    throw invalidWidth("")
                }
                pendingGoalWidth = try parseGoalWidth(arguments[index])
                index += 1
                continue
            }
            if argument.hasPrefix("-g"), argument.count > 2 {
                pendingGoalWidth = try parseGoalWidth(String(argument.dropFirst(2)))
                index += 1
                continue
            }
            if argument.hasPrefix("--goal=") {
                pendingGoalWidth = try parseGoalWidth(String(argument.dropFirst("--goal=".count)))
                index += 1
                continue
            }
            if argument == "-p" || argument == "--prefix" {
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure.usage("fmt: option requires an argument -- p\n")
                }
                prefix = arguments[index]
                index += 1
                continue
            }
            if argument.hasPrefix("-p"), argument.count > 2 {
                prefix = String(argument.dropFirst(2))
                index += 1
                continue
            }
            if argument.hasPrefix("--prefix=") {
                prefix = String(argument.dropFirst("--prefix=".count))
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                let optionBody = argument.dropFirst()
                if !optionBody.isEmpty, optionBody.allSatisfy(\.isNumber) {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "fmt: invalid option -- \(optionBody.first ?? "?"); -WIDTH is recognized only when it is the first\noption; use -w N instead\nTry 'fmt --help' for more information.\n"
                    ))
                }
                throw MSPCommandFailure.usage("fmt: unsupported option -- \(argument.dropFirst().first ?? "?")\n")
            }
            operands.append(argument)
            index += 1
        }

        if let pendingGoalWidth {
            if widthOptionProvided {
                guard pendingGoalWidth <= width else {
                    throw invalidWidth(String(pendingGoalWidth), outOfRange: true)
                }
            } else {
                width = pendingGoalWidth + 10
            }
            goalWidth = pendingGoalWidth
        }
    }

    private func parseWidth(_ text: String) throws -> Int {
        guard let value = Int(text), value > 0 else {
            throw invalidWidth(text)
        }
        return value
    }

    private func parseGoalWidth(_ text: String) throws -> Int {
        guard let value = Int(text), value > 0 else {
            throw invalidWidth(text)
        }
        return value
    }

    private func invalidWidth(_ text: String, outOfRange: Bool = false) -> MSPCommandFailure {
        let suffix = outOfRange ? ": Numerical result out of range" : ""
        return MSPCommandFailure(result: .failure(stderr: "fmt: invalid width: \(MSPPOSIXCommandSupport.gnuQuote(text))\(suffix)\n"))
    }
}
