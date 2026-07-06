import MSPShell

extension ModelShellProxy {
    func shellRuntimeReentryExpansionPorts() -> ShellRuntimeReentryExpansionPorts {
        ShellRuntimeReentryExpansionPorts(
            expandedReadAssignmentEnvironment: { [self] spec, lastExitCode, stderr in
                try await expandedReadAssignmentEnvironment(
                    spec: spec,
                    lastExitCode: lastExitCode,
                    stderr: &stderr
                )
            },
            expandWordText: { [self] word, lastExitCode, enablesPathnameExpansion, enablesWordSplitting in
                try await expandCompoundWordText(
                    word,
                    lastExitCode: lastExitCode,
                    enablesPathnameExpansion: enablesPathnameExpansion,
                    enablesWordSplitting: enablesWordSplitting
                )
            },
            expandWordVariants: { [self] word, lastExitCode in
                try await expandCompoundWordVariants(word, lastExitCode: lastExitCode)
            }
        )
    }

    private func applyShellWordExpansionState(_ expansion: MSPShellWordTextExpansionResult) {
        runtime.applyExpansionState(expansion)
    }

    private func applyShellWordExpansionState(_ expansion: MSPShellWordExpansionResult) {
        runtime.applyExpansionState(expansion)
    }

    private func expandCompoundWordText(
        _ word: MSPParsedWord,
        lastExitCode: Int32,
        enablesPathnameExpansion: Bool = true,
        enablesWordSplitting: Bool = true
    ) async throws -> MSPShellWordTextExpansionResult {
        let expansion = try await word.expandedTextResolvingCommandSubstitutions(
            in: try await shellExpansionContext(
                lastExitCode: lastExitCode,
                enablesPathnameExpansion: enablesPathnameExpansion,
                enablesWordSplitting: enablesWordSplitting,
                requiresPathnameCandidates: false
            ),
            resolver: { commandLine in
                await self.runCommandSubstitution(
                    commandLine,
                    standardInput: self.configuration.standardInput,
                    standardInputClosed: self.configuration.standardInputClosed,
                    lastExitCode: lastExitCode
                )
            },
            processSubstitutionResolver: { request in
                try await self.resolveProcessSubstitution(
                    request,
                    standardInput: self.configuration.standardInput,
                    standardInputClosed: self.configuration.standardInputClosed,
                    standardInputOverridesFileDescriptor: false,
                    lastExitCode: lastExitCode
                )
            }
        )
        applyShellWordExpansionState(expansion)
        return expansion
    }

    private func expandCompoundWordVariants(
        _ word: MSPParsedWord,
        lastExitCode: Int32
    ) async throws -> MSPShellWordExpansionResult {
        let expansion = try await word.expandedVariantsResolvingCommandSubstitutions(
            in: try await shellExpansionContext(
                lastExitCode: lastExitCode,
                requiresPathnameCandidates: word.mspMayNeedPathnameExpansionCandidates(
                    enablesExtendedGlob: runtime.shellOptionEnabled("extglob"),
                    enablesWordSplitting: true
                )
            ),
            resolver: { commandLine in
                await self.runCommandSubstitution(
                    commandLine,
                    standardInput: self.configuration.standardInput,
                    standardInputClosed: self.configuration.standardInputClosed,
                    lastExitCode: lastExitCode
                )
            },
            processSubstitutionResolver: { request in
                try await self.resolveProcessSubstitution(
                    request,
                    standardInput: self.configuration.standardInput,
                    standardInputClosed: self.configuration.standardInputClosed,
                    standardInputOverridesFileDescriptor: false,
                    lastExitCode: lastExitCode
                )
            }
        )
        applyShellWordExpansionState(expansion)
        return expansion
    }

    private func expandedReadAssignmentEnvironment(
        spec: MSPParsedReadSpec,
        lastExitCode: Int32,
        stderr: inout String
    ) async throws -> [MSPParsedAssignment] {
        var assignments: [MSPParsedAssignment] = []
        for (index, assignment) in spec.assignments.enumerated() {
            let value: String
            if spec.assignmentValueWords.indices.contains(index) {
                let expansion = try await expandCompoundWordText(
                    spec.assignmentValueWords[index],
                    lastExitCode: lastExitCode,
                    enablesPathnameExpansion: false,
                    enablesWordSplitting: false
                )
                stderr += expansion.stderr
                value = expansion.value
            } else {
                value = assignment.value
            }
            assignments.append(MSPParsedAssignment(name: assignment.name, value: value))
        }
        return assignments
    }
}
