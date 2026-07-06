struct ShellReadSpec {
    var assignments: [ShellAssignmentClause]
    var names: [String]
    var delimiter: String?
}

enum ShellForValues {
    case explicit([ShellWord])
    case positionalParameters
}

struct ShellAssignmentClause: Equatable {
    var name: String
    var value: ShellWord
}

struct ShellArrayAssignmentClause: Equatable {
    var name: String
    var values: [ShellWord]
    var append: Bool
}

struct ShellSimpleCommand {
    var assignments: [ShellAssignmentClause] = []
    var words: [ShellWord]
    var redirections: [ShellRedirectionClause] = []

    var commandName: ShellWord? {
        words.first
    }

    var arguments: [ShellWord] {
        Array(words.dropFirst())
    }

    init(
        assignments: [ShellAssignmentClause] = [],
        words: [ShellWord],
        redirections: [ShellRedirectionClause] = []
    ) {
        self.assignments = assignments
        self.words = words
        self.redirections = redirections
    }

    init(words: [ShellWord], redirections: [ShellRedirectionClause]) {
        self.init(assignments: [], words: words, redirections: redirections)
    }
}

enum ShellStage {
    case command(ShellSimpleCommand)
    case assignmentList(assignments: [ShellAssignmentClause], arrays: [ShellArrayAssignmentClause], redirections: [ShellRedirectionClause])
    case arrayAssignment(name: String, values: [ShellWord], append: Bool)
    case subscriptAssignment(name: String, key: ShellWord, value: ShellWord, append: Bool)
    case arithmeticCommand(expression: String, redirections: [ShellRedirectionClause])
    case compound(ShellCompoundCommand)
    case functionDefinition(ShellFunctionDefinition)
}

enum ShellStageCategory: Equatable {
    case simpleCommand
    case assignment
    case arithmeticCommand
    case compoundCommand
    case functionDefinition
}

enum ShellCommandNodeRole: Equatable {
    case executable
    case assignmentOnly
}

extension ShellStage {
    var category: ShellStageCategory {
        switch self {
        case .command:
            return .simpleCommand
        case .assignmentList, .arrayAssignment, .subscriptAssignment:
            return .assignment
        case .arithmeticCommand:
            return .arithmeticCommand
        case .compound:
            return .compoundCommand
        case .functionDefinition:
            return .functionDefinition
        }
    }

    var commandNodeRole: ShellCommandNodeRole {
        switch category {
        case .assignment:
            return .assignmentOnly
        case .simpleCommand, .arithmeticCommand, .compoundCommand, .functionDefinition:
            return .executable
        }
    }
}

struct ShellCommandNode {
    var stage: ShellStage
    var role: ShellCommandNodeRole

    init(stage: ShellStage) {
        self.stage = stage
        self.role = stage.commandNodeRole
    }
}

struct ShellScript {
    var grammar: MSPShellGrammar
    var body: ShellCommandList

    init(grammar: MSPShellGrammar, body: ShellCommandList = ShellCommandList()) {
        self.grammar = grammar
        self.body = body
    }

    var pipelines: [ShellPipeline] {
        body.pipelines
    }
}
