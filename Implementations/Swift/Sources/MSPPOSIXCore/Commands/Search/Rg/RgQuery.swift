import Foundation
import MSPCore

struct RgQuery {
    var pattern: String? {
        patterns.first
    }
    var patterns: [String] = []
    var paths: [String] = []
    var globRules: [RgGlobRule] = []
    var ignoreCase = false
    var fixedStrings = false
    var lineNumber = false
    var filesWithMatches = false
    var filesOnly = false
    var includeHidden = false
    var forceWithFilename = false
    var forceWithoutFilename = false
    var invertMatch = false
    var count = false
    var quiet = false
    var noMessages = false
    var wordRegexp = false
    var lineRegexp = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-i", "--ignore-case":
                ignoreCase = true
            case "-F", "--fixed-strings":
                fixedStrings = true
            case "-n", "--line-number":
                lineNumber = true
            case "-l", "--files-with-matches":
                filesWithMatches = true
            case "-v", "--invert-match":
                invertMatch = true
            case "-c", "--count":
                count = true
            case "-q", "--quiet":
                quiet = true
            case "--no-messages":
                noMessages = true
            case "-w", "--word-regexp":
                wordRegexp = true
            case "-x", "--line-regexp":
                lineRegexp = true
            case "--files":
                filesOnly = true
            case "--hidden":
                includeHidden = true
            case "-H", "--with-filename":
                forceWithFilename = true
                forceWithoutFilename = false
            case "-I", "--no-filename":
                forceWithoutFilename = true
                forceWithFilename = false
            case "-e", "--regexp":
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure.usage("rg: missing value for --regexp\n")
                }
                patterns.append(arguments[index])
            case _ where argument.hasPrefix("-e") && argument.count > 2:
                patterns.append(String(argument.dropFirst(2)))
            case "-g", "--glob":
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure.usage("rg: missing value for --glob\n")
                }
                globRules.append(try Self.globRule(rawPattern: arguments[index]))
            case _ where argument.hasPrefix("--glob="):
                globRules.append(try Self.globRule(
                    rawPattern: String(argument.dropFirst("--glob=".count))
                ))
            case _ where argument.hasPrefix("-g") && argument.count > 2:
                globRules.append(try Self.globRule(rawPattern: String(argument.dropFirst(2))))
            case "--":
                index += 1
                if !filesOnly, patterns.isEmpty, index < arguments.count {
                    patterns.append(arguments[index])
                    index += 1
                }
                paths.append(contentsOf: arguments.dropFirst(index))
                return
            default:
                if argument.hasPrefix("-") {
                    throw MSPCommandFailure.usage("rg: unsupported option -- \(argument)\n")
                }
                if filesOnly || !patterns.isEmpty {
                    paths.append(argument)
                } else {
                    patterns.append(argument)
                }
            }
            index += 1
        }
    }

    func includes(_ displayPath: String) -> Bool {
        let includeRules = globRules.filter { !$0.isExclusion }
        if !includeRules.isEmpty, !includeRules.contains(where: { $0.matches(displayPath) }) {
            return false
        }
        return !globRules.contains { $0.isExclusion && $0.matches(displayPath) }
    }

    private static func globRule(rawPattern: String) throws -> RgGlobRule {
        do {
            return try RgGlobRule(rawPattern: rawPattern)
        } catch let error as RgGlobParseError {
            throw MSPCommandFailure.usage(
                "error parsing glob '\(rawPattern)': \(error.message)\n"
            )
        }
    }
}
