import Foundation

enum ShellScriptParser {
    static func script(
        from command: String,
        grammar: MSPShellGrammar = .msp,
        limits: MSPShellLimits = MSPShellLimits()
    ) throws -> ShellScript {
        let budget = ParserBudget(limits: limits)
        try budget.validateSourceSize(command)
        let tokens = try ShellLexer.tokens(from: command, grammar: grammar)
        return try script(from: tokens, grammar: grammar, budget: budget, depth: 0)
    }

    static func commandList(
        from command: String,
        grammar: MSPShellGrammar = .msp,
        limits: MSPShellLimits = MSPShellLimits()
    ) throws -> ShellCommandList {
        try script(from: command, grammar: grammar, limits: limits).body
    }

    static func pipelines(
        from command: String,
        grammar: MSPShellGrammar = .msp,
        limits: MSPShellLimits = MSPShellLimits()
    ) throws -> [ShellPipeline] {
        try script(from: command, grammar: grammar, limits: limits).pipelines
    }

    static func script(
        from tokens: [ShellToken],
        grammar: MSPShellGrammar = .msp,
        budget: ParserBudget,
        depth: Int
    ) throws -> ShellScript {
        let script = ShellScript(
            grammar: grammar,
            body: try commandList(from: tokens, grammar: grammar, budget: budget, depth: depth)
        )
        try MSPShellASTBudgetValidator.validate(script, budget: budget)
        return script
    }

    static func commandList(
        from tokens: [ShellToken],
        grammar: MSPShellGrammar = .msp,
        budget: ParserBudget,
        depth: Int
    ) throws -> ShellCommandList {
        try budget.enterParse(tokenCount: tokens.count, depth: depth)
        var parser = TokenParser(tokens: tokens, grammar: grammar, budget: budget, depth: depth)
        return try parser.parseCommandList()
    }

    static func pipelines(
        from tokens: [ShellToken],
        grammar: MSPShellGrammar = .msp,
        budget: ParserBudget,
        depth: Int
    ) throws -> [ShellPipeline] {
        try commandList(from: tokens, grammar: grammar, budget: budget, depth: depth).pipelines
    }
}
