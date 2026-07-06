import Foundation

enum IORuntimeFailure: Error {
    case badFileDescriptor(String)
}

struct IORuntimeState {
    var persistentStdoutBinding: MSPRedirectionOutputBinding = .agentStdout
    var persistentStderrBinding: MSPRedirectionOutputBinding = .agentStderr
    var persistentOutputFileDescriptors: [Int: MSPRedirectionOutputBinding] = [:]
    var persistentInputFileDescriptors: [Int: Int] = [:]
    var persistentClosedInputFileDescriptors: Set<Int> = []
    var inputOpenFileDescriptions: [Int: MSPShellInputOpenFileDescription] = [:]
    var nextInputOpenFileID = 1
    var processSubstitutionTemporaryPaths: [String] = []
    var outputProcessSubstitutions: [String: MSPOutputProcessSubstitution] = [:]

    func fileDescriptorSnapshot(
        for fd: Int,
        standardInput: Data
    ) -> MSPShellFileDescriptorSnapshot {
        let outputBinding: MSPRedirectionOutputBinding?
        switch fd {
        case 1:
            outputBinding = persistentStdoutBinding
        case 2:
            outputBinding = persistentStderrBinding
        default:
            outputBinding = persistentOutputFileDescriptors[fd]
        }

        return MSPShellFileDescriptorSnapshot(
            inputDescriptionID: persistentInputFileDescriptors[fd],
            outputBinding: outputBinding,
            inputClosed: persistentClosedInputFileDescriptors.contains(fd),
            standardInput: fd == 0 ? standardInput : nil
        )
    }

    mutating func restoreFileDescriptor(
        _ fd: Int,
        snapshot: MSPShellFileDescriptorSnapshot,
        standardInput: inout Data
    ) {
        if let inputDescriptionID = snapshot.inputDescriptionID {
            persistentInputFileDescriptors[fd] = inputDescriptionID
        } else {
            persistentInputFileDescriptors.removeValue(forKey: fd)
        }

        if snapshot.inputClosed {
            persistentClosedInputFileDescriptors.insert(fd)
        } else {
            persistentClosedInputFileDescriptors.remove(fd)
        }

        switch fd {
        case 1:
            persistentStdoutBinding = snapshot.outputBinding ?? .agentStdout
        case 2:
            persistentStderrBinding = snapshot.outputBinding ?? .agentStderr
        default:
            if let outputBinding = snapshot.outputBinding {
                persistentOutputFileDescriptors[fd] = outputBinding
            } else {
                persistentOutputFileDescriptors.removeValue(forKey: fd)
            }
        }

        if fd == 0 {
            standardInput = snapshot.standardInput ?? Data()
        }
    }

    func scopedOutputBinding(_ binding: MSPRedirectionOutputBinding) -> MSPRedirectionOutputBinding {
        switch binding {
        case .file(let sink):
            return .file(MSPRedirectionFileSink(path: sink.path, append: true))
        case .agentStdout, .agentStderr, .closed, .discard, .openFileDescription:
            return binding
        }
    }

    var persistentOutputProcessSubstitutionPaths: Set<String> {
        let bindings = [persistentStdoutBinding, persistentStderrBinding]
            + Array(persistentOutputFileDescriptors.values)
        return Set(bindings.compactMap { binding in
            guard case .file(let sink) = binding,
                  outputProcessSubstitutions[sink.path] != nil else {
                return nil
            }
            return sink.path
        })
    }

    mutating func newInputOpenFileDescription(data: Data, virtualPath: String? = nil) -> Int {
        let id = nextInputOpenFileID
        nextInputOpenFileID += 1
        inputOpenFileDescriptions[id] = MSPShellInputOpenFileDescription(
            data: data,
            offset: 0,
            virtualPath: virtualPath
        )
        return id
    }

    func remainingInputData(
        for descriptionID: Int,
        readVirtualPath: (String) throws -> Data
    ) throws -> Data {
        guard let description = inputOpenFileDescriptions[descriptionID] else {
            throw IORuntimeFailure.badFileDescriptor("\(descriptionID): Bad file descriptor")
        }
        let data: Data
        if let virtualPath = description.virtualPath {
            data = try readVirtualPath(virtualPath)
        } else {
            data = description.data
        }
        let offset = min(max(0, description.offset), data.count)
        return data.subdata(in: offset..<data.count)
    }

    mutating func consumeInputOpenFileDescription(id: Int, byteCount: Int) {
        guard var description = inputOpenFileDescriptions[id] else {
            return
        }
        let nextOffset = max(0, description.offset + byteCount)
        if description.virtualPath == nil {
            description.offset = min(description.data.count, nextOffset)
        } else {
            description.offset = nextOffset
        }
        inputOpenFileDescriptions[id] = description
    }
}

struct MSPRedirectionFileSink: Equatable {
    var path: String
    var append: Bool
}

struct MSPOutputProcessSubstitution: Equatable {
    var path: String
    var command: String
}

struct MSPShellInputOpenFileDescription {
    var data: Data
    var offset: Int
    var virtualPath: String?
}

enum MSPRedirectionOutputBinding: Equatable {
    case agentStdout
    case agentStderr
    case file(MSPRedirectionFileSink)
    case openFileDescription(Int)
    case discard
    case closed
}

struct MSPShellFileDescriptorSnapshot {
    var inputDescriptionID: Int?
    var outputBinding: MSPRedirectionOutputBinding?
    var inputClosed: Bool
    var standardInput: Data?
}

struct MSPRedirectionRouting {
    var standardInput: Data
    var standardInputDescriptor: Int?
    var standardInputClosed: Bool = false
    var stdoutBinding: MSPRedirectionOutputBinding = .agentStdout
    var stderrBinding: MSPRedirectionOutputBinding = .agentStderr
    var outputFileDescriptors: [Int: MSPRedirectionOutputBinding] = [:]
    var inputFileDescriptors: [Int: Int] = [:]
    var closedInputFileDescriptors: Set<Int> = []
}
