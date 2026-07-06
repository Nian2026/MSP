import Foundation
import MSPShell

extension IORuntimeState {
    mutating func applyRedirections(
        _ redirections: [MSPParsedRedirection],
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
        stdoutBindingOverride: MSPRedirectionOutputBinding? = nil,
        stderrBindingOverride: MSPRedirectionOutputBinding? = nil,
        environment: IORedirectionEnvironment
    ) throws -> MSPRedirectionRouting {
        var inheritedInputFileDescriptors = persistentInputFileDescriptors
        var inheritedClosedInputFileDescriptors = persistentClosedInputFileDescriptors
        let inheritedInput: IORedirectionInputResolution
        if standardInputOverridesFileDescriptor {
            inheritedInputFileDescriptors.removeValue(forKey: 0)
            inheritedClosedInputFileDescriptors.remove(0)
            inheritedInput = IORedirectionInputResolution(
                data: standardInput,
                descriptionID: nil,
                isClosed: standardInputClosed
            )
        } else {
            inheritedInput = try standardInputForFileDescriptor(
                0,
                fallback: standardInput,
                fallbackClosed: standardInputClosed,
                inputFileDescriptors: persistentInputFileDescriptors,
                closedInputFileDescriptors: persistentClosedInputFileDescriptors,
                environment: environment
            )
        }
        var routing = MSPRedirectionRouting(
            standardInput: inheritedInput.data,
            standardInputDescriptor: inheritedInput.descriptionID,
            standardInputClosed: inheritedInput.isClosed,
            stdoutBinding: stdoutBindingOverride ?? persistentStdoutBinding,
            stderrBinding: stderrBindingOverride ?? persistentStderrBinding,
            outputFileDescriptors: persistentOutputFileDescriptors,
            inputFileDescriptors: inheritedInputFileDescriptors,
            closedInputFileDescriptors: inheritedClosedInputFileDescriptors
        )
        for redirection in redirections {
            switch redirection.operation {
            case .input:
                let descriptorID = newInputOpenFileDescription(data: try environment.readInput(redirection.target))
                bindInputDescriptor(descriptorID, to: redirection.fd ?? 0, routing: &routing, environment: environment)
            case .hereDocument:
                let descriptorID = newInputOpenFileDescription(data: Data((redirection.hereDocumentBody ?? "").utf8))
                bindInputDescriptor(descriptorID, to: redirection.fd ?? 0, routing: &routing, environment: environment)
            case .hereString:
                let descriptorID = newInputOpenFileDescription(data: Data((redirection.target + "\n").utf8))
                bindInputDescriptor(descriptorID, to: redirection.fd ?? 0, routing: &routing, environment: environment)
            case .output:
                try routeOutput(fd: redirection.fd, path: redirection.target, append: false, routing: &routing, environment: environment)
            case .appendOutput:
                try routeOutput(fd: redirection.fd, path: redirection.target, append: true, routing: &routing, environment: environment)
            case .outputBoth:
                let binding = try makeOutputBinding(path: redirection.target, append: false, routing: routing, environment: environment)
                routing.stdoutBinding = binding
                routing.stderrBinding = binding
            case .appendOutputBoth:
                let binding = try makeOutputBinding(path: redirection.target, append: true, routing: routing, environment: environment)
                routing.stdoutBinding = binding
                routing.stderrBinding = binding
            case .duplicateOutput:
                try routeDuplicateOutput(fd: redirection.fd, target: redirection.target, routing: &routing, environment: environment)
            case .duplicateInput:
                try routeDuplicateInput(fd: redirection.fd, target: redirection.target, routing: &routing, environment: environment)
            case .readWrite:
                try routeReadWrite(fd: redirection.fd, path: redirection.target, routing: &routing, environment: environment)
            case .unsupported(let operation):
                throw environment.redirectionFailure("\(operation): redirection is not supported")
            }
        }
        return routing
    }
}

private extension IORuntimeState {
    mutating func routeOutput(
        fd: Int?,
        path: String,
        append: Bool,
        routing: inout MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws {
        let targetFD = fd ?? 1
        let binding = try makeOutputBinding(path: path, append: append, routing: routing, environment: environment)
        switch targetFD {
        case 1:
            routing.stdoutBinding = binding
        case 2:
            routing.stderrBinding = binding
        default:
            routing.outputFileDescriptors[targetFD] = binding
        }
        routing.inputFileDescriptors.removeValue(forKey: targetFD)
        routing.closedInputFileDescriptors.remove(targetFD)
    }

    mutating func routeDuplicateOutput(
        fd: Int?,
        target: String,
        routing: inout MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws {
        let sourceFD = fd ?? 1
        let binding: MSPRedirectionOutputBinding
        if target == "-" {
            binding = .closed
        } else if let targetFD = Self.descriptorNumber(from: target) {
            binding = try outputBinding(for: targetFD, routing: routing, environment: environment)
        } else if fd == nil {
            let fileBinding = try makeOutputBinding(path: target, append: false, routing: routing, environment: environment)
            routing.stdoutBinding = fileBinding
            routing.stderrBinding = fileBinding
            return
        } else {
            throw environment.redirectionFailure("\(target): Bad file descriptor")
        }
        routing.inputFileDescriptors.removeValue(forKey: sourceFD)
        routing.closedInputFileDescriptors.remove(sourceFD)
        try setOutputBinding(binding, for: sourceFD, routing: &routing, environment: environment)
    }

    mutating func routeDuplicateInput(
        fd: Int?,
        target: String,
        routing: inout MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws {
        let sourceFD = fd ?? 0
        if target == "-" {
            closeInputDescriptor(sourceFD, routing: &routing)
            return
        }
        guard let targetFD = Self.descriptorNumber(from: target) else {
            throw environment.redirectionFailure("\(target): Bad file descriptor")
        }
        let resolved = try standardInputForFileDescriptor(
            targetFD,
            fallback: routing.standardInput,
            fallbackClosed: routing.standardInputClosed,
            inputFileDescriptors: routing.inputFileDescriptors,
            closedInputFileDescriptors: routing.closedInputFileDescriptors,
            environment: environment
        )
        guard let descriptorID = resolved.descriptionID else {
            guard !resolved.isClosed else {
                throw environment.redirectionFailure("\(target): Bad file descriptor")
            }
            if targetFD == 0 {
                let descriptorID = newInputOpenFileDescription(data: routing.standardInput)
                bindInputDescriptor(descriptorID, to: sourceFD, routing: &routing, environment: environment)
                return
            }
            throw environment.redirectionFailure("\(target): Bad file descriptor")
        }
        bindInputDescriptor(descriptorID, to: sourceFD, routing: &routing, environment: environment)
        if let targetOutputBinding = try? outputBinding(for: targetFD, routing: routing, environment: environment),
           case .openFileDescription(let outputDescriptionID) = targetOutputBinding {
            try setOutputBinding(.openFileDescription(outputDescriptionID), for: sourceFD, routing: &routing, environment: environment)
        }
    }

    mutating func routeReadWrite(
        fd: Int?,
        path: String,
        routing: inout MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws {
        let sourceFD = fd ?? 0
        let file = try environment.openReadWriteFile(path)
        let descriptorID = newInputOpenFileDescription(data: file.data, virtualPath: file.virtualPath)
        bindInputDescriptor(descriptorID, to: sourceFD, routing: &routing, environment: environment)
        try setOutputBinding(.openFileDescription(descriptorID), for: sourceFD, routing: &routing, environment: environment)
    }

    func outputBinding(
        for fd: Int,
        routing: MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws -> MSPRedirectionOutputBinding {
        switch fd {
        case 1:
            return routing.stdoutBinding
        case 2:
            return routing.stderrBinding
        default:
            guard let binding = routing.outputFileDescriptors[fd] else {
                throw environment.redirectionFailure("\(fd): Bad file descriptor")
            }
            return binding
        }
    }

    func setOutputBinding(
        _ binding: MSPRedirectionOutputBinding,
        for fd: Int,
        routing: inout MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws {
        switch fd {
        case 1:
            routing.stdoutBinding = binding
            if binding == .closed {
                routing.inputFileDescriptors.removeValue(forKey: fd)
                routing.closedInputFileDescriptors.insert(fd)
            } else if case .openFileDescription(let descriptionID) = binding {
                routing.inputFileDescriptors[fd] = descriptionID
                routing.closedInputFileDescriptors.remove(fd)
            }
        case 2:
            routing.stderrBinding = binding
            if binding == .closed {
                routing.inputFileDescriptors.removeValue(forKey: fd)
                routing.closedInputFileDescriptors.insert(fd)
            } else if case .openFileDescription(let descriptionID) = binding {
                routing.inputFileDescriptors[fd] = descriptionID
                routing.closedInputFileDescriptors.remove(fd)
            }
        default:
            if binding == .closed {
                routing.outputFileDescriptors.removeValue(forKey: fd)
                closeInputDescriptor(fd, routing: &routing)
            } else {
                routing.closedInputFileDescriptors.remove(fd)
                routing.outputFileDescriptors[fd] = binding
                if case .openFileDescription(let descriptionID) = binding {
                    routing.inputFileDescriptors[fd] = descriptionID
                    if fd == 0 {
                        routing.standardInput = (try? remainingInputData(for: descriptionID, environment: environment)) ?? Data()
                        routing.standardInputDescriptor = descriptionID
                    }
                }
            }
        }
    }

    func makeOutputBinding(
        path: String,
        append: Bool,
        routing: MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) throws -> MSPRedirectionOutputBinding {
        switch path {
        case "/dev/stdout":
            return routing.stdoutBinding
        case "/dev/stderr":
            return routing.stderrBinding
        case "/dev/null":
            return .discard
        default:
            return .file(try environment.makeOutputSink(path, append))
        }
    }

    mutating func bindInputDescriptor(
        _ descriptionID: Int,
        to fd: Int,
        routing: inout MSPRedirectionRouting,
        environment: IORedirectionEnvironment
    ) {
        routing.inputFileDescriptors[fd] = descriptionID
        routing.closedInputFileDescriptors.remove(fd)
        routing.outputFileDescriptors.removeValue(forKey: fd)
        if fd == 0 {
            routing.standardInput = (try? remainingInputData(for: descriptionID, environment: environment)) ?? Data()
            routing.standardInputDescriptor = descriptionID
            routing.standardInputClosed = false
        }
    }

    func closeInputDescriptor(_ fd: Int, routing: inout MSPRedirectionRouting) {
        routing.inputFileDescriptors.removeValue(forKey: fd)
        routing.closedInputFileDescriptors.insert(fd)
        routing.outputFileDescriptors.removeValue(forKey: fd)
        if fd == 0 {
            routing.standardInput = Data()
            routing.standardInputDescriptor = nil
            routing.standardInputClosed = true
        } else if fd == 1 {
            routing.stdoutBinding = .closed
        } else if fd == 2 {
            routing.stderrBinding = .closed
        }
    }
}
