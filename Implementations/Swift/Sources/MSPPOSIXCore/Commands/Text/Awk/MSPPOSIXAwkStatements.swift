import Foundation

extension MSPPOSIXAwkRunner {
    func executeStatements(_ body: String) throws {
        let statements = MSPPOSIXAwkSyntax.splitStatements(body)
        var index = 0
        while index < statements.count {
            var statement = statements[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if statement.hasPrefix("if"), index + 1 < statements.count {
                let next = statements[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.hasPrefix("else") {
                    statement += " " + next
                    index += 1
                }
            }
            try executeStatement(statement)
            index += 1
        }
    }

    private func executeStatement(_ statement: String) throws {
        guard !statement.isEmpty else { return }
        guard let node = MSPPOSIXAwkStatementParser.parse(statement) else {
            try executeAssignmentOrExpression(statement)
            return
        }
        try executeStatementNode(node)
    }

    private func executeStatementNode(_ node: StatementNode) throws {
        switch node {
        case .print(let expression, let redirection):
            let expressionText = expression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text: String
            if expressionText.isEmpty {
                text = currentLine
            } else {
                let expressions = MSPPOSIXAwkSyntax.splitTopLevel(expressionText, separator: ",")
                text = expressions.map { evaluateString($0) }.joined(separator: variables["OFS"] ?? " ")
            }
            emitAwkOutput(text, terminator: true, redirection: redirection)
        case .printf(let expression, let redirection):
            let expressions = MSPPOSIXAwkSyntax.splitTopLevel(expression, separator: ",")
            guard let format = expressions.first else { return }
            let values = expressions.dropFirst().map { evaluateString($0) }
            let text = MSPPOSIXAwkPrintf.format(format: evaluateString(format), values: values)
            emitAwkOutput(text, terminator: false, redirection: redirection)
        case .delete(let target):
            executeDeleteStatement(target)
        case .returnStatement(let expression):
            throw ReturnSignal(value: expression.map { evaluateString($0) } ?? "")
        case .exitStatement:
            throw ExitSignal()
        case .ifStatement(let condition, let thenBody, let elseBody):
            if evaluateBool(condition) {
                try executeStatementOrBlock(thenBody)
            } else if let elseBody {
                try executeStatementOrBlock(elseBody)
            }
        case .forStatement(let header, let body):
            try executeForStatement(header: header, body: body)
        case .whileLoop(let condition, let body):
            try executeWhileStatement(condition: condition, body: body)
        case .expression(let expression):
            _ = evaluateExpressionNode(expression)
        }
    }

    private func executeWhileStatement(condition: String, body: String) throws {
        var guardCount = 0
        while evaluateBool(condition) {
            try executeStatementOrBlock(body)
            guardCount += 1
            if guardCount > 100_000 {
                throw MSPPOSIXAwkError.usage("awk: while loop exceeded iteration limit")
            }
        }
    }

    private func emitAwkOutput(_ text: String, terminator: Bool, redirection: OutputRedirection?) {
        guard let redirection else {
            output.append(terminator ? text + (variables["ORS"] ?? "\n") : text)
            return
        }
        let path = evaluateString(redirection.pathExpression)
        guard !path.isEmpty else { return }
        let chunk = terminator ? text + (variables["ORS"] ?? "\n") : text
        if var existing = fileOutputs[path] {
            existing.text += chunk
            fileOutputs[path] = existing
        } else {
            fileOutputs[path] = MSPPOSIXAwkFileOutput(path: path, append: redirection.append, text: chunk)
            fileOutputOrder.append(path)
        }
    }

    private func executeDeleteStatement(_ targetText: String) {
        let target = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if let subscriptRange = MSPPOSIXAwkSyntax.topLevelSubscript(in: target) {
            let name = String(target[..<subscriptRange.nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = evaluateString(String(target[subscriptRange.keyRange]))
            arrays[name]?[key] = nil
        } else {
            arrays[target] = [:]
            variables[target] = nil
        }
    }

    private func executeForStatement(header: String, body: String) throws {
        let pieces = header.components(separatedBy: " in ")
        if pieces.count == 2 {
            let variableName = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let arrayName = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            for key in (arrays[arrayName] ?? [:]).keys.sorted() {
                variables[variableName] = key
                try executeStatementOrBlock(body)
            }
            return
        }

        let clauses = MSPPOSIXAwkSyntax.splitTopLevel(header, separator: ";")
        guard clauses.count == 3 else {
            throw MSPPOSIXAwkError.usage("awk: malformed for")
        }
        let initClause = clauses[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let conditionClause = clauses[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let incrementClause = clauses[2].trimmingCharacters(in: .whitespacesAndNewlines)
        if !initClause.isEmpty {
            executeExpressionClause(initClause)
        }
        var guardCount = 0
        while conditionClause.isEmpty || evaluateBool(conditionClause) {
            try executeStatementOrBlock(body)
            if !incrementClause.isEmpty {
                executeExpressionClause(incrementClause)
            }
            guardCount += 1
            if guardCount > 100_000 {
                throw MSPPOSIXAwkError.usage("awk: for loop exceeded iteration limit")
            }
        }
    }

    private func executeExpressionClause(_ clause: String) {
        _ = evaluateExpressionNode(MSPPOSIXAwkExpressionParser.parse(clause))
    }

    private func executeStatementOrBlock(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            try executeStatements(String(trimmed.dropFirst().dropLast()))
        } else {
            try executeStatement(trimmed)
        }
    }
}

enum MSPPOSIXAwkStatementParser {
    static func parse(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let printNode = parsePrint(trimmed) {
            return printNode
        }
        if let printfNode = parsePrintf(trimmed) {
            return printfNode
        }
        if let returnNode = parseReturn(trimmed) {
            return returnNode
        }
        if let exitNode = parseExit(trimmed) {
            return exitNode
        }
        if let deleteNode = parseDelete(trimmed) {
            return deleteNode
        }
        if let ifNode = parseIf(trimmed) {
            return ifNode
        }
        if let forNode = parseFor(trimmed) {
            return forNode
        }
        if let whileNode = parseWhile(trimmed) {
            return whileNode
        }
        return .expression(MSPPOSIXAwkExpressionParser.parse(trimmed))
    }

    private static func parseWhile(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard !statement.isEmpty,
              MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "while") else {
            return nil
        }
        var index = statement.index(statement.startIndex, offsetBy: "while".count)
        MSPPOSIXAwkSyntax.skipWhitespace(in: statement, index: &index)
        guard index < statement.endIndex, statement[index] == "(",
              let close = try? MSPPOSIXAwkSyntax.matchingParen(in: statement, open: index) else {
            return nil
        }
        let condition = String(statement[statement.index(after: index)..<close])
        let body = String(statement[statement.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return .whileLoop(condition: condition, body: body)
    }

    private static func parsePrint(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "print") else {
            return nil
        }
        let rest = String(statement.dropFirst("print".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty {
            return .print(expression: nil, redirection: nil)
        }
        if rest.hasPrefix("("), rest.hasSuffix(")"),
           let close = try? MSPPOSIXAwkSyntax.matchingParen(in: rest, open: rest.startIndex),
           close == rest.index(before: rest.endIndex) {
            return .print(expression: MSPPOSIXAwkSyntax.enclosedArguments("print" + rest), redirection: nil)
        }
        let parsed = parseAwkOutputRedirection(in: rest)
        return .print(expression: parsed.expression, redirection: parsed.redirection)
    }

    private static func parsePrintf(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "printf") else {
            return nil
        }
        let rest = String(statement.dropFirst("printf".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("("), rest.hasSuffix(")"),
           let close = try? MSPPOSIXAwkSyntax.matchingParen(in: rest, open: rest.startIndex),
           close == rest.index(before: rest.endIndex) {
            return .printf(expression: MSPPOSIXAwkSyntax.enclosedArguments("printf" + rest), redirection: nil)
        }
        let parsed = parseAwkOutputRedirection(in: rest)
        return .printf(expression: parsed.expression, redirection: parsed.redirection)
    }

    private static func parseReturn(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "return") else {
            return nil
        }
        let expression = String(statement.dropFirst("return".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .returnStatement(expression: expression.isEmpty ? nil : expression)
    }

    private static func parseExit(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "exit") else {
            return nil
        }
        return .exitStatement
    }

    private static func parseDelete(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "delete") else {
            return nil
        }
        let target = String(statement.dropFirst("delete".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : .delete(target: target)
    }

    private static func parseIf(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "if"),
              let open = statement.firstIndex(of: "("),
              let close = try? MSPPOSIXAwkSyntax.matchingParen(in: statement, open: open) else {
            return nil
        }
        let condition = String(statement[statement.index(after: open)..<close])
        let remainder = String(statement[statement.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = MSPPOSIXAwkSyntax.splitIfBodies(remainder)
        return .ifStatement(condition: condition, thenBody: parts.thenBody, elseBody: parts.elseBody)
    }

    private static func parseFor(_ statement: String) -> MSPPOSIXAwkRunner.StatementNode? {
        guard MSPPOSIXAwkSyntax.keywordAt(statement.startIndex, in: statement, is: "for"),
              let open = statement.firstIndex(of: "("),
              let close = try? MSPPOSIXAwkSyntax.matchingParen(in: statement, open: open) else {
            return nil
        }
        let header = String(statement[statement.index(after: open)..<close])
        let body = String(statement[statement.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return .forStatement(header: header, body: body)
    }

    private static func parseAwkOutputRedirection(
        in text: String
    ) -> (expression: String, redirection: MSPPOSIXAwkRunner.OutputRedirection?) {
        if let range = MSPPOSIXAwkSyntax.findTopLevel(">>", in: text, startingAt: text.startIndex) {
            return (
                String(text[..<range.lowerBound]),
                MSPPOSIXAwkRunner.OutputRedirection(pathExpression: String(text[range.upperBound...]), append: true)
            )
        }
        if let range = MSPPOSIXAwkSyntax.findTopLevel(">", in: text, startingAt: text.startIndex) {
            return (
                String(text[..<range.lowerBound]),
                MSPPOSIXAwkRunner.OutputRedirection(pathExpression: String(text[range.upperBound...]), append: false)
            )
        }
        return (text, nil)
    }
}
