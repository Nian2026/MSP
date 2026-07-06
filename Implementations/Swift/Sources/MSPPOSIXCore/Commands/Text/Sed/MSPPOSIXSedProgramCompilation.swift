import Foundation

extension MSPPOSIXSedRunner {
    struct CompiledSedProgramCommand {
        var id: Int
        var command: MSPPOSIXSedProgramCommand
        var kind: CompiledSedProgramKind
        var gates: [SedAddressGate]
    }

    struct CompiledSedProgram {
        var commands: [CompiledSedProgramCommand]
        var labels: [String: Int]
    }

    struct SedAddressGate {
        var id: Int
        var command: MSPPOSIXSedProgramCommand
    }

    enum CompiledSedProgramKind {
        case substitution(MSPPOSIXSedSubstitution, NSRegularExpression)
        case print
        case list
        case quit
        case delete
        case append(String)
        case insert(String)
        case change(String)
        case hold
        case holdAppend
        case get
        case getAppend
        case exchange
        case label(String)
        case branch(String?)
        case branchIfSubstitution(String?)
    }

    static func compileProgram(_ commands: [MSPPOSIXSedProgramCommand]) throws -> CompiledSedProgram {
        var nextID = 0
        var compiled: [CompiledSedProgramCommand] = []
        try compileProgram(commands, gates: [], nextID: &nextID, output: &compiled)
        let labels = labelIndexes(in: compiled)
        try validateBranchLabels(in: compiled, labels: labels)
        return CompiledSedProgram(commands: compiled, labels: labels)
    }

    private static func compileProgram(
        _ commands: [MSPPOSIXSedProgramCommand],
        gates: [SedAddressGate],
        nextID: inout Int,
        output: inout [CompiledSedProgramCommand]
    ) throws {
        for command in commands {
            let id = nextID
            nextID += 1
            switch command.kind {
            case .substitution(let substitution):
                do {
                    let options: NSRegularExpression.Options = substitution.caseInsensitive ? [.caseInsensitive] : []
                    let regex = try NSRegularExpression(
                        pattern: MSPPOSIXSedRegex.pattern(for: substitution.pattern, extended: substitution.extendedRegex),
                        options: options
                    )
                    output.append(CompiledSedProgramCommand(id: id, command: command, kind: .substitution(substitution, regex), gates: gates))
                } catch {
                    throw MSPPOSIXSedError.usage("sed: invalid regex: \(error.localizedDescription)")
                }
            case .print:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .print, gates: gates))
            case .list:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .list, gates: gates))
            case .quit:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .quit, gates: gates))
            case .delete:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .delete, gates: gates))
            case .append(let text):
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .append(text), gates: gates))
            case .insert(let text):
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .insert(text), gates: gates))
            case .change(let text):
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .change(text), gates: gates))
            case .hold:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .hold, gates: gates))
            case .holdAppend:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .holdAppend, gates: gates))
            case .get:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .get, gates: gates))
            case .getAppend:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .getAppend, gates: gates))
            case .exchange:
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .exchange, gates: gates))
            case .label(let label):
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .label(label), gates: gates))
            case .branch(let label):
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .branch(label), gates: gates))
            case .branchIfSubstitution(let label):
                output.append(CompiledSedProgramCommand(id: id, command: command, kind: .branchIfSubstitution(label), gates: gates))
            case .group(let commands):
                let groupGate = SedAddressGate(
                    id: id,
                    command: MSPPOSIXSedProgramCommand(
                        start: command.start,
                        end: command.end,
                        negated: command.negated,
                        kind: .group([])
                    )
                )
                try compileProgram(commands, gates: gates + [groupGate], nextID: &nextID, output: &output)
            }
        }
    }

    private static func labelIndexes(in commands: [CompiledSedProgramCommand]) -> [String: Int] {
        var labels: [String: Int] = [:]
        for (index, command) in commands.enumerated() {
            if case .label(let label) = command.kind {
                labels[label] = index
            }
        }
        return labels
    }

    private static func validateBranchLabels(
        in commands: [CompiledSedProgramCommand],
        labels: [String: Int]
    ) throws {
        for command in commands {
            switch command.kind {
            case .branch(let label), .branchIfSubstitution(let label):
                if let label, labels[label] == nil {
                    throw MSPPOSIXSedError.usage("sed: undefined label '\(label)'")
                }
            default:
                break
            }
        }
    }
}
