import Foundation
import MSPShellLanguage

struct MSPShellWordExpander {
    var context: MSPShellExpansionContext

    private var core: MSPShellWordExpansionCore {
        MSPShellWordExpansionCore(context: context)
    }

    private var textCore: MSPShellTextExpansionCore {
        MSPShellTextExpansionCore(commandSubstitutions: .preserveAsLiteral)
    }

    private var effectAdapter: MSPShellSyncExpansionEffectAdapter {
        MSPShellSyncExpansionEffectAdapter()
    }

    func expandWordText(_ word: MSPParsedWord) throws -> String {
        var result = ""
        for part in word.parts {
            let text = part.isExpandable
                ? try expandText(part.text)
                : part.text
            result += text
        }
        return result
    }

    func expandWordVariants(_ word: MSPParsedWord) throws -> [String] {
        if context.enablesBraceExpansion,
           let expandedWords = mspShellBraceExpandedWords(word),
           expandedWords.count != 1 || expandedWords.first != word {
            return try expandedWords.flatMap(expandWordVariantsWithoutBraceExpansion)
        }
        return try expandWordVariantsWithoutBraceExpansion(word)
    }

    private func expandWordVariantsWithoutBraceExpansion(_ word: MSPParsedWord) throws -> [String] {
        var fields = core.initialFields(for: word)

        for part in word.parts {
            if part.isQuoted, part.isExpandable {
                fields = try appendQuotedExpansion(part.text, to: fields)
            } else if part.isExpandable {
                fields = core.appendExpandedWordPart(
                    part,
                    expandedText: try expandText(part.text),
                    to: fields
                )
            } else {
                fields = core.appendLiteralWordPart(part, to: fields)
            }
        }

        return try core.finishFields(fields)
    }

    private func appendQuotedExpansion(
        _ text: String,
        to fields: [MSPShellExpandedField]
    ) throws -> [MSPShellExpandedField] {
        var output = fields
        for segment in mspShellExpansionSegmentsPreservingQuotedPositionalParameters(in: text) {
            switch segment {
            case .text(let rawText):
                output = core.appendQuotedExpansionSegment(
                    segment,
                    expandedText: try expandText(rawText),
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

    private func expandText(_ text: String) throws -> String {
        try textCore.expandText(text) { step in
            try resolveTextExpansionStep(step)
        }
    }

    private func resolveTextExpansionStep(
        _ step: MSPShellTextExpansionScanner.Step
    ) throws -> String {
        switch step {
        case .literal(let value):
            return value
        case .processSubstitution(let mode, _):
            return try effectAdapter.processSubstitutionPath(mode: mode)
        case .commandSubstitution(_, let rawText):
            return effectAdapter.preservedCommandSubstitution(rawText: rawText)
        case .bracedParameter(let expression):
            return try expandParameterExpression(expression)
        case .arithmeticExpression(let expression):
            return String(try evaluateArithmeticExpansion(expression))
        case .parameter(let name):
            return try requiredParameterValue(name).value
        }
    }

    private func evaluateArithmeticExpansion(_ expression: String) throws -> Int {
        let expandedExpression = try expandText(expression)
        var parser = MSPShellArithmeticExpressionParser(
            expression: expandedExpression,
            variables: context.environment,
            arrays: context.arrays,
            associativeArrays: context.associativeArrays,
            namerefVariables: context.namerefVariables
        )
        return try parser.parse()
    }

    private func expandParameterExpression(_ expression: String) throws -> String {
        let grammar: MSPShellGrammar = context.enablesBashParameterExtensions ? .msp : .debianDash
        switch MSPShellParameterExpansionSyntax.parameterForm(expression, grammar: grammar) {
        case .plain(let name):
            return try requiredParameterValue(name).value
        case .arraySubscript(let subscriptExpression):
            return try arrayValue(name: subscriptExpression.name, key: subscriptExpression.key)
        case .special(let name):
            return try requiredParameterValue(name).value
        case .length(let length):
            return try expandParameterLength(length)
        case .arrayValues(let name):
            return core.arrayValues(name).joined(separator: " ")
        case .arrayIndices(let name):
            return core.arrayIndices(name).joined(separator: " ")
        case .operation(let name, let operation):
            return try expandParameterOperation(name: name, operation: operation)
        case .substring(let substring):
            return try expandParameterSubstring(substring)
        case .badSubstitution:
            throw MSPShellExpansionError.badSubstitution(expression)
        }
    }

    private func expandParameterLength(
        _ length: MSPShellParameterExpansionSyntax.ParameterLength
    ) throws -> String {
        switch length {
        case .arrayCount(let name):
            return String(core.arrayValues(name).count)
        case .nested(let expression):
            return String(try expandParameterExpression(expression).count)
        case .reference(let name):
            return String(try requiredParameterValue(name).value.count)
        }
    }

    private func expandParameterSubstring(
        _ substring: MSPShellParameterExpansionSyntax.ParameterSubstring
    ) throws -> String {
        if MSPShellParameterExpansionSyntax.arraySplatExpression(substring.name) != nil {
            return try mspSubstringValue(
                expandParameterExpression(substring.name),
                offset: try evaluateArithmeticExpansion(substring.offset),
                length: try substring.length.map { try evaluateArithmeticExpansion($0) }
            )
        }
        let offset = try evaluateArithmeticExpansion(substring.offset)
        let length = try substring.length.map { try evaluateArithmeticExpansion($0) }
        return try mspSubstringValue(try requiredParameterValue(substring.name).value, offset: offset, length: length)
    }

    private func expandParameterOperation(
        name: String,
        operation: MSPShellParameterExpansionSyntax.ParameterOperation
    ) throws -> String {
        try evaluateParameterOperationAction(
            core.parameterOperationAction(
                name: name,
                parameter: try parameterReferenceExpression(name),
                operation: operation
            )
        )
    }

    private func parameterValueExpression(_ expression: String) throws -> (value: String, isSet: Bool) {
        if let subscriptExpression = MSPShellParameterExpansionSyntax.arraySubscriptExpression(expression) {
            return try arrayElement(
                name: subscriptExpression.name,
                key: subscriptExpression.key,
                throwsOnUnset: false
            )
        }
        return core.parameterValue(expression)
    }

    private func parameterReferenceExpression(_ expression: String) throws -> MSPShellParameterValueReference {
        if let subscriptExpression = MSPShellParameterExpansionSyntax.arraySubscriptExpression(expression) {
            let expandedKey = mspShellQuoteRemovedSubscriptText(try expandText(subscriptExpression.key))
            return try core.arrayElementReference(
                name: subscriptExpression.name,
                expandedKey: expandedKey,
                originalKey: subscriptExpression.key,
                throwsOnUnset: false
            )
        }
        return core.parameterReference(expression)
    }

    private func evaluateParameterOperationAction(
        _ action: MSPShellParameterOperationAction
    ) throws -> String {
        switch action {
        case .value(let value):
            return value
        case .expandWord(let word):
            return try expandWordText(word)
        case .expandWordThenFail(let word, let fallbackMessage):
            let message = try expandWordText(word)
            throw MSPShellExpansionError.expansionFailed(message.isEmpty ? fallbackMessage : message)
        case .expandWordThenAssign(let word, _):
            return try expandWordText(word)
        case .removePrefix(let value, let patternText, let longest):
            return try mspRemoveGlobPrefix(try expandText(patternText), from: value, longest: longest)
        case .removeSuffix(let value, let patternText, let longest):
            return try mspRemoveGlobSuffix(try expandText(patternText), from: value, longest: longest)
        }
    }

    private func arrayValue(name: String, key: String) throws -> String {
        try arrayElement(name: name, key: key, throwsOnUnset: true).value
    }

    private func arrayElement(
        name: String,
        key: String,
        throwsOnUnset: Bool
    ) throws -> (value: String, isSet: Bool) {
        let expandedKey = mspShellQuoteRemovedSubscriptText(try expandText(key))
        return try core.arrayElement(
            name: name,
            expandedKey: expandedKey,
            originalKey: key,
            throwsOnUnset: throwsOnUnset
        )
    }

    private func requiredParameterValue(_ name: String) throws -> (value: String, isSet: Bool) {
        let parameter = try parameterValueExpression(name)
        guard parameter.isSet || !context.treatsUnsetParametersAsErrors else {
            throw MSPShellExpansionError.expansionFailed("bash: \(name): unbound variable")
        }
        return parameter
    }
}
