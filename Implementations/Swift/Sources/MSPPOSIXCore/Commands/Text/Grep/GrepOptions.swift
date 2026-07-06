import Foundation
import MSPCore

enum GrepBinaryMode {
    case binary
    case text
    case withoutMatch
}

enum GrepDirectoryMode {
    case read
    case recurse
    case skip
}

enum GrepMatcherMode: Equatable {
    case basic
    case extended
    case fixed
    case perl
}

func grepPreprocessDigitContextOptions(_ arguments: [String]) -> [String] {
    arguments.flatMap { argument -> [String] in
        guard argument.hasPrefix("-"),
              argument.count > 1,
              argument.dropFirst().allSatisfy(\.isNumber)
        else {
            return [argument]
        }
        return ["-C", String(argument.dropFirst())]
    }
}

struct GrepOptions {
    var ignoreCase = false
    var invertMatch = false
    var showLineNumbers = false
    var filesWithMatches = false
    var filesWithoutMatches = false
    var matcherMode: GrepMatcherMode = .basic
    var fixedStrings: Bool { matcherMode == .fixed }
    var wordRegexp = false
    var lineRegexp = false
    var recursive = false
    var forceWithFilename = false
    var forceWithoutFilename = false
    var countOnly = false
    var onlyMatching = false
    var quiet = false
    var suppressMessages = false
    var byteOffset = false
    var nullData = false
    var nullFileName = false
    var initialTab = false
    var colorAlways = false
    var beforeContext = 0
    var afterContext = 0
    var groupSeparator: String? = "--"
    var binaryMode: GrepBinaryMode = .binary
    var directoryMode: GrepDirectoryMode = .read
    var maxCount: Int?
    var label: String?
    var warnings: [String] = []
    var patterns: [String] = []
    var paths: [String] = []
    var includePatterns: [String] = []
    var excludePatterns: [String] = []
    var excludeDirectoryPatterns: [String] = []
    var hasPatternSource = false
    var standardInputConsumedByOptionFile = false

    var hasContext: Bool {
        beforeContext > 0 || afterContext > 0
    }

    init(parsed: MSPPOSIXParsedArguments, context: MSPCommandContext) throws {
        var operands = parsed.operands
        var optionFiles: [(isPatternFile: Bool, path: String)] = []
        var defaultContext: Int?
        var explicitBeforeContext = false
        var explicitAfterContext = false
        var explicitMatcherMode: GrepMatcherMode?

        func matcherConflictFailure() -> MSPCommandFailure {
            MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "grep: conflicting matchers specified\n"
            ))
        }

        func setMatcherMode(_ mode: GrepMatcherMode) throws {
            if let explicitMatcherMode, explicitMatcherMode != mode {
                throw matcherConflictFailure()
            }
            matcherMode = mode
            explicitMatcherMode = mode
        }

        for option in parsed.options {
            switch option.name {
            case .short("i"), .short("y"), .long("ignore-case"):
                ignoreCase = true
            case .long("no-ignore-case"):
                ignoreCase = false
            case .short("v"), .long("invert-match"):
                invertMatch = true
            case .short("n"), .long("line-number"):
                showLineNumbers = true
            case .short("l"), .long("files-with-matches"):
                filesWithMatches = true
                filesWithoutMatches = false
            case .short("L"), .long("files-without-match"):
                filesWithoutMatches = true
                filesWithMatches = false
            case .short("F"), .long("fixed-regexp"), .long("fixed-strings"):
                try setMatcherMode(.fixed)
            case .short("G"), .long("basic-regexp"):
                try setMatcherMode(.basic)
            case .short("E"), .long("extended-regexp"):
                try setMatcherMode(.extended)
            case .short("P"), .long("perl-regexp"):
                try setMatcherMode(.perl)
            case .short("w"), .long("word-regexp"):
                wordRegexp = true
            case .short("x"), .long("line-regexp"):
                lineRegexp = true
            case .short("r"), .short("R"), .long("recursive"), .long("dereference-recursive"):
                recursive = true
                directoryMode = .recurse
            case .short("H"), .long("with-filename"):
                forceWithFilename = true
                forceWithoutFilename = false
            case .short("h"), .long("no-filename"):
                forceWithoutFilename = true
                forceWithFilename = false
            case .short("c"), .long("count"):
                countOnly = true
            case .short("o"), .long("only-matching"):
                onlyMatching = true
            case .short("q"), .long("quiet"), .long("silent"):
                quiet = true
            case .short("s"), .long("no-messages"):
                suppressMessages = true
            case .short("b"), .long("byte-offset"):
                byteOffset = true
            case .short("z"), .long("null-data"):
                nullData = true
            case .short("Z"), .long("null"):
                nullFileName = true
            case .short("e"), .long("regexp"):
                hasPatternSource = true
                patterns.append(option.value ?? "")
            case .short("f"), .long("file"):
                hasPatternSource = true
                if let value = option.value {
                    optionFiles.append((isPatternFile: true, path: value))
                }
            case .short("m"), .long("max-count"):
                guard let value = option.value, let parsed = Int(value), parsed >= 0 else {
                    throw MSPCommandFailure.usage("grep: invalid max count\n")
                }
                maxCount = parsed
            case .long("label"):
                label = option.value ?? ""
            case .short("A"), .long("after-context"):
                afterContext = try Self.parseContext(option.value)
                explicitAfterContext = true
            case .short("B"), .long("before-context"):
                beforeContext = try Self.parseContext(option.value)
                explicitBeforeContext = true
            case .short("C"), .long("context"):
                defaultContext = try Self.parseContext(option.value)
            case .long("group-separator"):
                groupSeparator = option.value ?? ""
            case .long("no-group-separator"):
                groupSeparator = nil
            case .long("color"), .long("colour"):
                colorAlways = try Self.parseColor(option.value, optionName: MSPPOSIXOptionParser.optionDisplayName(option))
            case .long("include"):
                includePatterns.append(option.value ?? "")
            case .long("exclude"):
                excludePatterns.append(option.value ?? "")
            case .long("exclude-from"):
                if let value = option.value {
                    optionFiles.append((isPatternFile: false, path: value))
                }
            case .long("exclude-dir"):
                excludeDirectoryPatterns.append(grepStripTrailingSlashes(option.value ?? ""))
            case .long("binary-files"):
                switch option.value {
                case "binary":
                    binaryMode = .binary
                case "text":
                    binaryMode = .text
                case "without-match":
                    binaryMode = .withoutMatch
                default:
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 2,
                        stderr: "grep: unknown binary-files type\n"
                    ))
                }
            case .short("I"):
                binaryMode = .withoutMatch
            case .short("a"), .long("text"):
                binaryMode = .text
            case .short("d"), .long("directories"):
                switch option.value {
                case "read":
                    directoryMode = .read
                    recursive = false
                case "recurse":
                    directoryMode = .recurse
                    recursive = true
                case "skip":
                    directoryMode = .skip
                    recursive = false
                default:
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 2,
                        stderr: "grep: unknown directories method\n"
                    ))
                }
            case .short("D"), .long("devices"):
                switch option.value {
                case "read", "skip":
                    continue
                default:
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 2,
                        stderr: "grep: unknown devices method\n"
                    ))
                }
            case .short("T"), .long("initial-tab"):
                initialTab = true
            case .short("u"), .long("unix-byte-offsets"):
                warnings.append("grep: warning: --unix-byte-offsets (-u) is obsolete")
            case .short("U"), .long("binary"):
                continue
            case .long("line-buffered"):
                continue
            default:
                continue
            }
        }
        try readPatternAndExcludeFiles(optionFiles, context: context)
        if !hasPatternSource, let first = operands.first {
            patterns.append(first)
            hasPatternSource = true
            operands.removeFirst()
        }
        if let defaultContext {
            if !explicitBeforeContext {
                beforeContext = defaultContext
            }
            if !explicitAfterContext {
                afterContext = defaultContext
            }
        }
        paths = operands
    }

    func shouldSearchFile(_ path: String) -> Bool {
        if grepPath(path, matchesAny: excludePatterns) {
            return false
        }
        guard !includePatterns.isEmpty else {
            return true
        }
        return grepPath(path, matchesAny: includePatterns)
    }

    func shouldDescendIntoDirectory(_ path: String, isCommandLineRoot: Bool) -> Bool {
        if isCommandLineRoot {
            return true
        }
        return !grepPath(path, matchesAny: excludeDirectoryPatterns)
    }

    func compiledPatterns(command: String) throws -> [NSRegularExpression] {
        guard !fixedStrings else { return [] }
        do {
            return try patterns.map { pattern in
                var regexPattern = matcherMode == .basic ? grepBasicRegexPattern(from: pattern) : pattern
                if wordRegexp {
                    regexPattern = "\\b(?:\(regexPattern))\\b"
                }
                if lineRegexp {
                    regexPattern = "^(?:\(regexPattern))$"
                }
                return try NSRegularExpression(
                    pattern: regexPattern,
                    options: ignoreCase ? [.caseInsensitive] : []
                )
            }
        } catch {
            throw MSPCommandFailure.usage("\(command): Invalid regular expression\n")
        }
    }

    private mutating func readPatternAndExcludeFiles(
        _ optionFiles: [(isPatternFile: Bool, path: String)],
        context: MSPCommandContext
    ) throws {
        guard !optionFiles.isEmpty else {
            return
        }
        var cachedFileSystem: (any MSPWorkspaceFileSystem)?
        var consumedStandardInput = false

        func readOptionFile(_ path: String) throws -> Data {
            if path == "-" {
                defer { consumedStandardInput = true }
                return consumedStandardInput ? Data() : context.standardInput
            }
            if cachedFileSystem == nil {
                cachedFileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: "grep")
            }
            do {
                return try cachedFileSystem!.readFile(path, from: context.currentDirectory)
            } catch {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 2,
                    stderr: "grep: \(path): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                ))
            }
        }

        for optionFile in optionFiles {
            let text = String(decoding: try readOptionFile(optionFile.path), as: UTF8.self)
            let lines = mspPOSIXLines(text)
            if optionFile.isPatternFile {
                patterns.append(contentsOf: lines)
            } else {
                excludePatterns.append(contentsOf: lines.filter { !$0.isEmpty })
            }
        }
        standardInputConsumedByOptionFile = consumedStandardInput
    }

    private static func parseContext(_ value: String?) throws -> Int {
        guard let value, let parsed = Int(value), parsed >= 0 else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "grep: invalid context length argument\n"
            ))
        }
        return parsed
    }

    private static func parseColor(_ value: String?, optionName: String) throws -> Bool {
        let normalized = (value ?? "auto").lowercased()
        switch normalized {
        case "never", "no", "none", "auto", "tty", "if-tty":
            return false
        case "always", "yes", "force":
            return true
        default:
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "grep: invalid color option \(MSPPOSIXCommandSupport.gnuQuote(value ?? ""))\n"
            ))
        }
    }
}
