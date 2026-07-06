import Foundation
import MSPShellLanguage

enum MSPShellParameterAssignmentTarget {
    case scalar(name: String)
    case indexedArrayElement(name: String, index: Int)
    case associativeArrayElement(name: String, key: String)
}

struct MSPShellParameterValueReference {
    var value: String
    var isSet: Bool
    var assignmentTarget: MSPShellParameterAssignmentTarget
}

enum MSPShellParameterOperationAction {
    case value(String)
    case expandWord(MSPParsedWord)
    case expandWordThenFail(MSPParsedWord, fallbackMessage: String)
    case expandWordThenAssign(MSPParsedWord, target: MSPShellParameterAssignmentTarget)
    case removePrefix(value: String, patternText: String, longest: Bool)
    case removeSuffix(value: String, patternText: String, longest: Bool)
}

struct MSPShellWordExpansionCore {
    var context: MSPShellExpansionContext

    func initialFields(for word: MSPParsedWord) -> [MSPShellExpandedField] {
        var fields = [MSPShellExpandedField()]
        if word.hasExplicitEmptyQuotedFragment {
            fields[0].forceKeep = true
        }
        return fields
    }

    func appendExpandedWordPart(
        _ part: MSPParsedWord.Part,
        expandedText: String,
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        if part.isQuoted || !context.enablesWordSplitting {
            return appendLiteral(
                expandedText,
                to: fields,
                globActive: false,
                forceKeepWhenEmpty: part.isQuoted
            )
        }
        return appendSplit(expandedText, to: fields)
    }

    func appendLiteralWordPart(
        _ part: MSPParsedWord.Part,
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        appendLiteral(
            part.text,
            to: fields,
            globActive: !part.isQuoted && context.enablesWordSplitting,
            forceKeepWhenEmpty: part.isQuoted
        )
    }

    func appendQuotedExpansionSegment(
        _ segment: MSPShellExpansionSegment,
        expandedText: String?,
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        switch segment {
        case .text:
            return appendLiteral(
                expandedText ?? "",
                to: fields,
                globActive: false,
                forceKeepWhenEmpty: true
            )
        case .quotedPositionalParameters(let mode):
            return mode == "@"
                ? appendQuotedPositionalParameters(to: fields)
                : appendQuotedArrayExpansion(context.positionalParameters, mode: mode, to: fields)
        case .quotedArrayValues(let name, let mode):
            return appendQuotedArrayExpansion(arrayValues(name), mode: mode, to: fields)
        case .quotedArrayIndices(let name, let mode):
            return appendQuotedArrayExpansion(arrayIndices(name), mode: mode, to: fields)
        }
    }

    func appendEmptyQuotedExpansionIfNeeded(
        _ text: String,
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        guard text.isEmpty else {
            return fields
        }
        return appendLiteral("", to: fields, globActive: false, forceKeepWhenEmpty: true)
    }

    func finishFields(_ fields: [MSPShellExpandedField]) throws -> [String] {
        let keptFields = fields.filter { !$0.isEmpty || $0.forceKeep }
        guard !keptFields.isEmpty else {
            return []
        }
        guard context.enablesPathnameExpansion else {
            return keptFields.map(\.text)
        }
        return try keptFields.flatMap { try expandPathnameField($0) }
    }

    func appendLiteral(
        _ text: String,
        to fields: [MSPShellExpandedField],
        globActive: Bool,
        forceKeepWhenEmpty: Bool = false
    ) -> [MSPShellExpandedField] {
        var output = fields
        for index in output.indices where output[index].acceptsContinuation {
            output[index].append(text, globActive: globActive)
            if forceKeepWhenEmpty && text.isEmpty {
                output[index].forceKeep = true
            }
        }
        return output
    }

    func appendQuotedPositionalParameters(
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        guard !context.positionalParameters.isEmpty else {
            return fields
        }

        var output: [MSPShellExpandedField] = []
        for field in fields {
            guard field.acceptsContinuation else {
                output.append(field)
                continue
            }
            for (index, parameter) in context.positionalParameters.enumerated() {
                var next = index == 0 ? field : MSPShellExpandedField()
                next.append(parameter, globActive: false)
                next.forceKeep = true
                next.acceptsContinuation = index == context.positionalParameters.count - 1
                output.append(next)
            }
        }
        return output
    }

    func appendQuotedArrayExpansion(
        _ values: [String],
        mode: String,
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        guard mode == "@" else {
            return appendLiteral(
                values.joined(separator: ifsJoinSeparator),
                to: fields,
                globActive: false,
                forceKeepWhenEmpty: true
            )
        }
        guard !values.isEmpty else {
            return fields
        }

        var output: [MSPShellExpandedField] = []
        for field in fields {
            guard field.acceptsContinuation else {
                output.append(field)
                continue
            }
            for (index, value) in values.enumerated() {
                var next = index == 0 ? field : MSPShellExpandedField()
                next.append(value, globActive: false)
                next.forceKeep = true
                next.acceptsContinuation = index == values.count - 1
                output.append(next)
            }
        }
        return output
    }

    func appendSplit(
        _ text: String,
        to fields: [MSPShellExpandedField]
    ) -> [MSPShellExpandedField] {
        let segments = mspShellFieldSplit(text, ifs: context.ifs)
        guard !segments.isEmpty else {
            return fields
        }
        var output: [MSPShellExpandedField] = []
        for field in fields {
            guard field.acceptsContinuation else {
                output.append(field)
                continue
            }
            for (index, segment) in segments.enumerated() {
                var next = index == 0 ? field : MSPShellExpandedField()
                next.append(segment, globActive: true)
                if segment.isEmpty {
                    next.forceKeep = true
                }
                next.acceptsContinuation = index == segments.count - 1
                output.append(next)
            }
        }
        return output
    }

    func parameterValue(_ name: String) -> (value: String, isSet: Bool) {
        if name == "@" || name == "*" {
            return (context.positionalParameters.joined(separator: " "), true)
        }
        if let special = context.specialParameters[name] {
            return (special, true)
        }
        let resolvedName = resolvedNamerefName(name)
        if let value = context.environment[resolvedName] {
            return (value, true)
        }
        if let values = context.arrays[resolvedName] {
            return (values.first ?? "", true)
        }
        if context.associativeArrays[resolvedName] != nil {
            return ("", true)
        }
        return ("", false)
    }

    func parameterReference(_ name: String) -> MSPShellParameterValueReference {
        let parameter = parameterValue(name)
        return MSPShellParameterValueReference(
            value: parameter.value,
            isSet: parameter.isSet,
            assignmentTarget: .scalar(name: resolvedNamerefName(name))
        )
    }

    func arrayValues(_ name: String) -> [String] {
        let resolvedName = resolvedNamerefName(name)
        if let values = context.associativeArrays[resolvedName] {
            return values.keys.sorted().map { values[$0] ?? "" }
        }
        return context.arrays[resolvedName]?.valuesByIndex ?? []
    }

    func arrayIndices(_ name: String) -> [String] {
        let resolvedName = resolvedNamerefName(name)
        if let values = context.associativeArrays[resolvedName] {
            return values.keys.sorted()
        }
        return (context.arrays[resolvedName]?.indicesByIndex ?? []).map(String.init)
    }

    func arrayElement(
        name: String,
        expandedKey: String,
        originalKey: String,
        throwsOnUnset: Bool
    ) throws -> (value: String, isSet: Bool) {
        let resolvedName = resolvedNamerefName(name)
        if let values = context.associativeArrays[resolvedName] {
            if let value = values[expandedKey] {
                return (value, true)
            }
            if throwsOnUnset, context.treatsUnsetParametersAsErrors {
                throw MSPShellExpansionError.expansionFailed("bash: \(name)[\(originalKey)]: unbound variable")
            }
            return ("", false)
        }
        let index = Int(expandedKey) ?? 0
        if let value = context.arrays[resolvedName]?[index] {
            return (value, true)
        }
        if throwsOnUnset, context.treatsUnsetParametersAsErrors {
            throw MSPShellExpansionError.expansionFailed("bash: \(name)[\(originalKey)]: unbound variable")
        }
        return ("", false)
    }

    func arrayElementReference(
        name: String,
        expandedKey: String,
        originalKey: String,
        throwsOnUnset: Bool
    ) throws -> MSPShellParameterValueReference {
        let parameter = try arrayElement(
            name: name,
            expandedKey: expandedKey,
            originalKey: originalKey,
            throwsOnUnset: throwsOnUnset
        )
        return MSPShellParameterValueReference(
            value: parameter.value,
            isSet: parameter.isSet,
            assignmentTarget: arrayAssignmentTarget(name: name, expandedKey: expandedKey)
        )
    }

    func arrayAssignmentTarget(
        name: String,
        expandedKey: String
    ) -> MSPShellParameterAssignmentTarget {
        let resolvedName = resolvedNamerefName(name)
        if context.associativeArrays[resolvedName] != nil {
            return .associativeArrayElement(name: resolvedName, key: expandedKey)
        }
        return .indexedArrayElement(name: resolvedName, index: Int(expandedKey) ?? 0)
    }

    func parameterOperationAction(
        name: String,
        parameter: MSPShellParameterValueReference,
        operation: MSPShellParameterExpansionSyntax.ParameterOperation
    ) -> MSPShellParameterOperationAction {
        switch operation {
        case .defaultValue(let word, let checkEmpty):
            if !parameter.isSet || (checkEmpty && parameter.value.isEmpty) {
                return .expandWord(word.parsedWord)
            }
            return .value(parameter.value)
        case .useAlternative(let word, let checkEmpty):
            if parameter.isSet && (!checkEmpty || !parameter.value.isEmpty) {
                return .expandWord(word.parsedWord)
            }
            return .value("")
        case .errorIfUnset(let word, let checkEmpty):
            if !parameter.isSet || (checkEmpty && parameter.value.isEmpty) {
                return .expandWordThenFail(
                    word.parsedWord,
                    fallbackMessage: "\(name): parameter null or not set"
                )
            }
            return .value(parameter.value)
        case .assignDefault(let word, let checkEmpty):
            if !parameter.isSet || (checkEmpty && parameter.value.isEmpty) {
                return .expandWordThenAssign(word.parsedWord, target: parameter.assignmentTarget)
            }
            return .value(parameter.value)
        case .lowercaseAll,
             .lowercaseFirst,
             .uppercaseAll,
             .uppercaseFirst,
             .replacement:
            return .value(transformedParameterValue(parameter.value, operation: operation))
        case .removePrefix(pattern: let patternText, longest: let longest):
            return .removePrefix(value: parameter.value, patternText: patternText, longest: longest)
        case .removeSuffix(pattern: let patternText, longest: let longest):
            return .removeSuffix(value: parameter.value, patternText: patternText, longest: longest)
        }
    }

    func transformedParameterValue(
        _ value: String,
        operation: MSPShellParameterExpansionSyntax.ParameterOperation
    ) -> String {
        switch operation {
        case .lowercaseAll:
            return value.lowercased()
        case .lowercaseFirst:
            guard let first = value.first else { return value }
            return first.lowercased() + String(value.dropFirst())
        case .uppercaseAll:
            return value.uppercased()
        case .uppercaseFirst:
            guard let first = value.first else { return value }
            return first.uppercased() + String(value.dropFirst())
        case .replacement(pattern: let patternText, replacement: let replacementText, global: let global):
            let pattern = mspShellDecodeBackslashEscapes(patternText)
            let replacement = mspShellDecodeBackslashEscapes(replacementText)
            guard !pattern.isEmpty else { return value }
            if global {
                return value.replacingOccurrences(of: pattern, with: replacement)
            }
            guard let range = value.range(of: pattern) else {
                return value
            }
            return value.replacingCharacters(in: range, with: replacement)
        case .defaultValue,
             .useAlternative,
             .errorIfUnset,
             .assignDefault,
             .removePrefix,
             .removeSuffix:
            return value
        }
    }

    func resolvedNamerefName(_ name: String) -> String {
        var current = name
        var seen: Set<String> = []
        while let next = context.namerefVariables[current],
              MSPShellExpansionScanner.isShellVariableName(next),
              !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }

    func expandPathnameField(_ field: MSPShellExpandedField) throws -> [String] {
        guard field.containsActiveGlob(extendedGlob: context.enablesExtendedGlob) else {
            return [field.text]
        }
        let normalized = normalizedPattern(field)
        let matches = context.pathnameCandidates
            .filter { path in
                normalized.matches(
                    path,
                    caseInsensitive: context.enablesNoCaseGlob,
                    extendedGlob: context.enablesExtendedGlob,
                    globStar: context.enablesGlobStar
                )
            }
            .filter { path in
                context.enablesDotGlob || normalized.explicitlyMatchesHiddenComponents(in: path)
            }
            .map { displayPath($0, rawPattern: field.text) }
            .sorted()
        if matches.isEmpty {
            if context.enablesFailGlob {
                throw MSPShellExpansionError.expansionFailed("no match: \(field.text)")
            }
            return context.enablesNullGlob ? [] : [field.text]
        }
        return matches
    }

    static func isSpecialParameter(_ character: Character) -> Bool {
        ["?", "$", "!", "#", "@", "*", "-"].contains(character)
    }

    private var ifsJoinSeparator: String {
        context.ifs.first.map(String.init) ?? ""
    }

    private func normalizedPattern(_ field: MSPShellExpandedField) -> MSPGlobPattern {
        var parts = field.parts
        if !field.text.hasPrefix("/") {
            let base = normalizedPath(context.currentDirectory)
            let prefix = base == "/" ? "/" : "\(base)/"
            parts.insert(.init(text: prefix, globActive: false), at: 0)
        }
        return MSPGlobPattern(parts: parts)
    }

    private func displayPath(_ path: String, rawPattern: String) -> String {
        if rawPattern.hasPrefix("/") {
            return path
        }
        let relative = relativePath(path, from: normalizedPath(context.currentDirectory))
        if rawPattern.hasPrefix("./") {
            return relative == "." ? "." : "./\(relative)"
        }
        return relative
    }
}
