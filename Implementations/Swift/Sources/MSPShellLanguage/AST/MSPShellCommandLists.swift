enum ShellListSeparator: Equatable {
    case semicolon
    case newline
    case and
    case or

    var listOperator: ShellListOperator {
        switch self {
        case .semicolon, .newline:
            return .semicolon
        case .and:
            return .and
        case .or:
            return .or
        }
    }

    var tokenText: String {
        switch self {
        case .semicolon:
            return ";"
        case .newline:
            return "newline"
        case .and:
            return "&&"
        case .or:
            return "||"
        }
    }

    var isCommandTerminator: Bool {
        switch self {
        case .semicolon, .newline:
            return true
        case .and, .or:
            return false
        }
    }
}

enum ShellListOperator: Equatable {
    case semicolon
    case and
    case or

    var tokenText: String {
        switch self {
        case .semicolon:
            return ";"
        case .and:
            return "&&"
        case .or:
            return "||"
        }
    }
}

enum ShellPipeOperator: Equatable, Sendable {
    case stdout
    case stdoutAndStderr

    var tokenText: String {
        switch self {
        case .stdout:
            return "|"
        case .stdoutAndStderr:
            return "|&"
        }
    }
}

struct ShellPipeline {
    var negated: Bool
    var commands: [ShellCommandNode]
    var pipeOperators: [ShellPipeOperator]

    init(
        negated: Bool,
        commands: [ShellCommandNode],
        pipeOperators: [ShellPipeOperator]? = nil
    ) {
        self.negated = negated
        self.commands = commands
        self.pipeOperators = pipeOperators ?? Array(repeating: .stdout, count: max(0, commands.count - 1))
    }

    init(negated: Bool, stages: [ShellStage]) {
        self.init(negated: negated, commands: stages.map(ShellCommandNode.init(stage:)))
    }

    var stages: [ShellStage] {
        commands.map(\.stage)
    }

    var parts: [ShellPipelinePart] {
        guard !commands.isEmpty else { return [] }
        var parts: [ShellPipelinePart] = []
        for index in commands.indices {
            parts.append(.command(commands[index]))
            if index < commands.count - 1 {
                let pipeOperator = pipeOperators.indices.contains(index) ? pipeOperators[index] : .stdout
                parts.append(.pipe(pipeOperator))
            }
        }
        return parts
    }
}

enum ShellPipelinePart {
    case command(ShellCommandNode)
    case pipe(ShellPipeOperator)
}

struct ShellCommandList {
    var first: ShellPipeline?
    var rest: [ShellCommandListContinuation]

    init(first: ShellPipeline? = nil, rest: [ShellCommandListContinuation] = []) {
        self.first = first
        self.rest = rest
    }

    init(pipelines: [ShellPipeline]) {
        self.init()
        for pipeline in pipelines {
            append(pipeline)
        }
    }

    var pipelines: [ShellPipeline] {
        guard let first else { return [] }
        return [first] + rest.map(\.pipeline)
    }

    var entries: [ShellCommandListEntry] {
        guard let first else { return [] }
        return [ShellCommandListEntry(leadingOperator: nil, leadingSeparator: nil, pipeline: first)]
            + rest.map { continuation in
                ShellCommandListEntry(
                    leadingOperator: continuation.operator,
                    leadingSeparator: continuation.separator,
                    pipeline: continuation.pipeline
                )
            }
    }

    var statements: [ShellStatement] {
        guard let first else { return [] }
        var output = [ShellStatement(first: first)]
        for continuation in rest {
            switch continuation.operator {
            case .and, .or:
                output[output.count - 1].append(continuation)
            case .semicolon:
                output.append(ShellStatement(
                    leadingTerminator: continuation.separator ?? .semicolon,
                    first: continuation.pipeline
                ))
            }
        }
        return output
    }

    mutating func append(_ pipeline: ShellPipeline) {
        append(pipeline, separator: nil)
    }

    mutating func append(_ pipeline: ShellPipeline, operator listOperator: ShellListOperator?) {
        append(pipeline, operator: listOperator, separator: nil)
    }

    mutating func append(_ pipeline: ShellPipeline, separator: ShellListSeparator?) {
        append(pipeline, operator: separator?.listOperator, separator: separator)
    }

    private mutating func append(
        _ pipeline: ShellPipeline,
        operator listOperator: ShellListOperator?,
        separator: ShellListSeparator?
    ) {
        guard first != nil else {
            first = pipeline
            return
        }
        rest.append(ShellCommandListContinuation(
            connector: ShellCommandListConnector(
                operator: listOperator,
                separator: separator
            ),
            pipeline: pipeline
        ))
    }

    var isEmpty: Bool {
        first == nil
    }
}

enum ShellCommandListConnector: Equatable {
    case listOperator(ShellListOperator)
    case separator(ShellListSeparator)

    init(operator listOperator: ShellListOperator?, separator: ShellListSeparator?) {
        if let separator {
            self = .separator(separator)
        } else {
            self = .listOperator(listOperator ?? .semicolon)
        }
    }

    var listOperator: ShellListOperator {
        switch self {
        case .listOperator(let listOperator):
            return listOperator
        case .separator(let separator):
            return separator.listOperator
        }
    }

    var sourceSeparator: ShellListSeparator? {
        switch self {
        case .listOperator:
            return nil
        case .separator(let separator):
            return separator
        }
    }
}

struct ShellCommandListContinuation {
    var connector: ShellCommandListConnector
    var pipeline: ShellPipeline

    init(connector: ShellCommandListConnector, pipeline: ShellPipeline) {
        self.connector = connector
        self.pipeline = pipeline
    }

    var `operator`: ShellListOperator {
        connector.listOperator
    }

    var separator: ShellListSeparator? {
        connector.sourceSeparator
    }
}

struct ShellCommandListEntry {
    var leadingOperator: ShellListOperator?
    var leadingSeparator: ShellListSeparator?
    var pipeline: ShellPipeline
}

struct ShellStatement {
    var leadingTerminator: ShellListSeparator? = nil
    var first: ShellPipeline
    var rest: [ShellStatementContinuation] = []

    var entries: [ShellStatementEntry] {
        [ShellStatementEntry(leadingOperator: nil, pipeline: first)]
            + rest.map { continuation in
                ShellStatementEntry(
                    leadingOperator: continuation.operator,
                    pipeline: continuation.pipeline
                )
            }
    }

    var pipelines: [ShellPipeline] {
        [first] + rest.map(\.pipeline)
    }

    var operators: [ShellListOperator] {
        rest.map(\.`operator`)
    }

    var leadingOperator: ShellListOperator? {
        leadingTerminator?.listOperator
    }

    var leadingSeparator: ShellListSeparator? {
        leadingTerminator
    }

    mutating func append(_ continuation: ShellCommandListContinuation) {
        rest.append(ShellStatementContinuation(
            operator: continuation.operator,
            connector: continuation.connector,
            pipeline: continuation.pipeline
        ))
    }
}

struct ShellStatementContinuation {
    var `operator`: ShellListOperator
    var connector: ShellCommandListConnector
    var pipeline: ShellPipeline

    var separator: ShellListSeparator? {
        connector.sourceSeparator
    }
}

struct ShellStatementEntry {
    var leadingOperator: ShellListOperator?
    var pipeline: ShellPipeline
}
