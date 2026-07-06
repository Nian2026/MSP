import Foundation

struct MSPPOSIXAwkRunResult {
    var stdout: String
    var fileOutputs: [MSPPOSIXAwkFileOutput]
}

struct MSPPOSIXAwkFileOutput {
    var path: String
    var append: Bool
    var text: String
}

extension MSPPOSIXAwkRunner {
    struct Block {
        enum Kind {
            case begin
            case record(String?)
            case end
        }

        var kind: Kind
        var body: String
    }

    struct UserFunction {
        var parameters: [String]
        var body: String
    }

    struct ReturnSignal: Error {
        var value: String
    }

    struct ExitSignal: Error {
    }

    struct OutputRedirection {
        var pathExpression: String
        var append: Bool
    }

    enum LValueNode {
        case variable(String)
        case field(Int)
        case arrayElement(name: String, keyExpression: ExpressionNode)

        var sourceText: String {
            switch self {
            case .variable(let name):
                return name
            case .field(let number):
                return "$\(number)"
            case .arrayElement(let name, let keyExpression):
                return "\(name)[\(keyExpression.sourceText)]"
            }
        }
    }

    indirect enum ExpressionNode {
        enum AssignmentOperator: Equatable {
            case assign
            case addAssign
            case subAssign
            case mulAssign
            case divAssign
            case modAssign
            case powAssign

            var sourceText: String {
                switch self {
                case .assign: return "="
                case .addAssign: return "+="
                case .subAssign: return "-="
                case .mulAssign: return "*="
                case .divAssign: return "/="
                case .modAssign: return "%="
                case .powAssign: return "^="
                }
            }
        }

        enum MutationOperator: Equatable {
            case preIncrement
            case preDecrement
            case postIncrement
            case postDecrement
        }

        enum BinaryOperator: String, Equatable {
            case add = "+"
            case subtract = "-"
            case multiply = "*"
            case divide = "/"
            case modulo = "%"
            case power = "^"
            case equal = "=="
            case notEqual = "!="
            case greaterThan = ">"
            case greaterThanOrEqual = ">="
            case lessThan = "<"
            case lessThanOrEqual = "<="
            case match = "~"
            case notMatch = "!~"
            case and = "&&"
            case or = "||"

            var precedence: Int {
                switch self {
                case .or:
                    return 1
                case .and:
                    return 2
                case .equal, .notEqual,
                     .greaterThan, .greaterThanOrEqual,
                     .lessThan, .lessThanOrEqual,
                     .match, .notMatch:
                    return 3
                case .add, .subtract:
                    return 4
                case .multiply, .divide, .modulo:
                    return 5
                case .power:
                    return 6
                }
            }

            var isRightAssociative: Bool {
                self == .power
            }
        }

        case assignment(target: LValueNode, operator: AssignmentOperator, value: ExpressionNode)
        case mutation(target: LValueNode, operator: MutationOperator)
        case binary(operator: BinaryOperator, left: ExpressionNode, right: ExpressionNode)
        case functionCall(name: String, arguments: [ExpressionNode])
        case fileGetline(target: LValueNode?, pathExpression: ExpressionNode)
        case pipeGetline(commandExpression: ExpressionNode, target: LValueNode?)
        case raw(String)

        var sourceText: String {
            switch self {
            case .assignment(let target, let operation, let value):
                return "\(target.sourceText) \(operation.sourceText) \(value.sourceText)"
            case .mutation(let target, let operation):
                switch operation {
                case .preIncrement:
                    return "++\(target.sourceText)"
                case .preDecrement:
                    return "--\(target.sourceText)"
                case .postIncrement:
                    return "\(target.sourceText)++"
                case .postDecrement:
                    return "\(target.sourceText)--"
                }
            case .binary(let operation, let left, let right):
                return "\(left.sourceText) \(operation.rawValue) \(right.sourceText)"
            case .functionCall(let name, let arguments):
                return "\(name)(\(arguments.map(\.sourceText).joined(separator: ", ")))"
            case .fileGetline(let target, let pathExpression):
                if let target {
                    return "getline \(target.sourceText) < \(pathExpression.sourceText)"
                }
                return "getline < \(pathExpression.sourceText)"
            case .pipeGetline(let commandExpression, let target):
                if let target {
                    return "\(commandExpression.sourceText) | getline \(target.sourceText)"
                }
                return "\(commandExpression.sourceText) | getline"
            case .raw(let expression):
                return expression
            }
        }
    }

    enum StatementNode {
        case print(expression: String?, redirection: OutputRedirection?)
        case printf(expression: String, redirection: OutputRedirection?)
        case delete(target: String)
        case returnStatement(expression: String?)
        case exitStatement
        case ifStatement(condition: String, thenBody: String, elseBody: String?)
        case forStatement(header: String, body: String)
        case whileLoop(condition: String, body: String)
        case expression(ExpressionNode)
    }
}
