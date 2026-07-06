import Foundation

extension ShellScriptParser {
    final class ParserBudget {
        let limits: MSPShellLimits
        private var remainingOperations: Int

        init(limits: MSPShellLimits) {
            self.limits = limits
            remainingOperations = max(0, limits.maxParserOperations)
        }

        func validateSourceSize(_ source: String) throws {
            let maxInputBytes = limits.maxInputBytes
            guard maxInputBytes <= 0 || source.utf8.count <= maxInputBytes else {
                throw ShellExit(
                    code: 2,
                    message: "shell: input exceeds maximum size (\(source.utf8.count) > \(maxInputBytes) bytes)",
                    interruptsExecution: true
                )
            }
        }

        func enterParse(tokenCount: Int, depth: Int) throws {
            try consume()
            if limits.maxParserTokens > 0, tokenCount > limits.maxParserTokens {
                throw ShellExit(
                    code: 124,
                    message: "shell: maximum parser token count exceeded",
                    interruptsExecution: true
                )
            }
            if limits.maxParserDepth > 0, depth > limits.maxParserDepth {
                throw ShellExit(
                    code: 124,
                    message: "shell: maximum parser depth exceeded",
                    interruptsExecution: true
                )
            }
        }

        func consume(_ count: Int = 1) throws {
            guard limits.maxParserOperations > 0 else { return }
            remainingOperations -= max(1, count)
            guard remainingOperations >= 0 else {
                throw ShellExit(
                    code: 124,
                    message: "shell: maximum parser operation count exceeded",
                    interruptsExecution: true
                )
            }
        }
    }
}

enum MSPShellASTBudgetValidator {
    static func validate(_ script: ShellScript, limits: MSPShellLimits) throws {
        let budget = ShellScriptParser.ParserBudget(limits: limits)
        try validate(script, budget: budget)
    }

    static func validate(_ script: ShellScript, budget: ShellScriptParser.ParserBudget) throws {
        var visitor = BudgetVisitor(grammar: script.grammar, budget: budget)
        try script.walk(&visitor)
    }

    private struct BudgetVisitor: MSPShellASTVisitor {
        let grammar: MSPShellGrammar
        let budget: ShellScriptParser.ParserBudget
        var commandNodeCount = 0
        var loopDepth = 0
        var substitutionParseDepth = 0

        var limits: MSPShellLimits {
            budget.limits
        }

        mutating func visit(commandList: ShellCommandList) throws {
            guard commandList.first != nil || commandList.rest.isEmpty else {
                throw ShellExit.usage("shell: invalid parser AST: command list continuation without first pipeline")
            }
        }

        mutating func visit(statement: ShellStatement) throws {
            let entries = statement.entries
            guard let first = entries.first else {
                throw ShellExit.usage("shell: invalid parser AST: empty statement")
            }
            guard first.leadingOperator == nil else {
                throw ShellExit.usage("shell: invalid parser AST: statement starts with list operator")
            }
            guard entries.dropFirst().allSatisfy({ $0.leadingOperator != .semicolon }) else {
                throw ShellExit.usage("shell: invalid parser AST: statement contains command terminator")
            }
        }

        mutating func visit(pipeline: ShellPipeline) throws {
            guard !pipeline.commands.isEmpty else {
                throw ShellExit.usage("shell: invalid parser AST: empty pipeline")
            }
            guard pipeline.pipeOperators.count == max(0, pipeline.commands.count - 1) else {
                throw ShellExit.usage("shell: invalid parser AST: pipeline operator count mismatch")
            }
            try consumeCommandNode()
        }

        mutating func visit(stage: ShellStage) throws {
            try consumeCommandNode()
        }

        mutating func visit(word: ShellWord) throws -> Bool {
            for commandSubstitution in try word.commandSubstitutions(grammar: grammar) {
                try validate(commandSubstitution: commandSubstitution)
            }
            for processSubstitution in try word.processSubstitutions(grammar: grammar) {
                try validate(processSubstitution: processSubstitution)
            }
            return true
        }

        mutating func enterLoop(_ command: ShellCompoundCommand) throws {
            loopDepth += 1
            guard limits.maxStaticLoopDepth <= 0
                || loopDepth <= limits.maxStaticLoopDepth else {
                throw ShellExit(
                    code: 124,
                    message: "shell: maximum static loop nesting depth exceeded",
                    interruptsExecution: true
                )
            }
        }

        mutating func leaveLoop(_ command: ShellCompoundCommand) {
            loopDepth -= 1
        }

        private mutating func consumeCommandNode() throws {
            commandNodeCount += 1
            guard limits.maxStaticCommandNodes <= 0
                || commandNodeCount <= limits.maxStaticCommandNodes else {
                throw ShellExit(
                    code: 124,
                    message: "shell: maximum static command node count exceeded",
                    interruptsExecution: true
                )
            }
        }

        private mutating func validate(
            commandSubstitution: ShellCommandSubstitution
        ) throws {
            let depth = try enterSubstitutionParseDepth()
            defer { leaveSubstitutionParseDepth() }
            let commandList = try commandSubstitution.commandList(
                grammar: grammar,
                budget: budget,
                depth: depth
            )
            try commandList.walk(&self)
        }

        private mutating func validate(
            processSubstitution: ShellProcessSubstitution
        ) throws {
            let depth = try enterSubstitutionParseDepth()
            defer { leaveSubstitutionParseDepth() }
            let commandList = try processSubstitution.commandList(
                grammar: grammar,
                budget: budget,
                depth: depth
            )
            try commandList.walk(&self)
        }

        private mutating func enterSubstitutionParseDepth() throws -> Int {
            substitutionParseDepth += 1
            guard limits.maxParserDepth <= 0
                || substitutionParseDepth <= limits.maxParserDepth else {
                throw ShellExit(
                    code: 124,
                    message: "shell: maximum parser depth exceeded",
                    interruptsExecution: true
                )
            }
            return substitutionParseDepth
        }

        private mutating func leaveSubstitutionParseDepth() {
            substitutionParseDepth -= 1
        }
    }
}
