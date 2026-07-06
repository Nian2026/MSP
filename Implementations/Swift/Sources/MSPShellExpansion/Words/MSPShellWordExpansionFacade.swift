import Foundation
import MSPShellLanguage

extension MSPParsedWord {
    public func expandedTextResolvingCommandSubstitutions(
        in context: MSPShellExpansionContext,
        resolver: @escaping @Sendable (String) async throws -> MSPShellCommandSubstitutionResult,
        processSubstitutionResolver: MSPShellProcessSubstitutionResolver? = nil
    ) async throws -> MSPShellWordTextExpansionResult {
        var expander = MSPShellAsyncWordExpander(
            context: context,
            commandSubstitutionResolver: resolver,
            processSubstitutionResolver: processSubstitutionResolver
        )
        let value = try await expander.expandWordText(self)
        return MSPShellWordTextExpansionResult(
            value: value,
            stderr: expander.substitutionStderr,
            state: expander.context.expansionState
        )
    }

    public func expandedVariantsResolvingCommandSubstitutions(
        in context: MSPShellExpansionContext,
        resolver: @escaping @Sendable (String) async throws -> MSPShellCommandSubstitutionResult,
        processSubstitutionResolver: MSPShellProcessSubstitutionResolver? = nil
    ) async throws -> MSPShellWordExpansionResult {
        var expander = MSPShellAsyncWordExpander(
            context: context,
            commandSubstitutionResolver: resolver,
            processSubstitutionResolver: processSubstitutionResolver
        )
        let values = try await expander.expandWordVariants(self)
        return MSPShellWordExpansionResult(
            values: values,
            stderr: expander.substitutionStderr,
            state: expander.context.expansionState
        )
    }
}
