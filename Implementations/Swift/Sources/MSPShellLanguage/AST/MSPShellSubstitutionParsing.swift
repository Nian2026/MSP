extension ShellProcessSubstitution {
    func commandList(
        grammar: MSPShellGrammar,
        limits: MSPShellLimits,
        depth: Int
    ) throws -> ShellCommandList {
        let budget = ShellScriptParser.ParserBudget(limits: limits)
        return try commandList(grammar: grammar, budget: budget, depth: depth)
    }

    func commandList(
        grammar: MSPShellGrammar,
        budget: ShellScriptParser.ParserBudget,
        depth: Int
    ) throws -> ShellCommandList {
        try budget.validateSourceSize(command)
        let tokens = try ShellLexer.tokens(from: command, grammar: grammar)
        return try ShellScriptParser.commandList(from: tokens, grammar: grammar, budget: budget, depth: depth)
    }
}

extension ShellCommandSubstitution {
    func commandList(
        grammar: MSPShellGrammar,
        limits: MSPShellLimits,
        depth: Int
    ) throws -> ShellCommandList {
        let budget = ShellScriptParser.ParserBudget(limits: limits)
        return try commandList(grammar: grammar, budget: budget, depth: depth)
    }

    func commandList(
        grammar: MSPShellGrammar,
        budget: ShellScriptParser.ParserBudget,
        depth: Int
    ) throws -> ShellCommandList {
        try budget.validateSourceSize(command)
        let tokens = try ShellLexer.tokens(from: command, grammar: grammar)
        return try ShellScriptParser.commandList(from: tokens, grammar: grammar, budget: budget, depth: depth)
    }
}
