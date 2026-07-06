import Foundation

protocol MSPShellASTVisitor {
    mutating func visit(commandList: ShellCommandList) throws
    mutating func visit(statement: ShellStatement) throws
    mutating func visit(pipeline: ShellPipeline) throws
    mutating func visit(commandNode: ShellCommandNode) throws
    mutating func visit(stage: ShellStage) throws
    mutating func visit(redirection: ShellRedirectionClause) throws -> Bool
    mutating func visit(hereDocument: ShellHereDocument, redirection: ShellRedirectionClause) throws -> Bool
    mutating func visit(word: ShellWord) throws -> Bool
    mutating func visit(expansionText: String) throws -> Bool
    mutating func enterLoop(_ command: ShellCompoundCommand) throws
    mutating func leaveLoop(_ command: ShellCompoundCommand)
}

extension MSPShellASTVisitor {
    mutating func visit(commandList: ShellCommandList) throws {}
    mutating func visit(statement: ShellStatement) throws {}
    mutating func visit(pipeline: ShellPipeline) throws {}
    mutating func visit(commandNode: ShellCommandNode) throws {}
    mutating func visit(stage: ShellStage) throws {}
    mutating func visit(redirection: ShellRedirectionClause) throws -> Bool { true }
    mutating func visit(hereDocument: ShellHereDocument, redirection: ShellRedirectionClause) throws -> Bool { true }
    mutating func visit(word: ShellWord) throws -> Bool { true }
    mutating func visit(expansionText: String) throws -> Bool { true }
    mutating func enterLoop(_ command: ShellCompoundCommand) throws {}
    mutating func leaveLoop(_ command: ShellCompoundCommand) {}
}

extension ShellScript {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        try body.walk(&visitor)
    }
}

extension ShellCommandList {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        try visitor.visit(commandList: self)
        for statement in statements {
            try statement.walk(&visitor)
        }
    }
}

extension ShellStatement {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        try visitor.visit(statement: self)
        for entry in entries {
            try entry.pipeline.walk(&visitor)
        }
    }
}

extension ShellPipeline {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        try visitor.visit(pipeline: self)
        for command in commands {
            try command.walk(&visitor)
        }
    }
}

extension ShellCommandNode {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        try visitor.visit(commandNode: self)
        try stage.walk(&visitor)
    }
}

extension ShellStage {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        try visitor.visit(stage: self)
        switch self {
        case .command(let command):
            try command.walk(&visitor)
        case .assignmentList(let assignments, let arrays, let redirections):
            for assignment in assignments {
                try assignment.value.walk(&visitor)
            }
            for array in arrays {
                for value in array.values {
                    try value.walk(&visitor)
                }
            }
            for redirection in redirections {
                try redirection.walk(&visitor)
            }
        case .arrayAssignment(_, let values, _):
            for value in values {
                try value.walk(&visitor)
            }
        case .subscriptAssignment(_, let key, let value, _):
            try key.walk(&visitor)
            try value.walk(&visitor)
        case .arithmeticCommand(let expression, let redirections):
            try MSPShellASTExpansionText.walk(expression, visitor: &visitor)
            for redirection in redirections {
                try redirection.walk(&visitor)
            }
        case .compound(let command):
            try command.walk(&visitor)
        case .functionDefinition(let definition):
            for redirection in definition.redirections {
                try redirection.walk(&visitor)
            }
            try definition.body.executionCommandList.walk(&visitor)
        }
    }
}

extension ShellSimpleCommand {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        for assignment in assignments {
            try assignment.value.walk(&visitor)
        }
        for word in words {
            try word.walk(&visitor)
        }
        for redirection in redirections {
            try redirection.walk(&visitor)
        }
    }
}

extension ShellCompoundCommand {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        switch self {
        case .ifThen(let branches, let elseBody, let redirections):
            try walk(redirections: redirections, visitor: &visitor)
            for branch in branches {
                try branch.condition.walk(&visitor)
                try branch.body.walk(&visitor)
            }
            try elseBody.walk(&visitor)
        case .whileLoop(let condition, let body, let redirections),
             .untilLoop(let condition, let body, let redirections):
            try walk(redirections: redirections, visitor: &visitor)
            try visitor.enterLoop(self)
            defer { visitor.leaveLoop(self) }
            try condition.walk(&visitor)
            try body.walk(&visitor)
        case .whileRead(let spec, let body, let redirections):
            for assignment in spec.assignments {
                try assignment.value.walk(&visitor)
            }
            try walk(redirections: redirections, visitor: &visitor)
            try visitor.enterLoop(self)
            defer { visitor.leaveLoop(self) }
            try body.walk(&visitor)
        case .forEach(_, let values, let body, let redirections):
            try walk(redirections: redirections, visitor: &visitor)
            if case .explicit(let words) = values {
                for word in words {
                    try word.walk(&visitor)
                }
            }
            try visitor.enterLoop(self)
            defer { visitor.leaveLoop(self) }
            try body.walk(&visitor)
        case .cStyleFor(_, _, _, let body, let redirections):
            try walk(redirections: redirections, visitor: &visitor)
            try visitor.enterLoop(self)
            defer { visitor.leaveLoop(self) }
            try body.walk(&visitor)
        case .caseOf(let subject, let arms, let redirections):
            try subject.walk(&visitor)
            try walk(redirections: redirections, visitor: &visitor)
            for arm in arms {
                for pattern in arm.patterns {
                    try pattern.walk(&visitor)
                }
                try arm.body.walk(&visitor)
            }
        case .conditional(let words, let redirections):
            for word in words {
                try word.walk(&visitor)
            }
            try walk(redirections: redirections, visitor: &visitor)
        case .group(let body, let redirections),
             .subshell(let body, let redirections):
            try walk(redirections: redirections, visitor: &visitor)
            try body.walk(&visitor)
        }
    }

    private func walk<V: MSPShellASTVisitor>(
        redirections: [ShellRedirectionClause],
        visitor: inout V
    ) throws {
        for redirection in redirections {
            try redirection.walk(&visitor)
        }
    }
}

extension ShellRedirectionClause {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        guard try visitor.visit(redirection: self) else { return }
        if let hereDocument = try hereDocument() {
            guard try visitor.visit(hereDocument: hereDocument, redirection: self) else {
                return
            }
            if hereDocument.expandable {
                let protected = MSPShellHereDocumentEscapes.protectExpandableEscapes(in: hereDocument.body)
                try MSPShellASTExpansionText.walk(protected.text, visitor: &visitor)
            }
            return
        }
        try target.walk(&visitor)
    }
}

extension ShellWord {
    func walk<V: MSPShellASTVisitor>(_ visitor: inout V) throws {
        guard try visitor.visit(word: self) else { return }
    }
}

enum MSPShellASTExpansionText {
    static func walk<V: MSPShellASTVisitor>(
        _ text: String,
        visitor: inout V
    ) throws {
        guard try visitor.visit(expansionText: text) else { return }
        var word = ShellWord()
        word.append(text, expandable: true)
        try word.walk(&visitor)
    }
}
