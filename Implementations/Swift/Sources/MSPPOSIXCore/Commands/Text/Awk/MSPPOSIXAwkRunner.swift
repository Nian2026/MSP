import Foundation

final class MSPPOSIXAwkRunner {
    private var program: String
    var fieldSeparator: String?
    var variables: [String: String] = [:]
    var arrays: [String: [String: String]] = [:]
    var functions: [String: UserFunction] = [:]
    var output: [String] = []
    var fileOutputs: [String: MSPPOSIXAwkFileOutput] = [:]
    var fileOutputOrder: [String] = []
    var pipeOutputRecords: [String: [String]] = [:]
    var fileInputRecords: [String: [String]] = [:]
    var currentLine = ""
    var currentFields: [String] = []
    var recordNumber = 0
    var commandOutput: (String) throws -> String
    var fileInput: (String) throws -> String
    private var blocks: [Block] = []
    private var hasParsedProgram = false
    private var hasExited = false

    init(
        program: String,
        fieldSeparator: String?,
        variables: [String: String] = [:],
        commandOutput: @escaping (String) throws -> String = { _ in "" },
        fileInput: @escaping (String) throws -> String = { _ in "" }
    ) {
        self.program = program
        self.fieldSeparator = fieldSeparator
        self.variables = variables
        self.fileInput = fileInput
        self.variables["FS"] = self.variables["FS"] ?? " "
        self.variables["OFS"] = self.variables["OFS"] ?? " "
        self.variables["ORS"] = self.variables["ORS"] ?? "\n"
        self.variables["RS"] = self.variables["RS"] ?? "\n"
        self.variables["SUBSEP"] = self.variables["SUBSEP"] ?? "\u{1c}"
        self.commandOutput = commandOutput
    }

    func run(text: String) throws -> MSPPOSIXAwkRunResult {
        let shouldReadRecords = try start()
        if shouldReadRecords {
            let records = MSPPOSIXAwkFields.records(in: text, separator: variables["RS"] ?? "\n")
            for line in records {
                guard try processRecord(line) else {
                    break
                }
            }
        }
        return try finish()
    }

    var recordSeparator: String {
        variables["RS"] ?? "\n"
    }

    @discardableResult
    func start() throws -> Bool {
        guard !hasParsedProgram else {
            return !hasExited
        }
        let parsedProgram = try MSPPOSIXAwkProgramParser.parse(program)
        functions = parsedProgram.functions
        blocks = parsedProgram.blocks
        hasParsedProgram = true
        do {
            for block in blocks {
                if case .begin = block.kind {
                    try executeStatements(block.body)
                }
            }
        } catch is ExitSignal {
            hasExited = true
            return false
        }
        return true
    }

    @discardableResult
    func processRecord(_ line: String) throws -> Bool {
        guard !hasExited else {
            return false
        }
        recordNumber += 1
        setCurrentLine(line)
        do {
            for block in blocks {
                guard case .record(let condition) = block.kind else { continue }
                if condition.map({ evaluateBool($0) }) ?? true {
                    try executeStatements(block.body)
                }
            }
        } catch is ExitSignal {
            hasExited = true
            return false
        }
        return true
    }

    func finish() throws -> MSPPOSIXAwkRunResult {
        do {
            for block in blocks {
                if case .end = block.kind {
                    try executeStatements(block.body)
                }
            }
        } catch is ExitSignal {
            return MSPPOSIXAwkRunResult(
                stdout: output.joined(),
                fileOutputs: fileOutputOrder.compactMap { fileOutputs[$0] }
            )
        }
        return MSPPOSIXAwkRunResult(
            stdout: output.joined(),
            fileOutputs: fileOutputOrder.compactMap { fileOutputs[$0] }
        )
    }

    func drainStdout() -> String {
        let text = output.joined()
        output.removeAll(keepingCapacity: true)
        return text
    }
}
