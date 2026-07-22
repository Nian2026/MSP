import Foundation
import MSPCore

public struct MSPInProcessExternalCommandInvocation: Sendable, Equatable {
    public var executableName: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectoryURL: URL
    public var standardInput: Data

    public init(
        executableName: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        standardInput: Data
    ) {
        self.executableName = executableName
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.standardInput = standardInput
    }
}

public protocol MSPInProcessExternalCommandExecutor: Sendable {
    func execute(
        _ invocation: MSPInProcessExternalCommandInvocation
    ) async throws -> MSPCommandResult
}

public struct MSPInProcessExternalCommandRunner: MSPExternalCommandRunner {
    public var executableURL: URL
    public var extraEnvironment: [String: String]
    public var trustedHostEnvironment: [String: String]
    public var runtimePathMappings: [MSPOutputPathSanitizer.Mapping]
    public var versionOutput: String?
    public var executor: any MSPInProcessExternalCommandExecutor

    public init(
        executableURL: URL,
        extraEnvironment: [String: String] = [:],
        trustedHostEnvironment: [String: String] = [:],
        runtimePathMappings: [MSPOutputPathSanitizer.Mapping] = [],
        versionOutput: String? = nil,
        executor: any MSPInProcessExternalCommandExecutor
    ) {
        self.executableURL = executableURL
        self.extraEnvironment = extraEnvironment
        self.trustedHostEnvironment = trustedHostEnvironment
        self.runtimePathMappings = runtimePathMappings
        self.versionOutput = versionOutput
        self.executor = executor
    }

    public func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let pathMapper = MSPExternalCommandPathMapper(
            executableURL: executableURL,
            runtimePathMappings: runtimePathMappings
        )
        let outputSanitizer = try pathMapper.outputSanitizer(context: context)
        if let versionOutput,
           request.arguments.count == 1,
           (request.arguments[0] == "--version" || request.arguments[0] == "-v") {
            return outputSanitizer.sanitize(.success(stdout: versionOutput))
        }

        var environment = try pathMapper.environment(
            request: request,
            extraEnvironment: extraEnvironment,
            context: context
        )
        environment.merge(trustedHostEnvironment) { _, trustedValue in trustedValue }
        let invocation = try MSPInProcessExternalCommandInvocation(
            executableName: request.executableName,
            arguments: pathMapper.arguments(request.arguments, context: context),
            environment: environment,
            workingDirectoryURL: pathMapper.workingDirectoryURL(
                virtualPath: request.workingDirectory,
                context: context
            ),
            standardInput: await bufferedStandardInput(from: context)
        )
        return outputSanitizer.sanitize(try await executor.execute(invocation))
    }

    private func bufferedStandardInput(
        from context: MSPCommandContext
    ) async throws -> Data {
        guard let stream = context.standardInputStream else {
            return context.standardInput
        }
        var data = Data()
        while let chunk = try await stream.read(maxBytes: 32 * 1024) {
            data.append(chunk)
        }
        return data
    }
}
