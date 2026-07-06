import Foundation
import MSPShell

extension IORuntimeState {
    mutating func applyPersistentExecRedirections(
        _ redirections: [MSPParsedRedirection],
        standardInput: inout Data,
        standardInputClosed: inout Bool,
        environment: IORedirectionEnvironment
    ) throws {
        for redirection in redirections {
            switch redirection.operation {
            case .input:
                let descriptorID = newInputOpenFileDescription(data: try environment.readInput(redirection.target))
                setPersistentInputDescriptor(
                    descriptorID,
                    for: redirection.fd ?? 0,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed,
                    environment: environment
                )
            case .hereDocument:
                let descriptorID = newInputOpenFileDescription(data: Data((redirection.hereDocumentBody ?? "").utf8))
                setPersistentInputDescriptor(
                    descriptorID,
                    for: redirection.fd ?? 0,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed,
                    environment: environment
                )
            case .hereString:
                let descriptorID = newInputOpenFileDescription(data: Data((redirection.target + "\n").utf8))
                setPersistentInputDescriptor(
                    descriptorID,
                    for: redirection.fd ?? 0,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed,
                    environment: environment
                )
            case .readWrite:
                let fd = redirection.fd ?? 0
                let file = try environment.openReadWriteFile(redirection.target)
                let descriptorID = newInputOpenFileDescription(data: file.data, virtualPath: file.virtualPath)
                setPersistentInputDescriptor(
                    descriptorID,
                    for: fd,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed,
                    environment: environment
                )
                try setPersistentOutputBinding(
                    .openFileDescription(descriptorID),
                    for: fd,
                    standardInput: &standardInput,
                    environment: environment
                )
            case .duplicateInput:
                let fd = redirection.fd ?? 0
                if redirection.target == "-" {
                    closePersistentInputDescriptor(
                        fd,
                        standardInput: &standardInput,
                        standardInputClosed: &standardInputClosed
                    )
                } else if let targetFD = Self.descriptorNumber(from: redirection.target) {
                    let resolved = try standardInputForFileDescriptor(
                        targetFD,
                        fallback: standardInput,
                        fallbackClosed: standardInputClosed,
                        inputFileDescriptors: persistentInputFileDescriptors,
                        closedInputFileDescriptors: persistentClosedInputFileDescriptors,
                        environment: environment
                    )
                    guard let descriptorID = resolved.descriptionID else {
                        guard !resolved.isClosed else {
                            throw environment.redirectionFailure("\(redirection.target): Bad file descriptor")
                        }
                        if targetFD == 0 {
                            setPersistentInputDescriptor(
                                newInputOpenFileDescription(data: standardInput),
                                for: fd,
                                standardInput: &standardInput,
                                standardInputClosed: &standardInputClosed,
                                environment: environment
                            )
                            break
                        }
                        throw environment.redirectionFailure("\(redirection.target): Bad file descriptor")
                    }
                    setPersistentInputDescriptor(
                        descriptorID,
                        for: fd,
                        standardInput: &standardInput,
                        standardInputClosed: &standardInputClosed,
                        environment: environment
                    )
                    if let targetOutputBinding = try? persistentOutputBinding(for: targetFD, environment: environment),
                       case .openFileDescription(let outputDescriptionID) = targetOutputBinding {
                        try setPersistentOutputBinding(
                            .openFileDescription(outputDescriptionID),
                            for: fd,
                            standardInput: &standardInput,
                            environment: environment
                        )
                    }
                } else {
                    throw environment.redirectionFailure("\(redirection.target): Bad file descriptor")
                }
            case .output:
                clearPersistentInputDescriptor(
                    redirection.fd ?? 1,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed
                )
                try setPersistentOutputBinding(
                    try makePersistentOutputBinding(path: redirection.target, append: false, environment: environment),
                    for: redirection.fd ?? 1,
                    standardInput: &standardInput,
                    environment: environment
                )
            case .appendOutput:
                clearPersistentInputDescriptor(
                    redirection.fd ?? 1,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed
                )
                try setPersistentOutputBinding(
                    try makePersistentOutputBinding(path: redirection.target, append: true, environment: environment),
                    for: redirection.fd ?? 1,
                    standardInput: &standardInput,
                    environment: environment
                )
            case .outputBoth:
                let binding = try makePersistentOutputBinding(path: redirection.target, append: false, environment: environment)
                clearPersistentInputDescriptor(1, standardInput: &standardInput, standardInputClosed: &standardInputClosed)
                clearPersistentInputDescriptor(2, standardInput: &standardInput, standardInputClosed: &standardInputClosed)
                persistentStdoutBinding = binding
                persistentStderrBinding = binding
            case .appendOutputBoth:
                let binding = try makePersistentOutputBinding(path: redirection.target, append: true, environment: environment)
                clearPersistentInputDescriptor(1, standardInput: &standardInput, standardInputClosed: &standardInputClosed)
                clearPersistentInputDescriptor(2, standardInput: &standardInput, standardInputClosed: &standardInputClosed)
                persistentStdoutBinding = binding
                persistentStderrBinding = binding
            case .duplicateOutput:
                try applyPersistentDuplicateOutput(
                    redirection,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed,
                    environment: environment
                )
            case .unsupported(let operation):
                throw environment.redirectionFailure("\(operation): redirection is not supported")
            }
        }
    }
}

private extension IORuntimeState {
    mutating func applyPersistentDuplicateOutput(
        _ redirection: MSPParsedRedirection,
        standardInput: inout Data,
        standardInputClosed: inout Bool,
        environment: IORedirectionEnvironment
    ) throws {
        let fd = redirection.fd ?? 1
        if redirection.target == "-" {
            try setPersistentOutputBinding(
                .closed,
                for: fd,
                standardInput: &standardInput,
                environment: environment
            )
            return
        }
        if let targetFD = Self.descriptorNumber(from: redirection.target) {
            clearPersistentInputDescriptor(
                fd,
                standardInput: &standardInput,
                standardInputClosed: &standardInputClosed
            )
            try setPersistentOutputBinding(
                try persistentOutputBinding(for: targetFD, environment: environment),
                for: fd,
                standardInput: &standardInput,
                environment: environment
            )
            return
        }
        guard redirection.fd == nil else {
            throw environment.redirectionFailure("\(redirection.target): Bad file descriptor")
        }
        let binding = try makePersistentOutputBinding(path: redirection.target, append: false, environment: environment)
        clearPersistentInputDescriptor(1, standardInput: &standardInput, standardInputClosed: &standardInputClosed)
        clearPersistentInputDescriptor(2, standardInput: &standardInput, standardInputClosed: &standardInputClosed)
        persistentStdoutBinding = binding
        persistentStderrBinding = binding
    }

    func persistentOutputBinding(
        for fd: Int,
        environment: IORedirectionEnvironment
    ) throws -> MSPRedirectionOutputBinding {
        switch fd {
        case 1:
            return persistentStdoutBinding
        case 2:
            return persistentStderrBinding
        default:
            guard let binding = persistentOutputFileDescriptors[fd] else {
                throw environment.redirectionFailure("\(fd): Bad file descriptor")
            }
            return binding
        }
    }

    mutating func setPersistentOutputBinding(
        _ binding: MSPRedirectionOutputBinding,
        for fd: Int,
        standardInput: inout Data,
        environment: IORedirectionEnvironment
    ) throws {
        switch fd {
        case 1:
            persistentStdoutBinding = binding
            if binding == .closed {
                persistentInputFileDescriptors.removeValue(forKey: fd)
                persistentClosedInputFileDescriptors.insert(fd)
            } else if case .openFileDescription(let descriptionID) = binding {
                persistentInputFileDescriptors[fd] = descriptionID
                persistentClosedInputFileDescriptors.remove(fd)
            }
        case 2:
            persistentStderrBinding = binding
            if binding == .closed {
                persistentInputFileDescriptors.removeValue(forKey: fd)
                persistentClosedInputFileDescriptors.insert(fd)
            } else if case .openFileDescription(let descriptionID) = binding {
                persistentInputFileDescriptors[fd] = descriptionID
                persistentClosedInputFileDescriptors.remove(fd)
            }
        default:
            if binding == .closed {
                persistentOutputFileDescriptors.removeValue(forKey: fd)
                persistentInputFileDescriptors.removeValue(forKey: fd)
                persistentClosedInputFileDescriptors.insert(fd)
                if fd == 0 {
                    standardInput = Data()
                }
            } else {
                persistentClosedInputFileDescriptors.remove(fd)
                persistentOutputFileDescriptors[fd] = binding
                if case .openFileDescription(let descriptionID) = binding {
                    persistentInputFileDescriptors[fd] = descriptionID
                    if fd == 0 {
                        standardInput = (try? remainingInputData(for: descriptionID, environment: environment)) ?? Data()
                    }
                }
            }
        }
    }

    func makePersistentOutputBinding(
        path: String,
        append: Bool,
        environment: IORedirectionEnvironment
    ) throws -> MSPRedirectionOutputBinding {
        switch path {
        case "/dev/stdout":
            return persistentStdoutBinding
        case "/dev/stderr":
            return persistentStderrBinding
        case "/dev/null":
            return .discard
        default:
            let sink = try environment.makeOutputSink(path, append)
            return .file(MSPRedirectionFileSink(path: sink.path, append: true))
        }
    }

    mutating func setPersistentInputDescriptor(
        _ descriptionID: Int,
        for fd: Int,
        standardInput: inout Data,
        standardInputClosed: inout Bool,
        environment: IORedirectionEnvironment
    ) {
        persistentInputFileDescriptors[fd] = descriptionID
        persistentClosedInputFileDescriptors.remove(fd)
        persistentOutputFileDescriptors.removeValue(forKey: fd)
        if fd == 0 {
            standardInput = (try? remainingInputData(for: descriptionID, environment: environment)) ?? Data()
            standardInputClosed = false
        }
    }

    mutating func clearPersistentInputDescriptor(
        _ fd: Int,
        standardInput: inout Data,
        standardInputClosed: inout Bool
    ) {
        persistentInputFileDescriptors.removeValue(forKey: fd)
        persistentClosedInputFileDescriptors.remove(fd)
        if fd == 0 {
            standardInput = Data()
            standardInputClosed = false
        }
    }

    mutating func closePersistentInputDescriptor(
        _ fd: Int,
        standardInput: inout Data,
        standardInputClosed: inout Bool
    ) {
        persistentInputFileDescriptors.removeValue(forKey: fd)
        persistentClosedInputFileDescriptors.insert(fd)
        if fd == 1 {
            persistentStdoutBinding = .closed
        } else if fd == 2 {
            persistentStderrBinding = .closed
        } else if fd >= 3 {
            persistentOutputFileDescriptors.removeValue(forKey: fd)
        }
        if fd == 0 {
            standardInput = Data()
            standardInputClosed = true
        }
    }
}
