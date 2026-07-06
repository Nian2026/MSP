import Foundation

enum MSPShellRawReconstruction {
    static func rawInput(for command: ShellSimpleCommand) -> String {
        let assignmentText = command.assignments.map {
            "\($0.name)=\(wordRawInput($0.value))"
        }
        let commandText = (assignmentText
            + [command.commandName].compactMap { $0 }.map(wordRawInput)
            + command.arguments.map(wordRawInput))
            .joined(separator: " ")
        return appendRedirections(command.redirections, to: commandText)
    }

    static func assignmentOnlyRawInput(
        assignments: [MSPParsedAssignment],
        arrayAssignments: [MSPParsedArrayAssignment] = []
    ) -> String {
        let scalarText = assignments.map { shellQuoted("\($0.name)=\($0.value)") }
        let arrayText = arrayAssignments.map { assignment in
            let operatorText = assignment.append ? "+=" : "="
            let values = assignment.values.map(shellQuoted).joined(separator: " ")
            return "\(assignment.name)\(operatorText)(\(values))"
        }
        return (scalarText + arrayText)
            .joined(separator: " ")
    }

    static func subscriptAssignmentRawInput(
        assignment: MSPParsedSubscriptAssignment
    ) -> String {
        let operatorText = assignment.append ? "+=" : "="
        return "\(assignment.name)[\(shellQuoted(assignment.key))]\(operatorText)\(shellQuoted(assignment.value))"
    }

    static func conditionalRawInput(words: [ShellWord]) -> String {
        (["[["] + words.map(wordRawInput) + ["]]"])
            .joined(separator: " ")
    }

    static func ifRawInput(
        branches: [MSPParsedIfBranch],
        elseBody: String
    ) -> String {
        guard let first = branches.first else {
            return "if false; then :; fi"
        }

        var parts = [
            "if \(first.condition); then \(commandListBodyRawInput(first.body));"
        ]
        for branch in branches.dropFirst() {
            parts.append("elif \(branch.condition); then \(commandListBodyRawInput(branch.body));")
        }
        if !elseBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("else \(commandListBodyRawInput(elseBody));")
        }
        parts.append("fi")
        return parts.joined(separator: " ")
    }

    static func commandListBodyRawInput(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ":" : body
    }

    static func whileReadRawInput(
        spec: ShellReadSpec,
        body: String
    ) -> String {
        var readParts = spec.assignments.map {
            "\($0.name)=\(wordRawInput($0.value))"
        }
        readParts.append("read")
        if let delimiter = spec.delimiter {
            readParts.append("-d")
            readParts.append(shellQuoted(delimiter))
        }
        readParts.append(contentsOf: spec.names.map(shellQuoted))
        return "while \(readParts.joined(separator: " ")); do \(body); done"
    }

    static func caseRawInput(
        subject: ShellWord,
        arms: [ShellCaseArm]
    ) throws -> String {
        let armText = try arms.map { arm in
            let patterns = arm.patterns.map(wordRawInput).joined(separator: "|")
            let body = try commandListRawInput(arm.body)
            let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ":"
                : body
            return "\(patterns)) \(bodyText) \(arm.terminator.tokenText)"
        }
        .joined(separator: " ")
        return "case \(wordRawInput(subject)) in \(armText) esac"
    }

    static func rawInput(
        commands: [MSPParsedCommandLine],
        pipeOperators: [MSPParsedPipeOperator]
    ) -> String {
        guard !commands.isEmpty else {
            return ""
        }
        var parts: [String] = []
        for index in commands.indices {
            parts.append(commands[index].rawInput)
            if index < commands.count - 1 {
                let pipeOperator = pipeOperators.indices.contains(index) ? pipeOperators[index] : .stdout
                parts.append(pipeOperator == .stdoutAndStderr ? "|&" : "|")
            }
        }
        return parts.joined(separator: " ")
    }

    static func commandListRawInput(_ list: ShellCommandList) throws -> String {
        try list.entries.map { entry in
            let pipeline = try pipelineRawInput(entry.pipeline)
            guard let leadingOperator = entry.leadingOperator else {
                return pipeline
            }
            return "\(leadingOperator.tokenText) \(pipeline)"
        }
        .joined(separator: " ")
    }

    static func appendRedirections(
        _ redirections: [ShellRedirectionClause],
        to commandText: String
    ) -> String {
        let redirectionText = redirections.map(redirectionRawInput).joined(separator: " ")
        guard !redirectionText.isEmpty else {
            return commandText
        }
        guard !commandText.isEmpty else {
            return redirectionText
        }
        return "\(commandText) \(redirectionText)"
    }

    static func functionDefinitionRawInput(
        _ definition: ShellFunctionDefinition,
        body: String
    ) -> String {
        let bodySource: String
        switch definition.body {
        case .braceGroup:
            bodySource = "{ \(body); }"
        case .subshell:
            bodySource = "( \(body) )"
        }
        return appendRedirections(
            definition.redirections,
            to: "\(definition.name)() \(bodySource)"
        )
    }

    static func wordRawInput(_ word: ShellWord) -> String {
        if word.parts.isEmpty {
            return word.hasExplicitEmptyQuotedFragment ? "''" : word.rawText
        }
        return word.parts.map(wordPartRawInput).joined()
    }

    private static func pipelineRawInput(_ pipeline: ShellPipeline) throws -> String {
        var parts: [String] = []
        if pipeline.negated {
            parts.append("!")
        }
        for index in pipeline.commands.indices {
            parts.append(try stageRawInput(pipeline.commands[index].stage))
            if index < pipeline.commands.count - 1 {
                let pipeOperator = pipeline.pipeOperators.indices.contains(index) ? pipeline.pipeOperators[index] : .stdout
                parts.append(pipeOperator.tokenText)
            }
        }
        return parts.joined(separator: " ")
    }

    private static func stageRawInput(_ stage: ShellStage) throws -> String {
        switch stage {
        case .command(let command):
            return rawInput(for: command)
        case .assignmentList(let assignments, let arrays, let redirections):
            let assignmentText = (
                assignments.map { "\($0.name)=\(wordRawInput($0.value))" }
                    + arrays.map { array in
                        let operatorText = array.append ? "+=" : "="
                        let values = array.values.map(wordRawInput).joined(separator: " ")
                        return "\(array.name)\(operatorText)(\(values))"
                    }
            ).joined(separator: " ")
            return appendRedirections(redirections, to: assignmentText)
        case .arrayAssignment(let name, let values, let append):
            let operatorText = append ? "+=" : "="
            return "\(name)\(operatorText)(\(values.map(wordRawInput).joined(separator: " ")))"
        case .subscriptAssignment(let name, let key, let value, let append):
            let operatorText = append ? "+=" : "="
            return "\(name)[\(wordRawInput(key))]\(operatorText)\(wordRawInput(value))"
        case .arithmeticCommand(let expression, let redirections):
            return appendRedirections(redirections, to: "(( \(expression) ))")
        case .compound(.ifThen(let branches, let elseBody, let redirections)):
            let parsedBranches = try branches.map {
                MSPParsedIfBranch(
                    condition: try commandListRawInput($0.condition),
                    body: try commandListRawInput($0.body)
                )
            }
            return appendRedirections(
                redirections,
                to: ifRawInput(
                    branches: parsedBranches,
                    elseBody: try commandListRawInput(elseBody)
                )
            )
        case .compound(.whileLoop(let condition, let body, let redirections)):
            return appendRedirections(
                redirections,
                to: "while \(try commandListRawInput(condition)); do \(try commandListRawInput(body)); done"
            )
        case .compound(.untilLoop(let condition, let body, let redirections)):
            return appendRedirections(
                redirections,
                to: "until \(try commandListRawInput(condition)); do \(try commandListRawInput(body)); done"
            )
        case .compound(.whileRead(let spec, let body, let redirections)):
            return appendRedirections(
                redirections,
                to: whileReadRawInput(
                    spec: spec,
                    body: try commandListRawInput(body)
                )
            )
        case .compound(.forEach(let variable, let values, let body, let redirections)):
            let valueSource: String
            switch values {
            case .explicit(let words):
                valueSource = " in " + words.map(wordRawInput).joined(separator: " ")
            case .positionalParameters:
                valueSource = ""
            }
            return appendRedirections(
                redirections,
                to: "for \(variable)\(valueSource); do \(try commandListRawInput(body)); done"
            )
        case .compound(.cStyleFor(let initExpression, let conditionExpression, let updateExpression, let body, let redirections)):
            return appendRedirections(
                redirections,
                to: "for (( \(initExpression); \(conditionExpression); \(updateExpression) )); do \(try commandListRawInput(body)); done"
            )
        case .compound(.caseOf(let subject, let arms, let redirections)):
            return appendRedirections(
                redirections,
                to: try caseRawInput(subject: subject, arms: arms)
            )
        case .compound(.conditional(let words, let redirections)):
            return appendRedirections(redirections, to: conditionalRawInput(words: words))
        case .compound(.group(let body, let redirections)):
            return appendRedirections(redirections, to: "{ \(try commandListRawInput(body)); }")
        case .compound(.subshell(let body, let redirections)):
            return appendRedirections(redirections, to: "( \(try commandListRawInput(body)) )")
        case .functionDefinition(let definition):
            return functionDefinitionRawInput(
                definition,
                body: try commandListRawInput(definition.body.innerCommandList)
            )
        }
    }

    private static func redirectionRawInput(_ redirection: ShellRedirectionClause) -> String {
        let fd = redirection.fd.map(String.init) ?? ""
        return "\(fd)\(redirection.operation.rawValue) \(wordRawInput(redirection.target))"
    }

    private static func wordPartRawInput(_ part: ShellWord.Part) -> String {
        let text = part.text
        guard part.isQuoted else {
            return text
        }
        if part.isExpandable {
            return doubleQuoted(text)
        }
        return shellQuoted(text)
    }

    private static func doubleQuoted(_ value: String) -> String {
        let protectedRanges = commandSubstitutionSourceRanges(in: value)
        var escaped = ""
        var rangeIndex = protectedRanges.startIndex
        var index = value.startIndex
        while index < value.endIndex {
            if rangeIndex < protectedRanges.endIndex,
               index == protectedRanges[rangeIndex].lowerBound {
                escaped += value[protectedRanges[rangeIndex]]
                index = protectedRanges[rangeIndex].upperBound
                rangeIndex = protectedRanges.index(after: rangeIndex)
                continue
            }

            switch value[index] {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "`":
                escaped += #"\`"#
            default:
                escaped.append(value[index])
            }
            index = value.index(after: index)
        }
        return "\"\(escaped)\""
    }

    private static func commandSubstitutionSourceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`",
               let substitution = try? MSPShellSubstitutionScanner.backtickSubstitutionCommand(
                in: text,
                startingAt: index
               ) {
                ranges.append(index..<substitution.nextIndex)
                index = substitution.nextIndex
                continue
            }

            guard text[index] == "$" else {
                index = text.index(after: index)
                continue
            }
            let openIndex = text.index(after: index)
            guard openIndex < text.endIndex, text[openIndex] == "(" else {
                index = openIndex
                continue
            }

            let bodyStart = text.index(after: openIndex)
            if bodyStart < text.endIndex,
               text[bodyStart] == "(",
               let nextIndex = try? MSPShellSubstitutionScanner.arithmeticExpansionEndIndex(
                in: text,
                startingAt: index,
                grammar: .msp
               ) {
                index = nextIndex
                continue
            }

            if let nextIndex = try? MSPShellSubstitutionScanner.commandSubstitutionEndIndex(
                in: text,
                startingAt: index,
                grammar: .msp
            ) {
                ranges.append(index..<nextIndex)
                index = nextIndex
                continue
            }

            index = openIndex
        }
        return ranges
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-+=,%@[]")
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
