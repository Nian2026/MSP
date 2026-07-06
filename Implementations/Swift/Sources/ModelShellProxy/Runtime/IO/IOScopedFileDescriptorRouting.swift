import Foundation
import MSPShell

struct MSPRedirectionOutputScope {
    var stdout: Bool
    var stderr: Bool
}

struct IOScopedFileDescriptorRoutingScope {
    var touchedFileDescriptors: Set<Int>
    var snapshots: [Int: MSPShellFileDescriptorSnapshot]
}

extension IORuntimeState {
    mutating func beginScopedFileDescriptorRouting(
        _ routing: MSPRedirectionRouting,
        touchedFileDescriptors: Set<Int>,
        standardInput: Data
    ) -> IOScopedFileDescriptorRoutingScope? {
        guard !touchedFileDescriptors.isEmpty else {
            return nil
        }

        let snapshots = Dictionary(
            uniqueKeysWithValues: touchedFileDescriptors.map { fd in
                (fd, fileDescriptorSnapshot(for: fd, standardInput: standardInput))
            }
        )

        persistentOutputFileDescriptors = routing.outputFileDescriptors
        persistentInputFileDescriptors = routing.inputFileDescriptors
        persistentClosedInputFileDescriptors = routing.closedInputFileDescriptors
        if touchedFileDescriptors.contains(1) {
            persistentStdoutBinding = scopedOutputBinding(routing.stdoutBinding)
        }
        if touchedFileDescriptors.contains(2) {
            persistentStderrBinding = scopedOutputBinding(routing.stderrBinding)
        }

        return IOScopedFileDescriptorRoutingScope(
            touchedFileDescriptors: touchedFileDescriptors,
            snapshots: snapshots
        )
    }

    mutating func endScopedFileDescriptorRouting(
        _ scope: IOScopedFileDescriptorRoutingScope,
        standardInput: inout Data
    ) {
        for fd in scope.touchedFileDescriptors {
            if let snapshot = scope.snapshots[fd] {
                restoreFileDescriptor(fd, snapshot: snapshot, standardInput: &standardInput)
            }
        }
    }

    static func redirectionOutputScope(
        for redirections: [MSPParsedRedirection],
        stdoutBindingOverride: MSPRedirectionOutputBinding? = nil,
        stderrBindingOverride: MSPRedirectionOutputBinding? = nil
    ) -> MSPRedirectionOutputScope {
        var scope = MSPRedirectionOutputScope(
            stdout: stdoutBindingOverride != nil,
            stderr: stderrBindingOverride != nil
        )

        for redirection in redirections {
            switch redirection.operation {
            case .output, .appendOutput:
                switch redirection.fd ?? 1 {
                case 1:
                    scope.stdout = true
                case 2:
                    scope.stderr = true
                default:
                    break
                }
            case .outputBoth, .appendOutputBoth:
                scope.stdout = true
                scope.stderr = true
            case .duplicateOutput:
                if redirection.fd == nil,
                   redirection.target != "-",
                   descriptorNumber(from: redirection.target) == nil {
                    scope.stdout = true
                    scope.stderr = true
                } else {
                    switch redirection.fd ?? 1 {
                    case 1:
                        scope.stdout = true
                    case 2:
                        scope.stderr = true
                    default:
                        break
                    }
                }
            case .readWrite:
                switch redirection.fd ?? 0 {
                case 1:
                    scope.stdout = true
                case 2:
                    scope.stderr = true
                default:
                    break
                }
            case .input, .duplicateInput, .hereDocument, .hereString, .unsupported:
                break
            }
        }

        return scope
    }

    static func redirectionTouchedFileDescriptors(_ redirections: [MSPParsedRedirection]) -> Set<Int> {
        var descriptors = Set<Int>()
        for redirection in redirections {
            switch redirection.operation {
            case .input, .duplicateInput, .readWrite, .hereDocument, .hereString:
                descriptors.insert(redirection.fd ?? 0)
            case .output, .appendOutput:
                descriptors.insert(redirection.fd ?? 1)
            case .outputBoth, .appendOutputBoth:
                descriptors.insert(1)
                descriptors.insert(2)
            case .duplicateOutput:
                if redirection.fd == nil,
                   redirection.target != "-",
                   descriptorNumber(from: redirection.target) == nil {
                    descriptors.insert(1)
                    descriptors.insert(2)
                } else {
                    descriptors.insert(redirection.fd ?? 1)
                }
            case .unsupported:
                break
            }
        }
        return descriptors
    }

    static func redirectionsScopeStandardInput(_ redirections: [MSPParsedRedirection]) -> Bool {
        redirections.contains { redirection in
            switch redirection.operation {
            case .input, .duplicateInput, .readWrite, .hereDocument, .hereString:
                return redirection.fd == nil || redirection.fd == 0
            case .output, .appendOutput, .outputBoth, .appendOutputBoth, .duplicateOutput, .unsupported:
                return false
            }
        }
    }
}
