import Foundation
import MSPCore

struct MSPXargsStreamingExecutor {
    private let options: MSPXargsStreamingOptions
    private var context: MSPCommandContext
    private let standardOutput: any MSPCommandOutputStream
    private let standardError: any MSPCommandOutputStream
    private var currentWords: [String]
    private var currentValueCount = 0
    private var currentLineCount = 0
    private let baseRenderedLength: Int
    private var currentRenderedLength: Int
    private var aggregateExitCode: Int32 = 0
    private var modelContentItems: [MSPCommandModelContentItem] = []
    private var hasExecutedCommand = false
    private(set) var shouldStopConsumingInput = false

    init(
        options: MSPXargsStreamingOptions,
        context: MSPCommandContext,
        standardOutput: any MSPCommandOutputStream,
        standardError: any MSPCommandOutputStream
    ) {
        self.options = options
        self.context = context
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.currentWords = options.commandWords
        self.baseRenderedLength = mspPOSIXXargsRenderedLength(options.commandWords)
        self.currentRenderedLength = baseRenderedLength
    }

    mutating func consume(_ record: MSPXargsStreamingRecord) async throws {
        guard !shouldStopConsumingInput else {
            return
        }
        switch record {
        case .value(let value):
            if let replacement = options.replacement {
                let command = options.commandWords.map {
                    $0.replacingOccurrences(of: replacement, with: value)
                }
                try await run(command)
                return
            }
            try await appendValues([value], lineCount: 0)
        case .logicalLine(let words):
            try await appendValues(words, lineCount: 1)
        }
    }

    mutating func finish() async throws -> MSPCommandResult {
        if shouldStopConsumingInput {
            return result()
        }
        if currentValueCount > 0 {
            try await flushCurrent()
        } else if !hasExecutedCommand,
                  !options.noRunIfEmpty,
                  options.replacement == nil {
            try await run(options.commandWords)
        }
        return result()
    }

    func result() -> MSPCommandResult {
        MSPCommandResult(
            stdout: "",
            stderr: "",
            exitCode: aggregateExitCode,
            modelContentItems: modelContentItems
        )
    }

    private mutating func appendValues(_ values: [String], lineCount: Int) async throws {
        guard !values.isEmpty else {
            return
        }
        let wouldExceedLines = lineCount > 0
            && currentValueCount > 0
            && options.maxLines.map { currentLineCount >= $0 } == true
        let wouldExceedArgs = options.maxArgs.map {
            currentValueCount > 0 && currentValueCount + values.count > $0
        } ?? false
        var additionLength = mspPOSIXXargsRenderedAdditionLength(
            values,
            afterWordCount: currentWords.count
        )
        if currentValueCount > 0,
           wouldExceedLines || wouldExceedArgs || currentRenderedLength + additionLength > options.maxCharacters {
            try await flushCurrent()
            additionLength = mspPOSIXXargsRenderedAdditionLength(
                values,
                afterWordCount: currentWords.count
            )
        }

        let nextRenderedLength = currentRenderedLength + additionLength
        guard nextRenderedLength <= options.maxCharacters else {
            throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "xargs: command line too long\n"))
        }
        currentWords += values
        currentRenderedLength = nextRenderedLength
        currentValueCount += values.count
        currentLineCount += lineCount

        if let maxArgs = options.maxArgs,
           currentValueCount >= maxArgs {
            try await flushCurrent()
        }
    }

    private mutating func flushCurrent() async throws {
        guard currentValueCount > 0 else {
            return
        }
        try await run(currentWords)
        currentWords = options.commandWords
        currentRenderedLength = baseRenderedLength
        currentValueCount = 0
        currentLineCount = 0
    }

    private mutating func run(_ commandWords: [String]) async throws {
        let rendered = render(commandWords)
        guard rendered.utf8.count <= options.maxCharacters else {
            throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "xargs: command line too long\n"))
        }
        if options.verbose {
            try await standardError.write(Data((rendered + "\n").utf8))
        }
        hasExecutedCommand = true
        let childResult = await mspPOSIXXargsRunChildCommand(
            commandWords,
            rendered: rendered,
            context: context,
            standardOutputStream: standardOutput,
            standardErrorStream: standardError,
            clearsChildStandardInput: options.clearsChildStandardInput
        )
        if !childResult.stdoutData.isEmpty {
            try await standardOutput.write(childResult.stdoutData)
        }
        if !childResult.stderrData.isEmpty {
            try await standardError.write(childResult.stderrData)
        }
        modelContentItems.append(contentsOf: childResult.modelContentItems)
        aggregateExitCode = mspPOSIXXargsExitCode(
            current: aggregateExitCode,
            childExitCode: childResult.exitCode
        )
        if childResult.exitCode == 255 {
            shouldStopConsumingInput = true
        }
    }

    private func render(_ words: [String]) -> String {
        words.map(mspPOSIXShellQuote).joined(separator: " ")
    }
}
