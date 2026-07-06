import Foundation

public struct MSPParsedShellScript: Sendable, Equatable {
    public var rawInput: String
    public var pipelineCount: Int
    public var commandNodeCount: Int
    public var isSingleSimpleCommand: Bool

    public init(
        rawInput: String,
        pipelineCount: Int,
        commandNodeCount: Int,
        isSingleSimpleCommand: Bool
    ) {
        self.rawInput = rawInput
        self.pipelineCount = pipelineCount
        self.commandNodeCount = commandNodeCount
        self.isSingleSimpleCommand = isSingleSimpleCommand
    }
}

public enum MSPParsedCompoundKind: Sendable, Equatable {
    case group
    case subshell
    case ifThen
    case whileLoop
    case untilLoop
    case whileRead
    case forEach
    case cStyleFor
    case caseOf
}

public struct MSPParsedCommandList: Sendable, Equatable {
    public var pipelines: [MSPParsedCommandPipeline]
    public var rawInput: String

    public init(
        pipelines: [MSPParsedCommandPipeline] = [],
        rawInput: String = ""
    ) {
        self.pipelines = pipelines
        self.rawInput = rawInput
    }
}

public struct MSPParsedIfBranch: Sendable, Equatable {
    public var condition: String
    public var body: String

    public init(condition: String, body: String) {
        self.condition = condition
        self.body = body
    }
}

public struct MSPParsedStructuredIfBranch: Sendable, Equatable {
    public var condition: MSPParsedCommandList
    public var body: MSPParsedCommandList

    public init(condition: MSPParsedCommandList, body: MSPParsedCommandList) {
        self.condition = condition
        self.body = body
    }
}

public struct MSPParsedReadSpec: Sendable, Equatable {
    public var assignments: [MSPParsedAssignment]
    public var assignmentValueWords: [MSPParsedWord]
    public var names: [String]
    public var delimiter: String?

    public init(
        assignments: [MSPParsedAssignment],
        assignmentValueWords: [MSPParsedWord],
        names: [String],
        delimiter: String? = nil
    ) {
        self.assignments = assignments
        self.assignmentValueWords = assignmentValueWords
        self.names = names
        self.delimiter = delimiter
    }
}

public enum MSPParsedForValues: Sendable, Equatable {
    case explicit([MSPParsedWord])
    case positionalParameters
}

public struct MSPParsedCStyleForHeader: Sendable, Equatable {
    public var initExpression: String
    public var conditionExpression: String
    public var updateExpression: String

    public init(initExpression: String, conditionExpression: String, updateExpression: String) {
        self.initExpression = initExpression
        self.conditionExpression = conditionExpression
        self.updateExpression = updateExpression
    }
}

public enum MSPParsedCaseTerminator: Sendable, Equatable {
    case breakArm
    case fallThrough
    case continueMatching
}

public struct MSPParsedCaseArm: Sendable, Equatable {
    public var patterns: [MSPParsedWord]
    public var body: String
    public var terminator: MSPParsedCaseTerminator

    public init(patterns: [MSPParsedWord], body: String, terminator: MSPParsedCaseTerminator) {
        self.patterns = patterns
        self.body = body
        self.terminator = terminator
    }
}

public struct MSPParsedStructuredCaseArm: Sendable, Equatable {
    public var patterns: [MSPParsedWord]
    public var body: MSPParsedCommandList
    public var terminator: MSPParsedCaseTerminator

    public init(patterns: [MSPParsedWord], body: MSPParsedCommandList, terminator: MSPParsedCaseTerminator) {
        self.patterns = patterns
        self.body = body
        self.terminator = terminator
    }
}

public enum MSPParsedCompoundCommand: Sendable, Equatable {
    case group(body: String)
    case subshell(body: String)
    case ifThen(branches: [MSPParsedIfBranch], elseBody: String)
    case whileLoop(condition: String, body: String)
    case untilLoop(condition: String, body: String)
    case whileRead(spec: MSPParsedReadSpec, body: String)
    case forEach(variable: String, values: MSPParsedForValues, body: String)
    case cStyleFor(header: MSPParsedCStyleForHeader, body: String)
    case caseOf(subject: MSPParsedWord, arms: [MSPParsedCaseArm])
}

public indirect enum MSPParsedStructuredCompoundCommand: Sendable, Equatable {
    case group(body: MSPParsedCommandList)
    case subshell(body: MSPParsedCommandList)
    case ifThen(branches: [MSPParsedStructuredIfBranch], elseBody: MSPParsedCommandList)
    case whileLoop(condition: MSPParsedCommandList, body: MSPParsedCommandList)
    case untilLoop(condition: MSPParsedCommandList, body: MSPParsedCommandList)
    case whileRead(spec: MSPParsedReadSpec, body: MSPParsedCommandList)
    case forEach(variable: String, values: MSPParsedForValues, body: MSPParsedCommandList)
    case cStyleFor(header: MSPParsedCStyleForHeader, body: MSPParsedCommandList)
    case caseOf(subject: MSPParsedWord, arms: [MSPParsedStructuredCaseArm])
}

public enum MSPParsedFunctionBodyKind: Sendable, Equatable {
    case braceGroup
    case subshell
}

public struct MSPParsedFunctionDefinition: Sendable, Equatable {
    public var name: String
    public var bodyKind: MSPParsedFunctionBodyKind
    public var body: String
    public var structuredBody: MSPParsedCommandList?
    public var redirections: [MSPParsedRedirection]
    public var redirectionTargetWords: [MSPParsedWord]

    public init(
        name: String,
        bodyKind: MSPParsedFunctionBodyKind,
        body: String,
        structuredBody: MSPParsedCommandList? = nil,
        redirections: [MSPParsedRedirection] = [],
        redirectionTargetWords: [MSPParsedWord] = []
    ) {
        self.name = name
        self.bodyKind = bodyKind
        self.body = body
        self.structuredBody = structuredBody
        self.redirections = redirections
        self.redirectionTargetWords = redirectionTargetWords
    }
}

public struct MSPParsedCommandLine: Sendable, Equatable {
    public var commandName: String
    public var arguments: [String]
    public var assignments: [MSPParsedAssignment]
    public var arrayAssignments: [MSPParsedArrayAssignment]
    public var subscriptAssignments: [MSPParsedSubscriptAssignment]
    public var redirections: [MSPParsedRedirection]
    public var isAssignmentOnly: Bool
    public var rawInput: String
    public var commandNameWord: MSPParsedWord?
    public var argumentWords: [MSPParsedWord]
    public var assignmentValueWords: [MSPParsedWord]
    public var arrayAssignmentValueWords: [[MSPParsedWord]]
    public var subscriptAssignmentKeyWords: [MSPParsedWord]
    public var subscriptAssignmentValueWords: [MSPParsedWord]
    public var redirectionTargetWords: [MSPParsedWord]
    public var arithmeticExpression: String?
    public var compoundKind: MSPParsedCompoundKind?
    public var compoundBody: String?
    public var compoundCommand: MSPParsedCompoundCommand?
    public var structuredCompoundCommand: MSPParsedStructuredCompoundCommand?
    public var functionDefinition: MSPParsedFunctionDefinition?

    public init(
        commandName: String,
        arguments: [String],
        assignments: [MSPParsedAssignment] = [],
        arrayAssignments: [MSPParsedArrayAssignment] = [],
        subscriptAssignments: [MSPParsedSubscriptAssignment] = [],
        redirections: [MSPParsedRedirection] = [],
        isAssignmentOnly: Bool = false,
        rawInput: String,
        commandNameWord: MSPParsedWord? = nil,
        argumentWords: [MSPParsedWord] = [],
        assignmentValueWords: [MSPParsedWord] = [],
        arrayAssignmentValueWords: [[MSPParsedWord]] = [],
        subscriptAssignmentKeyWords: [MSPParsedWord] = [],
        subscriptAssignmentValueWords: [MSPParsedWord] = [],
        redirectionTargetWords: [MSPParsedWord] = [],
        arithmeticExpression: String? = nil,
        compoundKind: MSPParsedCompoundKind? = nil,
        compoundBody: String? = nil,
        compoundCommand: MSPParsedCompoundCommand? = nil,
        structuredCompoundCommand: MSPParsedStructuredCompoundCommand? = nil,
        functionDefinition: MSPParsedFunctionDefinition? = nil
    ) {
        self.commandName = commandName
        self.arguments = arguments
        self.assignments = assignments
        self.arrayAssignments = arrayAssignments
        self.subscriptAssignments = subscriptAssignments
        self.redirections = redirections
        self.isAssignmentOnly = isAssignmentOnly
        self.rawInput = rawInput
        self.commandNameWord = commandNameWord
        self.argumentWords = argumentWords
        self.assignmentValueWords = assignmentValueWords
        self.arrayAssignmentValueWords = arrayAssignmentValueWords
        self.subscriptAssignmentKeyWords = subscriptAssignmentKeyWords
        self.subscriptAssignmentValueWords = subscriptAssignmentValueWords
        self.redirectionTargetWords = redirectionTargetWords
        self.arithmeticExpression = arithmeticExpression
        self.compoundKind = compoundKind
        self.compoundBody = compoundBody
        self.compoundCommand = compoundCommand
        self.structuredCompoundCommand = structuredCompoundCommand
        self.functionDefinition = functionDefinition
    }
}

public struct MSPParsedAssignment: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MSPParsedArrayAssignment: Sendable, Equatable {
    public var name: String
    public var values: [String]
    public var append: Bool

    public init(name: String, values: [String], append: Bool = false) {
        self.name = name
        self.values = values
        self.append = append
    }
}

public struct MSPParsedSubscriptAssignment: Sendable, Equatable {
    public var name: String
    public var key: String
    public var value: String
    public var append: Bool

    public init(name: String, key: String, value: String, append: Bool = false) {
        self.name = name
        self.key = key
        self.value = value
        self.append = append
    }
}

package func mspShellDecodedArrayAssignmentArgument(
    _ argument: String
) -> MSPParsedArrayAssignment? {
    let pieces = argument.components(separatedBy: mspShellArrayAssignmentFieldSeparator)
    guard pieces.count >= 3,
          pieces[0] == mspShellArrayAssignmentArgumentPrefix,
          mspShellVariableName(pieces[2]) else {
        return nil
    }
    return MSPParsedArrayAssignment(
        name: pieces[2],
        values: Array(pieces.dropFirst(3)),
        append: pieces[1] == "1"
    )
}

public enum MSPParsedRedirectionOperator: Sendable, Equatable {
    case input
    case output
    case appendOutput
    case outputBoth
    case appendOutputBoth
    case duplicateOutput
    case duplicateInput
    case readWrite
    case hereDocument
    case hereString
    case unsupported(String)
}

public struct MSPParsedRedirection: Sendable, Equatable {
    public var fd: Int?
    public var operation: MSPParsedRedirectionOperator
    public var target: String
    public var hereDocumentBody: String?

    public init(
        fd: Int?,
        operation: MSPParsedRedirectionOperator,
        target: String,
        hereDocumentBody: String? = nil
    ) {
        self.fd = fd
        self.operation = operation
        self.target = target
        self.hereDocumentBody = hereDocumentBody
    }
}

public enum MSPParsedPipeOperator: Sendable, Equatable {
    case stdout
    case stdoutAndStderr
}

public enum MSPParsedListOperator: Sendable, Equatable {
    case semicolon
    case and
    case or
}

public struct MSPParsedCommandPipeline: Sendable, Equatable {
    public var leadingOperator: MSPParsedListOperator?
    public var isNegated: Bool
    public var commands: [MSPParsedCommandLine]
    public var pipeOperators: [MSPParsedPipeOperator]
    public var rawInput: String

    public init(
        leadingOperator: MSPParsedListOperator? = nil,
        isNegated: Bool = false,
        commands: [MSPParsedCommandLine],
        pipeOperators: [MSPParsedPipeOperator],
        rawInput: String
    ) {
        self.leadingOperator = leadingOperator
        self.isNegated = isNegated
        self.commands = commands
        self.pipeOperators = pipeOperators
        self.rawInput = rawInput
    }
}
