import Foundation
import MSPShellLanguage

extension MSPParsedCommandLine {
    public func expanded(
        in context: MSPShellExpansionContext
    ) throws -> MSPParsedCommandLine {
        let expander = MSPShellWordExpander(context: context)
        return try MSPShellCommandLineExpansionCore(commandLine: self).expanded(using: expander)
    }

    public func expandedResolvingCommandSubstitutions(
        in context: MSPShellExpansionContext,
        resolver: @escaping @Sendable (String) async throws -> MSPShellCommandSubstitutionResult,
        processSubstitutionResolver: MSPShellProcessSubstitutionResolver? = nil
    ) async throws -> MSPShellCommandSubstitutionExpansion {
        var expander = MSPShellAsyncWordExpander(
            context: context,
            commandSubstitutionResolver: resolver,
            processSubstitutionResolver: processSubstitutionResolver
        )
        let commandLine = try await MSPShellCommandLineExpansionCore(commandLine: self)
            .expanded(using: &expander)
        return MSPShellCommandSubstitutionExpansion(
            commandLine: commandLine,
            stderr: expander.substitutionStderr,
            state: expander.context.expansionState
        )
    }
}

private struct MSPShellCommandLineExpansionCore {
    var commandLine: MSPParsedCommandLine

    func expanded(using expander: MSPShellWordExpander) throws -> MSPParsedCommandLine {
        let parts = try expandedCommonParts(using: expander)
        switch continuation(with: parts) {
        case .complete(let commandLine):
            return commandLine
        case .arithmetic(let parts, let expression):
            return commandLineAfterArithmeticExpansion(
                parts,
                expression: try expander.expandWordText(expression)
            )
        case .conditional(let parts, let words, let fallbackArguments):
            let expandedArguments = try expandedConditionalArguments(
                words,
                fallbackArguments: fallbackArguments,
                using: expander
            )
            return commandLineAfterConditionalExpansion(parts, arguments: expandedArguments)
        case .command(let parts, let words, let fallbackWords):
            let expandedWords = try expandedCommandWords(
                words,
                fallbackWords: fallbackWords,
                using: expander
            )
            return commandLineAfterWordExpansion(parts, expandedWords: expandedWords)
        }
    }

    func expanded(using expander: inout MSPShellAsyncWordExpander) async throws -> MSPParsedCommandLine {
        let parts = try await expandedCommonParts(using: &expander)
        switch continuation(with: parts) {
        case .complete(let commandLine):
            return commandLine
        case .arithmetic(let parts, let expression):
            return commandLineAfterArithmeticExpansion(
                parts,
                expression: try await expander.expandWordText(expression)
            )
        case .conditional(let parts, let words, let fallbackArguments):
            let expandedArguments = try await expandedConditionalArguments(
                words,
                fallbackArguments: fallbackArguments,
                using: &expander
            )
            return commandLineAfterConditionalExpansion(parts, arguments: expandedArguments)
        case .command(let parts, let words, let fallbackWords):
            let expandedWords = try await expandedCommandWords(
                words,
                fallbackWords: fallbackWords,
                using: &expander
            )
            return commandLineAfterWordExpansion(parts, expandedWords: expandedWords)
        }
    }

    private func expandedCommonParts(
        using expander: MSPShellWordExpander
    ) throws -> MSPShellCommandLineExpandedParts {
        let expandedAssignments = try commandLine.assignments.enumerated().map { index, assignment in
            let value = try commandLine.assignmentValueWords.indices.contains(index)
                ? expander.expandWordText(commandLine.assignmentValueWords[index])
                : assignment.value
            return MSPParsedAssignment(name: assignment.name, value: value)
        }
        let expandedArrayAssignments = try commandLine.arrayAssignments.enumerated().map { index, assignment in
            let values = try commandLine.arrayAssignmentValueWords.indices.contains(index)
                ? commandLine.arrayAssignmentValueWords[index].flatMap { try expander.expandWordVariants($0) }
                : assignment.values
            return MSPParsedArrayAssignment(
                name: assignment.name,
                values: values,
                append: assignment.append
            )
        }
        let expandedSubscriptAssignments = try commandLine.subscriptAssignments.enumerated().map { index, assignment in
            let key = try commandLine.subscriptAssignmentKeyWords.indices.contains(index)
                ? expander.expandWordText(commandLine.subscriptAssignmentKeyWords[index])
                : assignment.key
            let value = try commandLine.subscriptAssignmentValueWords.indices.contains(index)
                ? expander.expandWordText(commandLine.subscriptAssignmentValueWords[index])
                : assignment.value
            return MSPParsedSubscriptAssignment(
                name: assignment.name,
                key: key,
                value: value,
                append: assignment.append
            )
        }
        let expandedRedirections = try commandLine.redirections.enumerated().map { index, redirection in
            var updated = redirection
            if commandLine.redirectionTargetWords.indices.contains(index) {
                updated.target = try expander.expandWordText(commandLine.redirectionTargetWords[index])
            }
            return updated
        }

        return MSPShellCommandLineExpandedParts(
            assignments: expandedAssignments,
            arrayAssignments: expandedArrayAssignments,
            subscriptAssignments: expandedSubscriptAssignments,
            redirections: expandedRedirections
        )
    }

    private func expandedCommonParts(
        using expander: inout MSPShellAsyncWordExpander
    ) async throws -> MSPShellCommandLineExpandedParts {
        var expandedAssignments: [MSPParsedAssignment] = []
        for (index, assignment) in commandLine.assignments.enumerated() {
            let value = try await commandLine.assignmentValueWords.indices.contains(index)
                ? expander.expandWordText(commandLine.assignmentValueWords[index])
                : assignment.value
            expandedAssignments.append(MSPParsedAssignment(name: assignment.name, value: value))
        }

        var expandedArrayAssignments: [MSPParsedArrayAssignment] = []
        for (index, assignment) in commandLine.arrayAssignments.enumerated() {
            var values: [String] = []
            if commandLine.arrayAssignmentValueWords.indices.contains(index) {
                for valueWord in commandLine.arrayAssignmentValueWords[index] {
                    values.append(contentsOf: try await expander.expandWordVariants(valueWord))
                }
            } else {
                values = assignment.values
            }
            expandedArrayAssignments.append(MSPParsedArrayAssignment(
                name: assignment.name,
                values: values,
                append: assignment.append
            ))
        }

        var expandedSubscriptAssignments: [MSPParsedSubscriptAssignment] = []
        for (index, assignment) in commandLine.subscriptAssignments.enumerated() {
            let key = try await commandLine.subscriptAssignmentKeyWords.indices.contains(index)
                ? expander.expandWordText(commandLine.subscriptAssignmentKeyWords[index])
                : assignment.key
            let value = try await commandLine.subscriptAssignmentValueWords.indices.contains(index)
                ? expander.expandWordText(commandLine.subscriptAssignmentValueWords[index])
                : assignment.value
            expandedSubscriptAssignments.append(MSPParsedSubscriptAssignment(
                name: assignment.name,
                key: key,
                value: value,
                append: assignment.append
            ))
        }

        var expandedRedirections: [MSPParsedRedirection] = []
        for (index, redirection) in commandLine.redirections.enumerated() {
            var updated = redirection
            if commandLine.redirectionTargetWords.indices.contains(index) {
                updated.target = try await expander.expandWordText(commandLine.redirectionTargetWords[index])
            }
            expandedRedirections.append(updated)
        }

        return MSPShellCommandLineExpandedParts(
            assignments: expandedAssignments,
            arrayAssignments: expandedArrayAssignments,
            subscriptAssignments: expandedSubscriptAssignments,
            redirections: expandedRedirections
        )
    }

    private func continuation(
        with parts: MSPShellCommandLineExpandedParts
    ) -> MSPShellCommandLineExpansionContinuation {
        if commandLine.isAssignmentOnly || commandLine.compoundKind != nil {
            return .complete(commandLineApplying(parts))
        }

        if var functionDefinition = commandLine.functionDefinition {
            functionDefinition.redirections = parts.redirections
            var updated = commandLineApplying(parts)
            updated.functionDefinition = functionDefinition
            return .complete(updated)
        }

        if let arithmeticExpression = commandLine.arithmeticExpression {
            return .arithmetic(
                parts,
                MSPParsedWord(parts: [
                    .init(text: arithmeticExpression, isExpandable: true, isQuoted: false)
                ])
            )
        }

        if commandLine.commandName == "[[" {
            return .conditional(
                parts,
                commandLine.argumentWords,
                fallbackArguments: commandLine.arguments
            )
        }

        let parsedWords = [commandLine.commandNameWord].compactMap { $0 } + commandLine.argumentWords
        return .command(
            parts,
            parsedWords,
            fallbackWords: [commandLine.commandName] + commandLine.arguments
        )
    }

    private func expandedConditionalArguments(
        _ words: [MSPParsedWord],
        fallbackArguments: [String],
        using expander: MSPShellWordExpander
    ) throws -> [String] {
        guard !words.isEmpty else {
            return fallbackArguments
        }
        return try words.map { try expander.expandWordText($0) }
    }

    private func expandedConditionalArguments(
        _ words: [MSPParsedWord],
        fallbackArguments: [String],
        using expander: inout MSPShellAsyncWordExpander
    ) async throws -> [String] {
        guard !words.isEmpty else {
            return fallbackArguments
        }
        var expandedArguments: [String] = []
        for word in words {
            expandedArguments.append(try await expander.expandWordText(word))
        }
        return expandedArguments
    }

    private func expandedCommandWords(
        _ words: [MSPParsedWord],
        fallbackWords: [String],
        using expander: MSPShellWordExpander
    ) throws -> [String] {
        guard !words.isEmpty else {
            return fallbackWords
        }
        return try words.flatMap { try expander.expandWordVariants($0) }
    }

    private func expandedCommandWords(
        _ words: [MSPParsedWord],
        fallbackWords: [String],
        using expander: inout MSPShellAsyncWordExpander
    ) async throws -> [String] {
        guard !words.isEmpty else {
            return fallbackWords
        }
        var expandedWords: [String] = []
        for word in words {
            expandedWords.append(contentsOf: try await expander.expandWordVariants(word))
        }
        return expandedWords
    }

    private func commandLineAfterArithmeticExpansion(
        _ parts: MSPShellCommandLineExpandedParts,
        expression: String
    ) -> MSPParsedCommandLine {
        var updated = commandLineApplying(parts)
        updated.arithmeticExpression = expression
        updated.arguments = [updated.arithmeticExpression ?? "", "))"]
        return updated
    }

    private func commandLineAfterConditionalExpansion(
        _ parts: MSPShellCommandLineExpandedParts,
        arguments: [String]
    ) -> MSPParsedCommandLine {
        var updated = commandLineApplying(parts)
        updated.arguments = arguments
        return updated
    }

    private func commandLineAfterWordExpansion(
        _ parts: MSPShellCommandLineExpandedParts,
        expandedWords: [String]
    ) -> MSPParsedCommandLine {
        guard let expandedCommandName = expandedWords.first, !expandedCommandName.isEmpty else {
            var updated = commandLineApplying(parts)
            updated.commandName = ":"
            updated.arguments = []
            updated.isAssignmentOnly = !parts.assignments.isEmpty
                || !parts.arrayAssignments.isEmpty
                || !parts.subscriptAssignments.isEmpty
                || !parts.redirections.isEmpty
            return updated
        }

        var updated = commandLineApplying(parts)
        updated.commandName = expandedCommandName
        updated.arguments = Array(expandedWords.dropFirst())
        return updated
    }

    private func commandLineApplying(
        _ parts: MSPShellCommandLineExpandedParts
    ) -> MSPParsedCommandLine {
        var updated = commandLine
        updated.assignments = parts.assignments
        updated.arrayAssignments = parts.arrayAssignments
        updated.subscriptAssignments = parts.subscriptAssignments
        updated.redirections = parts.redirections
        return updated
    }
}

private struct MSPShellCommandLineExpandedParts {
    var assignments: [MSPParsedAssignment]
    var arrayAssignments: [MSPParsedArrayAssignment]
    var subscriptAssignments: [MSPParsedSubscriptAssignment]
    var redirections: [MSPParsedRedirection]
}

private enum MSPShellCommandLineExpansionContinuation {
    case complete(MSPParsedCommandLine)
    case arithmetic(MSPShellCommandLineExpandedParts, MSPParsedWord)
    case conditional(MSPShellCommandLineExpandedParts, [MSPParsedWord], fallbackArguments: [String])
    case command(MSPShellCommandLineExpandedParts, [MSPParsedWord], fallbackWords: [String])
}
