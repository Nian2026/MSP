import Foundation
import MSPShellLanguage

struct MSPShellAsyncWordExpander {
    var context: MSPShellExpansionContext
    private var effectAdapter: MSPShellAsyncExpansionEffectAdapter

    init(
        context: MSPShellExpansionContext,
        commandSubstitutionResolver: @escaping @Sendable (String) async throws -> MSPShellCommandSubstitutionResult,
        processSubstitutionResolver: MSPShellProcessSubstitutionResolver? = nil
    ) {
        self.context = context
        self.effectAdapter = MSPShellAsyncExpansionEffectAdapter(
            commandSubstitutionResolver: commandSubstitutionResolver,
            processSubstitutionResolver: processSubstitutionResolver
        )
    }

    private var core: MSPShellWordExpansionCore {
        MSPShellWordExpansionCore(context: context)
    }

    private var textCore: MSPShellTextExpansionCore {
        MSPShellTextExpansionCore(commandSubstitutions: .recognize)
    }

    var substitutionStderr: String {
        effectAdapter.stderr
    }

    mutating func expandWordText(_ word: MSPParsedWord) async throws -> String {
        var result = ""
        for part in word.parts {
            let text = part.isExpandable
                ? try await expandText(part.text)
                : part.text
            result += text
        }
        return result
    }

    mutating func expandWordVariants(_ word: MSPParsedWord) async throws -> [String] {
        if context.enablesBraceExpansion,
           let expandedWords = mspShellBraceExpandedWords(word),
           expandedWords.count != 1 || expandedWords.first != word {
            var output: [String] = []
            for expandedWord in expandedWords {
                output.append(contentsOf: try await expandWordVariantsWithoutBraceExpansion(expandedWord))
            }
            return output
        }
        return try await expandWordVariantsWithoutBraceExpansion(word)
    }

    private mutating func expandWordVariantsWithoutBraceExpansion(_ word: MSPParsedWord) async throws -> [String] {
        var fields = core.initialFields(for: word)

        for part in word.parts {
            if part.isQuoted, part.isExpandable {
                fields = try await appendQuotedExpansion(part.text, to: fields)
            } else if part.isExpandable {
                fields = core.appendExpandedWordPart(
                    part,
                    expandedText: try await expandText(part.text),
                    to: fields
                )
            } else {
                fields = core.appendLiteralWordPart(part, to: fields)
            }
        }

        return try core.finishFields(fields)
    }

    private mutating func appendQuotedExpansion(
        _ text: String,
        to fields: [MSPShellExpandedField]
    ) async throws -> [MSPShellExpandedField] {
        var output = fields
        for segment in mspShellExpansionSegmentsPreservingQuotedPositionalParameters(in: text) {
            switch segment {
            case .text(let rawText):
                let expanded = try await expandText(rawText)
                output = core.appendQuotedExpansionSegment(
                    segment,
                    expandedText: expanded,
                    to: output
                )
            case .quotedPositionalParameters,
                 .quotedArrayValues,
                 .quotedArrayIndices:
                output = core.appendQuotedExpansionSegment(segment, expandedText: nil, to: output)
            }
        }
        return core.appendEmptyQuotedExpansionIfNeeded(text, to: output)
    }

    private mutating func expandText(_ text: String) async throws -> String {
        try await textCore.expandText(text) { step in
            try await resolveTextExpansionStep(step)
        }
    }

    private mutating func resolveTextExpansionStep(
        _ step: MSPShellTextExpansionScanner.Step
    ) async throws -> String {
        switch step {
        case .literal(let value):
            return value
        case .processSubstitution(let mode, let command):
            return try await effectAdapter.processSubstitutionPath(
                mode: mode,
                command: command
            )
        case .commandSubstitution(let command, _):
            return try await effectAdapter.commandSubstitutionOutput(command)
        case .bracedParameter(let expression):
            return try await expandParameterExpression(expression)
        case .arithmeticExpression(let expression):
            return String(try await evaluateArithmeticExpansion(expression))
        case .parameter(let name):
            return try requiredParameterValue(name).value
        }
    }

    private mutating func evaluateArithmeticExpansion(_ expression: String) async throws -> Int {
        let expandedExpression = try await expandText(expression)
        var parser = MSPShellArithmeticExpressionParser(
            expression: expandedExpression,
            variables: context.environment,
            arrays: context.arrays,
            associativeArrays: context.associativeArrays,
            namerefVariables: context.namerefVariables
        )
        return try parser.parse()
    }

    private mutating func expandParameterExpression(_ expression: String) async throws -> String {
        let grammar: MSPShellGrammar = context.enablesBashParameterExtensions ? .msp : .debianDash
        switch MSPShellParameterExpansionSyntax.parameterForm(expression, grammar: grammar) {
        case .plain(let name):
            return try requiredParameterValue(name).value
        case .arraySubscript(let subscriptExpression):
            return try await arrayValue(name: subscriptExpression.name, key: subscriptExpression.key)
        case .special(let name):
            return try requiredParameterValue(name).value
        case .length(let length):
            return try await expandParameterLength(length)
        case .arrayValues(let name):
            return core.arrayValues(name).joined(separator: " ")
        case .arrayIndices(let name):
            return core.arrayIndices(name).joined(separator: " ")
        case .operation(let name, let operation):
            return try await expandParameterOperation(name: name, operation: operation)
        case .substring(let substring):
            return try await expandParameterSubstring(substring)
        case .badSubstitution:
            throw MSPShellExpansionError.badSubstitution(expression)
        }
    }

    private mutating func expandParameterLength(
        _ length: MSPShellParameterExpansionSyntax.ParameterLength
    ) async throws -> String {
        switch length {
        case .arrayCount(let name):
            return String(core.arrayValues(name).count)
        case .nested(let expression):
            return String(try await expandParameterExpression(expression).count)
        case .reference(let name):
            return String(try requiredParameterValue(name).value.count)
        }
    }

    private mutating func expandParameterSubstring(
        _ substring: MSPShellParameterExpansionSyntax.ParameterSubstring
    ) async throws -> String {
        if MSPShellParameterExpansionSyntax.arraySplatExpression(substring.name) != nil {
            let value = try await expandParameterExpression(substring.name)
            let offset = try await evaluateArithmeticExpansion(substring.offset)
            let length: Int?
            if let lengthExpression = substring.length {
                length = try await evaluateArithmeticExpansion(lengthExpression)
            } else {
                length = nil
            }
            return try mspSubstringValue(value, offset: offset, length: length)
        }
        let offset = try await evaluateArithmeticExpansion(substring.offset)
        let length: Int?
        if let lengthExpression = substring.length {
            length = try await evaluateArithmeticExpansion(lengthExpression)
        } else {
            length = nil
        }
        return try mspSubstringValue(try requiredParameterValue(substring.name).value, offset: offset, length: length)
    }

    private mutating func expandParameterOperation(
        name: String,
        operation: MSPShellParameterExpansionSyntax.ParameterOperation
    ) async throws -> String {
        try await evaluateParameterOperationAction(
            core.parameterOperationAction(
                name: name,
                parameter: try await parameterReferenceExpression(name),
                operation: operation
            )
        )
    }

    private mutating func parameterValueExpression(_ expression: String) async throws -> (value: String, isSet: Bool) {
        if let subscriptExpression = MSPShellParameterExpansionSyntax.arraySubscriptExpression(expression) {
            return try await arrayElement(
                name: subscriptExpression.name,
                key: subscriptExpression.key,
                throwsOnUnset: false
            )
        }
        return core.parameterValue(expression)
    }

    private mutating func parameterReferenceExpression(
        _ expression: String
    ) async throws -> MSPShellParameterValueReference {
        if let subscriptExpression = MSPShellParameterExpansionSyntax.arraySubscriptExpression(expression) {
            let expandedKey = mspShellQuoteRemovedSubscriptText(try await expandText(subscriptExpression.key))
            return try core.arrayElementReference(
                name: subscriptExpression.name,
                expandedKey: expandedKey,
                originalKey: subscriptExpression.key,
                throwsOnUnset: false
            )
        }
        return core.parameterReference(expression)
    }

    private mutating func evaluateParameterOperationAction(
        _ action: MSPShellParameterOperationAction
    ) async throws -> String {
        switch action {
        case .value(let value):
            return value
        case .expandWord(let word):
            return try await expandWordText(word)
        case .expandWordThenFail(let word, let fallbackMessage):
            let message = try await expandWordText(word)
            throw MSPShellExpansionError.expansionFailed(message.isEmpty ? fallbackMessage : message)
        case .expandWordThenAssign(let word, let target):
            let value = try await expandWordText(word)
            context.apply(.assignDefault(value: value, target: target))
            return value
        case .removePrefix(let value, let patternText, let longest):
            return try mspRemoveGlobPrefix(try await expandText(patternText), from: value, longest: longest)
        case .removeSuffix(let value, let patternText, let longest):
            return try mspRemoveGlobSuffix(try await expandText(patternText), from: value, longest: longest)
        }
    }

    private mutating func arrayValue(name: String, key: String) async throws -> String {
        try await arrayElement(name: name, key: key, throwsOnUnset: true).value
    }

    private mutating func arrayElement(
        name: String,
        key: String,
        throwsOnUnset: Bool
    ) async throws -> (value: String, isSet: Bool) {
        let expandedKey = mspShellQuoteRemovedSubscriptText(try await expandText(key))
        return try core.arrayElement(
            name: name,
            expandedKey: expandedKey,
            originalKey: key,
            throwsOnUnset: throwsOnUnset
        )
    }

    private func requiredParameterValue(_ name: String) throws -> (value: String, isSet: Bool) {
        let parameter = core.parameterValue(name)
        guard parameter.isSet || !context.treatsUnsetParametersAsErrors else {
            throw MSPShellExpansionError.expansionFailed("bash: \(name): unbound variable")
        }
        return parameter
    }
}
