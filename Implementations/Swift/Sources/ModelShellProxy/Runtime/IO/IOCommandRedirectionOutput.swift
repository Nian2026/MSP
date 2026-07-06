import Foundation

extension IORuntimeState {
    mutating func emitRedirectionOutput(
        _ data: Data,
        to binding: MSPRedirectionOutputBinding,
        visibleStdout: inout Data,
        visibleStderr: inout Data,
        writtenFilePaths: inout Set<String>,
        commandName: String? = nil,
        closedReason: String = "Bad file descriptor",
        environment: IORedirectionEnvironment
    ) throws {
        guard !data.isEmpty else {
            return
        }
        switch binding {
        case .agentStdout:
            visibleStdout.append(data)
        case .agentStderr:
            visibleStderr.append(data)
        case .closed:
            let owner = commandName ?? "shell"
            throw environment.commandFailure(1, "\(owner): \(closedReason)\n")
        case .file(let sink):
            let shouldAppend = sink.append || writtenFilePaths.contains(sink.path)
            try environment.writeFileOutput(data, sink.path, shouldAppend)
            writtenFilePaths.insert(sink.path)
        case .openFileDescription(let descriptionID):
            try writeOpenFileDescriptionOutput(data, to: descriptionID, environment: environment)
        case .discard:
            return
        }
    }

    func readCommandInput(
        for fd: Int,
        routing: MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws -> (data: Data, descriptionID: Int?) {
        if fd == 0 {
            if let descriptionID = routing.standardInputDescriptor {
                return (try remainingInputData(for: descriptionID, environment: environment), descriptionID)
            }
            if routing.standardInputClosed {
                throw environment.commandFailure(1, "read: 0: read error: Bad file descriptor\n")
            }
            return (routing.standardInput, nil)
        }
        guard !routing.closedInputFileDescriptors.contains(fd),
              let descriptionID = routing.inputFileDescriptors[fd] else {
            throw environment.commandFailure(
                1,
                "read: \(fd): invalid file descriptor: Bad file descriptor\n"
            )
        }
        return (try remainingInputData(for: descriptionID, environment: environment), descriptionID)
    }
}
