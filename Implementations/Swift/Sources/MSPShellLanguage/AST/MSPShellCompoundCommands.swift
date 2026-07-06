enum ShellCompoundCommand {
    case ifThen(branches: [ShellIfBranch], elseBody: ShellCommandList, redirections: [ShellRedirectionClause])
    case whileLoop(condition: ShellCommandList, body: ShellCommandList, redirections: [ShellRedirectionClause])
    case untilLoop(condition: ShellCommandList, body: ShellCommandList, redirections: [ShellRedirectionClause])
    case whileRead(spec: ShellReadSpec, body: ShellCommandList, redirections: [ShellRedirectionClause])
    case forEach(variable: String, values: ShellForValues, body: ShellCommandList, redirections: [ShellRedirectionClause])
    case cStyleFor(initExpression: String, conditionExpression: String, updateExpression: String, body: ShellCommandList, redirections: [ShellRedirectionClause])
    case caseOf(subject: ShellWord, arms: [ShellCaseArm], redirections: [ShellRedirectionClause])
    case conditional(words: [ShellWord], redirections: [ShellRedirectionClause])
    case group(body: ShellCommandList, redirections: [ShellRedirectionClause])
    case subshell(body: ShellCommandList, redirections: [ShellRedirectionClause])
}

extension ShellCompoundCommand {
    var redirections: [ShellRedirectionClause] {
        switch self {
        case .ifThen(_, _, let redirections),
             .whileLoop(_, _, let redirections),
             .untilLoop(_, _, let redirections),
             .whileRead(_, _, let redirections),
             .forEach(_, _, _, let redirections),
             .cStyleFor(_, _, _, _, let redirections),
             .caseOf(_, _, let redirections),
             .conditional(_, let redirections),
             .group(_, let redirections),
             .subshell(_, let redirections):
            return redirections
        }
    }
}

struct ShellIfBranch {
    var condition: ShellCommandList
    var body: ShellCommandList
}

enum ShellCaseTerminator: Equatable {
    case breakArm
    case fallThrough
    case continueMatching

    var tokenText: String {
        switch self {
        case .breakArm:
            return ";;"
        case .fallThrough:
            return ";&"
        case .continueMatching:
            return ";;&"
        }
    }
}

struct ShellCaseArm {
    var patterns: [ShellWord]
    var body: ShellCommandList
    var terminator: ShellCaseTerminator

    init(
        patterns: [ShellWord],
        body: ShellCommandList,
        terminator: ShellCaseTerminator = .breakArm
    ) {
        self.patterns = patterns
        self.body = body
        self.terminator = terminator
    }
}

enum ShellFunctionBody {
    case braceGroup(ShellCommandList)
    case subshell(ShellCommandList)

    var innerCommandList: ShellCommandList {
        switch self {
        case .braceGroup(let body), .subshell(let body):
            return body
        }
    }

    var executionCommandList: ShellCommandList {
        switch self {
        case .braceGroup(let body):
            return body
        case .subshell(let body):
            return ShellCommandList(pipelines: [
                ShellPipeline(
                    negated: false,
                    commands: [
                        ShellCommandNode(stage: .compound(.subshell(body: body, redirections: [])))
                    ]
                )
            ])
        }
    }
}

struct ShellFunctionDefinition {
    var name: String
    var body: ShellFunctionBody
    var redirections: [ShellRedirectionClause] = []

    init(
        name: String,
        body: ShellFunctionBody,
        redirections: [ShellRedirectionClause] = []
    ) {
        self.name = name
        self.body = body
        self.redirections = redirections
    }

    init(
        name: String,
        body: ShellCommandList,
        redirections: [ShellRedirectionClause] = []
    ) {
        self.init(name: name, body: .braceGroup(body), redirections: redirections)
    }
}
