import Foundation

enum MSPShellParsedCommandConversionError: Error, Sendable, Equatable {
    case emptyInput
}

enum MSPShellASTToParsedConversion {
    static func parsedShellScript(
        from script: ShellScript,
        rawInput: String
    ) -> MSPParsedShellScript {
        MSPParsedShellScript(
            rawInput: rawInput,
            pipelineCount: script.body.pipelines.count,
            commandNodeCount: script.body.pipelines.reduce(0) { count, pipeline in
                count + pipeline.commands.count
            },
            isSingleSimpleCommand: singleSimpleCommand(in: script) != nil
        )
    }

    static func parsedCommandPipelines(
        from script: ShellScript
    ) throws -> [MSPParsedCommandPipeline] {
        try parsedCommandList(from: script.body).pipelines
    }

    private static func parsedCommandList(
        from commandList: ShellCommandList
    ) throws -> MSPParsedCommandList {
        let pipelines = try commandList.entries.map { entry in
            var parsed = try parsedCommandPipeline(from: entry.pipeline)
            parsed.leadingOperator = parsedListOperator(from: entry.leadingOperator)
            return parsed
        }
        return MSPParsedCommandList(
            pipelines: pipelines,
            rawInput: try MSPShellRawReconstruction.commandListRawInput(commandList)
        )
    }

    private static func parsedCommandPipeline(
        from pipeline: ShellPipeline
    ) throws -> MSPParsedCommandPipeline {
        let commands = try pipeline.commands.map { node in
            switch node.stage {
            case .command(let command):
                return try parsedCommandLine(
                    from: command,
                    rawInput: MSPShellRawReconstruction.rawInput(for: command)
                )
            case .assignmentList(let assignments, let arrays, let redirections):
                return try parsedAssignmentOnlyCommandLine(
                    assignments: assignments,
                    arrays: arrays,
                    redirections: redirections
                )
            case .arrayAssignment(let name, let values, let append):
                return try parsedArrayAssignmentCommandLine(
                    name: name,
                    values: values,
                    append: append
                )
            case .subscriptAssignment(let name, let key, let value, let append):
                return try parsedSubscriptAssignmentCommandLine(
                    name: name,
                    key: key,
                    value: value,
                    append: append
                )
            case .arithmeticCommand(let expression, let redirections):
                return try parsedArithmeticCommandLine(
                    expression: expression,
                    redirections: redirections
                )
            case .compound(.conditional(let words, let redirections)):
                return try parsedConditionalCommandLine(words: words, redirections: redirections)
            case .compound(.ifThen(let branches, let elseBody, let redirections)):
                return try parsedIfCommandLine(branches: branches, elseBody: elseBody, redirections: redirections)
            case .compound(.whileLoop(let condition, let body, let redirections)):
                return try parsedConditionalLoopCommandLine(
                    kind: .whileLoop,
                    commandName: "while",
                    condition: condition,
                    body: body,
                    redirections: redirections
                )
            case .compound(.untilLoop(let condition, let body, let redirections)):
                return try parsedConditionalLoopCommandLine(
                    kind: .untilLoop,
                    commandName: "until",
                    condition: condition,
                    body: body,
                    redirections: redirections
                )
            case .compound(.whileRead(let spec, let body, let redirections)):
                return try parsedWhileReadCommandLine(spec: spec, body: body, redirections: redirections)
            case .compound(.forEach(let variable, let values, let body, let redirections)):
                return try parsedForEachCommandLine(
                    variable: variable,
                    values: values,
                    body: body,
                    redirections: redirections
                )
            case .compound(.cStyleFor(let initExpression, let conditionExpression, let updateExpression, let body, let redirections)):
                return try parsedCStyleForCommandLine(
                    initExpression: initExpression,
                    conditionExpression: conditionExpression,
                    updateExpression: updateExpression,
                    body: body,
                    redirections: redirections
                )
            case .compound(.caseOf(let subject, let arms, let redirections)):
                return try parsedCaseCommandLine(subject: subject, arms: arms, redirections: redirections)
            case .compound(.group(let body, let redirections)):
                return try parsedCompoundCommandLine(kind: .group, body: body, redirections: redirections)
            case .compound(.subshell(let body, let redirections)):
                return try parsedCompoundCommandLine(kind: .subshell, body: body, redirections: redirections)
            case .functionDefinition(let definition):
                return try parsedFunctionDefinitionCommandLine(definition)
            }
        }
        let operators = pipeline.pipeOperators.map { pipeOperator in
            switch pipeOperator {
            case .stdout:
                return MSPParsedPipeOperator.stdout
            case .stdoutAndStderr:
                return MSPParsedPipeOperator.stdoutAndStderr
            }
        }
        return MSPParsedCommandPipeline(
            leadingOperator: nil,
            isNegated: pipeline.negated,
            commands: commands,
            pipeOperators: operators,
            rawInput: MSPShellRawReconstruction.rawInput(commands: commands, pipeOperators: operators)
        )
    }

    private static func parsedCommandLine(
        from command: ShellSimpleCommand,
        rawInput: String
    ) throws -> MSPParsedCommandLine {
        let assignments = command.assignments.map(parsedAssignment(from:))
        guard let commandName = command.commandName?.rawText, !commandName.isEmpty else {
            if !command.redirections.isEmpty || !assignments.isEmpty {
                return MSPParsedCommandLine(
                    commandName: ":",
                    arguments: [],
                    assignments: assignments,
                    redirections: try command.redirections.map(parsedRedirection(from:)),
                    isAssignmentOnly: true,
                    rawInput: rawInput,
                    assignmentValueWords: command.assignments.map { MSPParsedWord(shellWord: $0.value) },
                    redirectionTargetWords: command.redirections.map { MSPParsedWord(shellWord: $0.target) }
                )
            }
            throw MSPShellParsedCommandConversionError.emptyInput
        }
        let redirections = try command.redirections.map(parsedRedirection(from:))
        return MSPParsedCommandLine(
            commandName: commandName,
            arguments: command.arguments.map(\.rawText),
            assignments: assignments,
            redirections: redirections,
            rawInput: rawInput,
            commandNameWord: MSPParsedWord(shellWord: command.commandName!),
            argumentWords: command.arguments.map(MSPParsedWord.init(shellWord:)),
            assignmentValueWords: command.assignments.map { MSPParsedWord(shellWord: $0.value) },
            redirectionTargetWords: command.redirections.map { MSPParsedWord(shellWord: $0.target) }
        )
    }

    private static func parsedAssignmentOnlyCommandLine(
        assignments: [ShellAssignmentClause],
        arrays: [ShellArrayAssignmentClause],
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let parsedAssignments = assignments.map(parsedAssignment(from:))
        let parsedArrayAssignments = arrays.map(parsedArrayAssignment(from:))
        return MSPParsedCommandLine(
            commandName: ":",
            arguments: [],
            assignments: parsedAssignments,
            arrayAssignments: parsedArrayAssignments,
            redirections: try redirections.map(parsedRedirection(from:)),
            isAssignmentOnly: true,
            rawInput: MSPShellRawReconstruction.assignmentOnlyRawInput(
                assignments: parsedAssignments,
                arrayAssignments: parsedArrayAssignments
            ),
            assignmentValueWords: assignments.map { MSPParsedWord(shellWord: $0.value) },
            arrayAssignmentValueWords: arrays.map { array in
                array.values.map(MSPParsedWord.init(shellWord:))
            },
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) }
        )
    }

    private static func parsedArrayAssignmentCommandLine(
        name: String,
        values: [ShellWord],
        append: Bool
    ) throws -> MSPParsedCommandLine {
        let parsedArrayAssignment = MSPParsedArrayAssignment(
            name: name,
            values: values.map(\.rawText),
            append: append
        )
        return MSPParsedCommandLine(
            commandName: ":",
            arguments: [],
            arrayAssignments: [parsedArrayAssignment],
            isAssignmentOnly: true,
            rawInput: MSPShellRawReconstruction.assignmentOnlyRawInput(
                assignments: [],
                arrayAssignments: [parsedArrayAssignment]
            ),
            arrayAssignmentValueWords: [values.map(MSPParsedWord.init(shellWord:))]
        )
    }

    private static func parsedSubscriptAssignmentCommandLine(
        name: String,
        key: ShellWord,
        value: ShellWord,
        append: Bool
    ) throws -> MSPParsedCommandLine {
        let parsedSubscriptAssignment = MSPParsedSubscriptAssignment(
            name: name,
            key: key.rawText,
            value: value.rawText,
            append: append
        )
        return MSPParsedCommandLine(
            commandName: ":",
            arguments: [],
            subscriptAssignments: [parsedSubscriptAssignment],
            isAssignmentOnly: true,
            rawInput: MSPShellRawReconstruction.subscriptAssignmentRawInput(
                assignment: parsedSubscriptAssignment
            ),
            subscriptAssignmentKeyWords: [MSPParsedWord(shellWord: key)],
            subscriptAssignmentValueWords: [MSPParsedWord(shellWord: value)]
        )
    }

    private static func parsedConditionalCommandLine(
        words: [ShellWord],
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let arguments = words.map(\.rawText) + ["]]"]
        return MSPParsedCommandLine(
            commandName: "[[",
            arguments: arguments,
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.conditionalRawInput(words: words),
            argumentWords: words.map(MSPParsedWord.init(shellWord:))
                + [MSPParsedWord(parts: [.init(text: "]]", isExpandable: false, isQuoted: false)])],
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) }
        )
    }

    private static func parsedArithmeticCommandLine(
        expression: String,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        MSPParsedCommandLine(
            commandName: "((",
            arguments: [expression, "))"],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: "(( \(expression) ))",
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            arithmeticExpression: expression
        )
    }

    private static func parsedCompoundCommandLine(
        kind: MSPParsedCompoundKind,
        body: ShellCommandList,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredBody = try parsedCommandList(from: body)
        let bodySource = structuredBody.rawInput
        return MSPParsedCommandLine(
            commandName: kind == .group ? "{" : "(",
            arguments: [bodySource, kind == .group ? "}" : ")"],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: kind == .group ? "{ \(bodySource); }" : "( \(bodySource) )",
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: kind,
            compoundBody: bodySource,
            compoundCommand: kind == .group ? .group(body: bodySource) : .subshell(body: bodySource),
            structuredCompoundCommand: kind == .group
                ? .group(body: structuredBody)
                : .subshell(body: structuredBody)
        )
    }

    private static func parsedIfCommandLine(
        branches: [ShellIfBranch],
        elseBody: ShellCommandList,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredBranches = try branches.map {
            MSPParsedStructuredIfBranch(
                condition: try parsedCommandList(from: $0.condition),
                body: try parsedCommandList(from: $0.body)
            )
        }
        let parsedBranches = try branches.map {
            MSPParsedIfBranch(
                condition: try MSPShellRawReconstruction.commandListRawInput($0.condition),
                body: try MSPShellRawReconstruction.commandListRawInput($0.body)
            )
        }
        let structuredElseBody = try parsedCommandList(from: elseBody)
        let parsedElseBody = structuredElseBody.rawInput
        return MSPParsedCommandLine(
            commandName: "if",
            arguments: [],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.appendRedirections(
                redirections,
                to: MSPShellRawReconstruction.ifRawInput(branches: parsedBranches, elseBody: parsedElseBody)
            ),
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: .ifThen,
            compoundCommand: .ifThen(branches: parsedBranches, elseBody: parsedElseBody),
            structuredCompoundCommand: .ifThen(
                branches: structuredBranches,
                elseBody: structuredElseBody
            )
        )
    }

    private static func parsedConditionalLoopCommandLine(
        kind: MSPParsedCompoundKind,
        commandName: String,
        condition: ShellCommandList,
        body: ShellCommandList,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredCondition = try parsedCommandList(from: condition)
        let structuredBody = try parsedCommandList(from: body)
        let conditionSource = structuredCondition.rawInput
        let bodySource = structuredBody.rawInput
        let compoundCommand: MSPParsedCompoundCommand = kind == .whileLoop
            ? .whileLoop(condition: conditionSource, body: bodySource)
            : .untilLoop(condition: conditionSource, body: bodySource)
        let structuredCompoundCommand: MSPParsedStructuredCompoundCommand = kind == .whileLoop
            ? .whileLoop(condition: structuredCondition, body: structuredBody)
            : .untilLoop(condition: structuredCondition, body: structuredBody)
        return MSPParsedCommandLine(
            commandName: commandName,
            arguments: [],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.appendRedirections(
                redirections,
                to: "\(commandName) \(conditionSource); do \(bodySource); done"
            ),
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: kind,
            compoundBody: bodySource,
            compoundCommand: compoundCommand,
            structuredCompoundCommand: structuredCompoundCommand
        )
    }

    private static func parsedWhileReadCommandLine(
        spec: ShellReadSpec,
        body: ShellCommandList,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredBody = try parsedCommandList(from: body)
        let bodySource = structuredBody.rawInput
        let parsedSpec = MSPParsedReadSpec(
            assignments: spec.assignments.map(parsedAssignment(from:)),
            assignmentValueWords: spec.assignments.map { MSPParsedWord(shellWord: $0.value) },
            names: spec.names,
            delimiter: spec.delimiter
        )
        return MSPParsedCommandLine(
            commandName: "while",
            arguments: [],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.appendRedirections(
                redirections,
                to: MSPShellRawReconstruction.whileReadRawInput(spec: spec, body: bodySource)
            ),
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: .whileRead,
            compoundBody: bodySource,
            compoundCommand: .whileRead(spec: parsedSpec, body: bodySource),
            structuredCompoundCommand: .whileRead(spec: parsedSpec, body: structuredBody)
        )
    }

    private static func parsedForEachCommandLine(
        variable: String,
        values: ShellForValues,
        body: ShellCommandList,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredBody = try parsedCommandList(from: body)
        let bodySource = structuredBody.rawInput
        let parsedValues: MSPParsedForValues
        let valueSource: String
        switch values {
        case .explicit(let words):
            parsedValues = .explicit(words.map(MSPParsedWord.init(shellWord:)))
            valueSource = " in " + words.map(MSPShellRawReconstruction.wordRawInput).joined(separator: " ")
        case .positionalParameters:
            parsedValues = .positionalParameters
            valueSource = ""
        }
        return MSPParsedCommandLine(
            commandName: "for",
            arguments: [],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.appendRedirections(
                redirections,
                to: "for \(variable)\(valueSource); do \(bodySource); done"
            ),
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: .forEach,
            compoundBody: bodySource,
            compoundCommand: .forEach(variable: variable, values: parsedValues, body: bodySource),
            structuredCompoundCommand: .forEach(variable: variable, values: parsedValues, body: structuredBody)
        )
    }

    private static func parsedCStyleForCommandLine(
        initExpression: String,
        conditionExpression: String,
        updateExpression: String,
        body: ShellCommandList,
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredBody = try parsedCommandList(from: body)
        let bodySource = structuredBody.rawInput
        let header = MSPParsedCStyleForHeader(
            initExpression: initExpression,
            conditionExpression: conditionExpression,
            updateExpression: updateExpression
        )
        return MSPParsedCommandLine(
            commandName: "for",
            arguments: [],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.appendRedirections(
                redirections,
                to: "for (( \(initExpression); \(conditionExpression); \(updateExpression) )); do \(bodySource); done"
            ),
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: .cStyleFor,
            compoundBody: bodySource,
            compoundCommand: .cStyleFor(header: header, body: bodySource),
            structuredCompoundCommand: .cStyleFor(header: header, body: structuredBody)
        )
    }

    private static func parsedCaseCommandLine(
        subject: ShellWord,
        arms: [ShellCaseArm],
        redirections: [ShellRedirectionClause]
    ) throws -> MSPParsedCommandLine {
        let structuredArms = try arms.map { arm in
            MSPParsedStructuredCaseArm(
                patterns: arm.patterns.map(MSPParsedWord.init(shellWord:)),
                body: try parsedCommandList(from: arm.body),
                terminator: parsedCaseTerminator(from: arm.terminator)
            )
        }
        let parsedArms = try arms.map { arm in
            MSPParsedCaseArm(
                patterns: arm.patterns.map(MSPParsedWord.init(shellWord:)),
                body: try MSPShellRawReconstruction.commandListRawInput(arm.body),
                terminator: parsedCaseTerminator(from: arm.terminator)
            )
        }
        return MSPParsedCommandLine(
            commandName: "case",
            arguments: [],
            redirections: try redirections.map(parsedRedirection(from:)),
            rawInput: MSPShellRawReconstruction.appendRedirections(
                redirections,
                to: try MSPShellRawReconstruction.caseRawInput(subject: subject, arms: arms)
            ),
            redirectionTargetWords: redirections.map { MSPParsedWord(shellWord: $0.target) },
            compoundKind: .caseOf,
            compoundCommand: .caseOf(subject: MSPParsedWord(shellWord: subject), arms: parsedArms),
            structuredCompoundCommand: .caseOf(
                subject: MSPParsedWord(shellWord: subject),
                arms: structuredArms
            )
        )
    }

    private static func parsedFunctionDefinitionCommandLine(
        _ definition: ShellFunctionDefinition
    ) throws -> MSPParsedCommandLine {
        let bodyKind: MSPParsedFunctionBodyKind
        let bodySource: String
        switch definition.body {
        case .braceGroup(let body):
            bodyKind = .braceGroup
            bodySource = try MSPShellRawReconstruction.commandListRawInput(body)
        case .subshell(let body):
            bodyKind = .subshell
            bodySource = try MSPShellRawReconstruction.commandListRawInput(body)
        }
        let structuredBody = try parsedCommandList(from: definition.body.innerCommandList)
        let redirections = try definition.redirections.map(parsedRedirection(from:))
        let parsedDefinition = MSPParsedFunctionDefinition(
            name: definition.name,
            bodyKind: bodyKind,
            body: bodySource,
            structuredBody: structuredBody,
            redirections: redirections,
            redirectionTargetWords: definition.redirections.map { MSPParsedWord(shellWord: $0.target) }
        )
        return MSPParsedCommandLine(
            commandName: "function",
            arguments: [definition.name],
            redirections: redirections,
            rawInput: MSPShellRawReconstruction.functionDefinitionRawInput(definition, body: bodySource),
            redirectionTargetWords: definition.redirections.map { MSPParsedWord(shellWord: $0.target) },
            functionDefinition: parsedDefinition
        )
    }

    private static func parsedListOperator(from operator: ShellListOperator?) -> MSPParsedListOperator? {
        switch `operator` {
        case nil:
            return nil
        case .semicolon?:
            return .semicolon
        case .and?:
            return .and
        case .or?:
            return .or
        }
    }

    private static func parsedAssignment(from assignment: ShellAssignmentClause) -> MSPParsedAssignment {
        MSPParsedAssignment(name: assignment.name, value: assignment.value.rawText)
    }

    private static func parsedArrayAssignment(from assignment: ShellArrayAssignmentClause) -> MSPParsedArrayAssignment {
        MSPParsedArrayAssignment(
            name: assignment.name,
            values: assignment.values.map(\.rawText),
            append: assignment.append
        )
    }

    private static func parsedRedirection(from redirection: ShellRedirectionClause) throws -> MSPParsedRedirection {
        let operation: MSPParsedRedirectionOperator
        var hereDocumentBody: String?
        switch redirection.operation {
        case .input:
            operation = .input
        case .output, .clobberOutput:
            operation = .output
        case .appendOutput:
            operation = .appendOutput
        case .outputBoth:
            operation = .outputBoth
        case .appendOutputBoth:
            operation = .appendOutputBoth
        case .hereString:
            operation = .hereString
        case .hereDocument, .hereDocumentStripTabs:
            operation = .hereDocument
            hereDocumentBody = try redirection.hereDocument()?.body
        case .duplicateOutput:
            operation = .duplicateOutput
        case .duplicateInput:
            operation = .duplicateInput
        case .readWrite:
            operation = .readWrite
        }
        return MSPParsedRedirection(
            fd: redirection.fd,
            operation: operation,
            target: redirection.target.rawText,
            hereDocumentBody: hereDocumentBody
        )
    }

    private static func parsedCaseTerminator(from terminator: ShellCaseTerminator) -> MSPParsedCaseTerminator {
        switch terminator {
        case .breakArm:
            return .breakArm
        case .fallThrough:
            return .fallThrough
        case .continueMatching:
            return .continueMatching
        }
    }

    private static func singleSimpleCommand(in script: ShellScript) -> ShellSimpleCommand? {
        guard script.body.rest.isEmpty,
              let pipeline = script.body.first,
              !pipeline.negated,
              pipeline.commands.count == 1,
              pipeline.pipeOperators.isEmpty,
              let node = pipeline.commands.first,
              case .command(let command) = node.stage else {
            return nil
        }
        return command
    }
}
