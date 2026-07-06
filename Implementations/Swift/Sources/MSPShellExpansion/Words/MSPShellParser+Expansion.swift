import Foundation
import MSPShellLanguage

public extension MSPShellParser {
    @available(*, deprecated, message: "Parse first, then call expanded(in:) on MSPParsedCommandLine.")
    func parseExecutableInvocation(
        _ input: String,
        expansion: MSPShellExpansionContext
    ) throws -> MSPParsedCommandLine {
        try parseExecutableInvocation(input).expanded(in: expansion)
    }

    @available(*, deprecated, message: "Parse first, then call expanded(in:) on each MSPParsedCommandLine.")
    func parseExecutableInvocations(
        _ input: String,
        expansion: MSPShellExpansionContext
    ) throws -> [MSPParsedCommandLine] {
        try parseExecutableInvocations(input).map { try $0.expanded(in: expansion) }
    }
}
