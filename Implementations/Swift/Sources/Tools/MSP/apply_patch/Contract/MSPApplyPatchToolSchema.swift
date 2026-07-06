import Foundation

public enum MSPApplyPatchToolSchema {
    public static let name = "apply_patch"

    public static let description =
        "Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON."

    public static let larkGrammar = """
    start: begin_patch hunk+ end_patch
    begin_patch: "*** Begin Patch" LF
    end_patch: "*** End Patch" LF?

    hunk: add_hunk | delete_hunk | update_hunk
    add_hunk: "*** Add File: " filename LF add_line+
    delete_hunk: "*** Delete File: " filename LF
    update_hunk: "*** Update File: " filename LF change_move? change?

    filename: /(.+)/
    add_line: "+" /(.*)/ LF -> line

    change_move: "*** Move to: " filename LF
    change: (change_context | change_line)+ eof_line?
    change_context: ("@@" | "@@ " /(.+)/) LF
    change_line: ("+" | "-" | " ") /(.*)/ LF
    eof_line: "*** End of File" LF

    %import common.LF
    """

    public static func grammar(includeEnvironmentID: Bool = false) -> String {
        guard includeEnvironmentID else {
            return larkGrammar
        }
        return larkGrammar.replacingOccurrences(
            of: "start: begin_patch hunk+ end_patch",
            with: "start: begin_patch environment_id? hunk+ end_patch\nenvironment_id: \"*** Environment ID: \" filename LF"
        )
    }

    public static func format(includeEnvironmentID: Bool = false) -> MSPAgentFreeformToolFormat {
        MSPAgentFreeformToolFormat(
            type: "grammar",
            syntax: "lark",
            definition: grammar(includeEnvironmentID: includeEnvironmentID)
        )
    }
}
