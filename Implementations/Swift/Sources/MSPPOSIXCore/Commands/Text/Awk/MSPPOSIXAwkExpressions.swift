import Foundation

extension MSPPOSIXAwkRunner {
    func executeAssignmentOrExpression(_ statement: String) throws {
        _ = evaluateExpressionNode(MSPPOSIXAwkExpressionParser.parse(statement))
    }

    func evaluateBool(_ expression: String) -> Bool {
        let trimmed = MSPPOSIXAwkSyntax.strippingOuterParens(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        let parsedExpression = MSPPOSIXAwkExpressionParser.parse(trimmed)
        if case .raw = parsedExpression {
            // Fall through to boolean/comparison parsing below.
        } else {
            return MSPPOSIXAwkTypeCoercion.isTruthy(evaluateExpressionNode(parsedExpression))
        }
        if let negated = unaryNotOperand(trimmed) {
            return !evaluateBool(negated)
        }
        if trimmed.hasPrefix("/"), trimmed.hasSuffix("/"), trimmed.count >= 2 {
            let pattern = regexPattern(from: trimmed)
            return currentLine.range(of: pattern, options: regexOptions) != nil
        }
        if let parts = MSPPOSIXAwkSyntax.splitByTopLevelOperator(trimmed, operatorText: "||") {
            return parts.contains { evaluateBool($0) }
        }
        if let parts = MSPPOSIXAwkSyntax.splitByTopLevelOperator(trimmed, operatorText: "&&") {
            return parts.allSatisfy { evaluateBool($0) }
        }
        if let ternary = MSPPOSIXAwkSyntax.splitTernary(trimmed) {
            return evaluateBool(ternary.condition) ? evaluateBool(ternary.trueExpression) : evaluateBool(ternary.falseExpression)
        }
        if let range = MSPPOSIXAwkSyntax.findTopLevelOperator("!~", in: trimmed) {
            let lhs = evaluateString(String(trimmed[..<range.lowerBound]))
            let pattern = regexPattern(from: String(trimmed[range.upperBound...]))
            return lhs.range(of: pattern, options: regexOptions) == nil
        }
        if let range = MSPPOSIXAwkSyntax.findTopLevelOperator("~", in: trimmed) {
            let lhs = evaluateString(String(trimmed[..<range.lowerBound]))
            let pattern = regexPattern(from: String(trimmed[range.upperBound...]))
            return lhs.range(of: pattern, options: regexOptions) != nil
        }
        for operatorText in ["==", "!=", ">=", "<=", ">", "<"] {
            if let range = MSPPOSIXAwkSyntax.findTopLevelOperator(operatorText, in: trimmed) {
                let lhs = evaluateString(String(trimmed[..<range.lowerBound]))
                let rhs = evaluateString(String(trimmed[range.upperBound...]))
                switch operatorText {
                case "==": return lhs == rhs
                case "!=": return lhs != rhs
                case ">", ">=", "<", "<=":
                    if let lhsNumber = MSPPOSIXAwkTypeCoercion.exactNumber(lhs),
                       let rhsNumber = MSPPOSIXAwkTypeCoercion.exactNumber(rhs) {
                        switch operatorText {
                        case ">": return lhsNumber > rhsNumber
                        case ">=": return lhsNumber >= rhsNumber
                        case "<": return lhsNumber < rhsNumber
                        case "<=": return lhsNumber <= rhsNumber
                        default: break
                        }
                    } else if MSPPOSIXAwkTypeCoercion.looksNumeric(lhs) || MSPPOSIXAwkTypeCoercion.looksNumeric(rhs) {
                        let lhsNumber = numericValue(String(trimmed[..<range.lowerBound]))
                        let rhsNumber = numericValue(String(trimmed[range.upperBound...]))
                        switch operatorText {
                        case ">": return lhsNumber > rhsNumber
                        case ">=": return lhsNumber >= rhsNumber
                        case "<": return lhsNumber < rhsNumber
                        case "<=": return lhsNumber <= rhsNumber
                        default: break
                        }
                    }
                    switch operatorText {
                    case ">": return lhs > rhs
                    case ">=": return lhs >= rhs
                    case "<": return lhs < rhs
                    case "<=": return lhs <= rhs
                    default: break
                    }
                default:
                    break
                }
            }
        }
        if let range = MSPPOSIXAwkSyntax.findTopLevelInOperator(in: trimmed) {
            let key = evaluateString(String(trimmed[..<range.lowerBound]))
            let arrayName = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return arrays[arrayName]?[key] != nil
        }
        let value = evaluateString(trimmed)
        return MSPPOSIXAwkTypeCoercion.isTruthy(value)
    }

    func evaluateString(_ expression: String) -> String {
        let trimmed = MSPPOSIXAwkSyntax.strippingOuterParens(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "" }
        let parsedExpression = MSPPOSIXAwkExpressionParser.parse(trimmed)
        if case .raw(let rawExpression) = parsedExpression {
            return evaluateRawString(rawExpression)
        }
        return evaluateExpressionNode(parsedExpression)
    }

    func evaluateExpressionNode(_ node: ExpressionNode) -> String {
        switch node {
        case .assignment(let target, let operation, let valueExpression):
            let value = assignmentValue(target: target, operation: operation, valueExpression: valueExpression)
            setLValue(target, value: value)
            return value
        case .mutation(let target, let operation):
            let oldValue = evaluateLValue(target)
            let delta = operation == .preIncrement || operation == .postIncrement ? 1.0 : -1.0
            let newValue = MSPPOSIXAwkTypeCoercion.string(storedNumberValue(target) + delta)
            setLValue(target, value: newValue)
            return operation == .postIncrement || operation == .postDecrement ? oldValue : newValue
        case .binary(let operation, let left, let right):
            return evaluateBinaryExpression(operation, left: left, right: right)
        case .functionCall(let name, let arguments):
            return evaluateFunctionCall(name: name, arguments: arguments)
        case .fileGetline, .pipeGetline:
            return evaluateGetlineExpression(node)
        case .raw(let expression):
            return evaluateRawString(expression)
        }
    }

    private func evaluateRawString(_ expression: String) -> String {
        let trimmed = MSPPOSIXAwkSyntax.strippingOuterParens(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "" }
        if let ternary = MSPPOSIXAwkSyntax.splitTernary(trimmed) {
            return evaluateBool(ternary.condition) ? evaluateString(ternary.trueExpression) : evaluateString(ternary.falseExpression)
        }
        if unaryNotOperand(trimmed) != nil || containsTopLevelBooleanOperator(trimmed) {
            return evaluateBool(trimmed) ? "1" : "0"
        }
        for operatorGroup in [["+", "-"], ["*", "/"]] {
            if let (operatorText, range) = MSPPOSIXAwkSyntax.findRightmostTopLevelArithmeticOperator(operatorGroup, in: trimmed) {
                let lhs = numericValue(String(trimmed[..<range.lowerBound]))
                let rhs = numericValue(String(trimmed[range.upperBound...]))
                switch operatorText {
                case "+":
                    return MSPPOSIXAwkTypeCoercion.string(lhs + rhs)
                case "-":
                    return MSPPOSIXAwkTypeCoercion.string(lhs - rhs)
                case "*":
                    return MSPPOSIXAwkTypeCoercion.string(lhs * rhs)
                case "/":
                    return rhs == 0 ? "0" : MSPPOSIXAwkTypeCoercion.string(lhs / rhs)
                default:
                    break
                }
            }
        }
        if trimmed == "$0" {
            return currentLine
        }
        if trimmed == "NR" {
            return String(recordNumber)
        }
        if trimmed == "NF" {
            return String(currentFields.count)
        }
        if trimmed == "$NF" {
            return currentFields.last ?? ""
        }
        if trimmed.hasPrefix("$"), let fieldNumber = Int(trimmed.dropFirst()) {
            return field(fieldNumber)
        }
        let parts = MSPPOSIXAwkSyntax.splitConcatenation(trimmed)
        if parts.count > 1 {
            return parts.map { evaluateString($0) }.joined()
        }
        if MSPPOSIXAwkSyntax.isQuotedString(trimmed) {
            return MSPPOSIXAwkSyntax.decodeAwkString(String(trimmed.dropFirst().dropLast()))
        }
        if MSPPOSIXAwkSyntax.isRegexLiteral(trimmed) {
            return trimmed
        }
        if let subscriptRange = MSPPOSIXAwkSyntax.topLevelSubscript(in: trimmed) {
            let name = String(trimmed[..<subscriptRange.nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = evaluateString(String(trimmed[subscriptRange.keyRange]))
            if let value = arrays[name]?[key] {
                return value
            }
            arrays[name, default: [:]][key] = ""
            return ""
        }
        if let value = variables[trimmed] {
            return value
        }
        if MSPPOSIXAwkSyntax.isAwkIdentifier(trimmed) {
            return ""
        }
        return trimmed
    }

    private func assignmentValue(
        target: LValueNode,
        operation: ExpressionNode.AssignmentOperator,
        valueExpression: ExpressionNode
    ) -> String {
        switch operation {
        case .assign:
            return evaluateExpressionNode(valueExpression)
        case .addAssign:
            return MSPPOSIXAwkTypeCoercion.string(storedNumberValue(target) + numericValue(valueExpression))
        case .subAssign:
            return MSPPOSIXAwkTypeCoercion.string(storedNumberValue(target) - numericValue(valueExpression))
        case .mulAssign:
            return MSPPOSIXAwkTypeCoercion.string(storedNumberValue(target) * numericValue(valueExpression))
        case .divAssign:
            let rhs = numericValue(valueExpression)
            return rhs == 0 ? "0" : MSPPOSIXAwkTypeCoercion.string(storedNumberValue(target) / rhs)
        case .modAssign:
            let rhs = numericValue(valueExpression)
            return rhs == 0 ? "0" : MSPPOSIXAwkTypeCoercion.string(storedNumberValue(target).truncatingRemainder(dividingBy: rhs))
        case .powAssign:
            return MSPPOSIXAwkTypeCoercion.string(pow(storedNumberValue(target), numericValue(valueExpression)))
        }
    }

    private func evaluateBinaryExpression(
        _ operation: ExpressionNode.BinaryOperator,
        left: ExpressionNode,
        right: ExpressionNode
    ) -> String {
        switch operation {
        case .or:
            return (evaluateBool(left) || evaluateBool(right)) ? "1" : "0"
        case .and:
            return (evaluateBool(left) && evaluateBool(right)) ? "1" : "0"
        case .match, .notMatch:
            let lhs = evaluateExpressionNode(left)
            let pattern = regexPattern(from: regexPatternExpression(right))
            let matched = lhs.range(of: pattern, options: regexOptions) != nil
            return (operation == .match ? matched : !matched) ? "1" : "0"
        case .equal, .notEqual:
            let lhs = evaluateExpressionNode(left)
            let rhs = evaluateExpressionNode(right)
            let matched = lhs == rhs
            return (operation == .equal ? matched : !matched) ? "1" : "0"
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            return evaluateComparison(operation, left: left, right: right) ? "1" : "0"
        case .add, .subtract, .multiply, .divide, .modulo, .power:
            return evaluateArithmetic(operation, left: left, right: right)
        }
    }

    private func evaluateBool(_ node: ExpressionNode) -> Bool {
        MSPPOSIXAwkTypeCoercion.isTruthy(evaluateExpressionNode(node))
    }

    private func evaluateComparison(
        _ operation: ExpressionNode.BinaryOperator,
        left: ExpressionNode,
        right: ExpressionNode
    ) -> Bool {
        let lhs = evaluateExpressionNode(left)
        let rhs = evaluateExpressionNode(right)
        if let lhsNumber = MSPPOSIXAwkTypeCoercion.exactNumber(lhs),
           let rhsNumber = MSPPOSIXAwkTypeCoercion.exactNumber(rhs) {
            switch operation {
            case .greaterThan: return lhsNumber > rhsNumber
            case .greaterThanOrEqual: return lhsNumber >= rhsNumber
            case .lessThan: return lhsNumber < rhsNumber
            case .lessThanOrEqual: return lhsNumber <= rhsNumber
            default: break
            }
        } else if MSPPOSIXAwkTypeCoercion.looksNumeric(lhs) || MSPPOSIXAwkTypeCoercion.looksNumeric(rhs) {
            let lhsNumber = MSPPOSIXAwkTypeCoercion.number(lhs)
            let rhsNumber = MSPPOSIXAwkTypeCoercion.number(rhs)
            switch operation {
            case .greaterThan: return lhsNumber > rhsNumber
            case .greaterThanOrEqual: return lhsNumber >= rhsNumber
            case .lessThan: return lhsNumber < rhsNumber
            case .lessThanOrEqual: return lhsNumber <= rhsNumber
            default: break
            }
        }
        switch operation {
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        default: return false
        }
    }

    private func evaluateArithmetic(
        _ operation: ExpressionNode.BinaryOperator,
        left: ExpressionNode,
        right: ExpressionNode
    ) -> String {
        let lhs = numericValue(left)
        let rhs = numericValue(right)
        switch operation {
        case .add:
            return MSPPOSIXAwkTypeCoercion.string(lhs + rhs)
        case .subtract:
            return MSPPOSIXAwkTypeCoercion.string(lhs - rhs)
        case .multiply:
            return MSPPOSIXAwkTypeCoercion.string(lhs * rhs)
        case .divide:
            return rhs == 0 ? "0" : MSPPOSIXAwkTypeCoercion.string(lhs / rhs)
        case .modulo:
            return rhs == 0 ? "0" : MSPPOSIXAwkTypeCoercion.string(lhs.truncatingRemainder(dividingBy: rhs))
        case .power:
            return MSPPOSIXAwkTypeCoercion.string(pow(lhs, rhs))
        default:
            return "0"
        }
    }

    private func regexPatternExpression(_ node: ExpressionNode) -> String {
        if case .raw(let expression) = node {
            return expression
        }
        return evaluateExpressionNode(node)
    }

    func evaluateGetlineExpression(_ node: ExpressionNode) -> String {
        do {
            switch node {
            case .fileGetline(let target, let pathExpression):
                return try fileGetline(pathExpression: pathExpression, target: target)
            case .pipeGetline(let commandExpression, let target):
                return try pipeGetline(commandExpression: commandExpression, target: target)
            default:
                return "0"
            }
        } catch {
            return "-1"
        }
    }

    func pipeGetline(commandExpression: ExpressionNode, target: LValueNode?) throws -> String {
        let command = evaluateExpressionNode(commandExpression)
        guard !command.isEmpty else { return "0" }
        if pipeOutputRecords[command] == nil {
            let stdout = try commandOutput(command)
            pipeOutputRecords[command] = MSPPOSIXAwkFields.records(in: stdout, separator: variables["RS"] ?? "\n")
        }
        guard var records = pipeOutputRecords[command], !records.isEmpty else {
            return "0"
        }
        let line = records.removeFirst()
        pipeOutputRecords[command] = records
        if let target {
            setLValue(target, value: line)
        } else {
            setCurrentLine(line)
        }
        return "1"
    }

    func fileGetline(pathExpression: ExpressionNode, target: LValueNode?) throws -> String {
        let path = evaluateExpressionNode(pathExpression)
        guard !path.isEmpty else { return "0" }
        if fileInputRecords[path] == nil {
            let text = try fileInput(path)
            fileInputRecords[path] = MSPPOSIXAwkFields.records(in: text, separator: variables["RS"] ?? "\n")
        }
        guard var records = fileInputRecords[path], !records.isEmpty else {
            return "0"
        }
        let line = records.removeFirst()
        fileInputRecords[path] = records
        if let target {
            setLValue(target, value: line)
        } else {
            setCurrentLine(line)
        }
        return "1"
    }

    func numericValue(_ expression: String) -> Double {
        MSPPOSIXAwkTypeCoercion.number(evaluateString(expression))
    }

    func numericValue(_ expression: ExpressionNode) -> Double {
        MSPPOSIXAwkTypeCoercion.number(evaluateExpressionNode(expression))
    }

    func evaluateLValue(_ target: LValueNode) -> String {
        switch target {
        case .variable(let name):
            return variables[name] ?? ""
        case .field(let number):
            return number == 0 ? currentLine : field(number)
        case .arrayElement(let name, let keyExpression):
            let key = evaluateExpressionNode(keyExpression)
            if let value = arrays[name]?[key] {
                return value
            }
            arrays[name, default: [:]][key] = ""
            return ""
        }
    }

    func setLValue(_ lhs: String, value: String) {
        setLValue(MSPPOSIXAwkExpressionParser.parseLValue(lhs), value: value)
    }

    func setLValue(_ target: LValueNode, value: String) {
        switch target {
        case .field(0):
            setCurrentLine(value)
        case .field(let number):
            setField(number, value: value)
        case .arrayElement(let name, let keyExpression):
            let key = evaluateExpressionNode(keyExpression)
            arrays[name, default: [:]][key] = value
        case .variable(let name):
            variables[name] = value
        }
    }

    func setCurrentLine(_ line: String) {
        currentLine = line
        currentFields = MSPPOSIXAwkFields.split(line: line, fieldSeparator: fieldSeparator ?? variables["FS"])
    }

    private func containsTopLevelBooleanOperator(_ expression: String) -> Bool {
        if MSPPOSIXAwkSyntax.findTopLevelInOperator(in: expression) != nil {
            return true
        }
        for operatorText in ["||", "&&", "!~", "==", "!=", ">=", "<=", "~", ">", "<"] {
            if MSPPOSIXAwkSyntax.findTopLevelOperator(operatorText, in: expression) != nil {
                return true
            }
        }
        return false
    }

    private func unaryNotOperand(_ expression: String) -> String? {
        guard expression.hasPrefix("!") else { return nil }
        let next = expression.index(after: expression.startIndex)
        if next < expression.endIndex, expression[next] == "=" || expression[next] == "~" {
            return nil
        }
        return String(expression[next...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func storedNumberValue(_ lvalue: LValueNode) -> Double {
        MSPPOSIXAwkTypeCoercion.number(evaluateLValue(lvalue))
    }

    private func setField(_ number: Int, value: String) {
        MSPPOSIXAwkFields.setField(number, value: value, currentFields: &currentFields, currentLine: &currentLine)
    }

    private func field(_ number: Int) -> String {
        MSPPOSIXAwkFields.field(number, currentFields: currentFields)
    }

    var regexOptions: String.CompareOptions {
        variables["IGNORECASE"] == "1" ? [.regularExpression, .caseInsensitive] : [.regularExpression]
    }

    func regexPattern(from expression: String) -> String {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if MSPPOSIXAwkSyntax.isRegexLiteral(value) {
            return String(value.dropFirst().dropLast())
        }
        return evaluateString(value)
    }
}
