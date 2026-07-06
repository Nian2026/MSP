import Foundation
import MSPCore

public struct MSPFindCommand: MSPStreamingCommand {
    public let name = "find"
    public let summary: String? = "Search workspace paths."
    private static let directoryBatchSize = 1024

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let query = try FindQuery(arguments: invocation.arguments)
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let output = FindBufferedOutputWriter()
        return try await run(
            query: query,
            fileSystem: fileSystem,
            currentDirectory: context.currentDirectory,
            commandContext: context,
            output: output
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }
        let query = try FindQuery(arguments: invocation.arguments)
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let output = FindStreamingOutputWriter(
            standardOutput: standardOutput,
            standardError: context.standardErrorStream ?? MSPBlackHoleOutputStream()
        )
        return try await run(
            query: query,
            fileSystem: fileSystem,
            currentDirectory: context.currentDirectory,
            commandContext: context,
            output: output
        )
    }

    private func run(
        query: FindQuery,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String,
        commandContext context: MSPCommandContext,
        output: any FindOutputWriter
    ) async throws -> MSPCommandResult {
        let runtimeContext = try runtimePredicateContext(
            for: query,
            fileSystem: fileSystem,
            currentDirectory: currentDirectory
        )
        var exitCode: Int32 = 0
        var batchActions: [FindBatchAction] = []
        var shouldQuit = false

        for path in query.paths {
            do {
                let resolved = try fileSystem.resolve(path, from: context.currentDirectory)
                let info = try fileSystem.stat(resolved.virtualPath, from: "/")
                let displayBasePath = displayBasePath(
                    rawPath: path,
                    resolvedPath: resolved.virtualPath
                )
                shouldQuit = try await visit(
                    info,
                    depth: 0,
                    basePath: resolved.virtualPath,
                    displayBasePath: displayBasePath,
                    query: query,
                    runtimeContext: runtimeContext,
                    fileSystem: fileSystem,
                    commandContext: context,
                    output: output,
                    batchActions: &batchActions,
                    exitCode: &exitCode
                )
            } catch MSPCommandStreamError.brokenPipe {
                return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
            } catch {
                exitCode = 1
                let displayPath = MSPPOSIXCommandSupport.displayPath(path)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                try await output.appendDiagnostic("find: \(mspPOSIXFindQuote(displayPath)): \(reason)")
            }
            if shouldQuit {
                break
            }
        }

        try await flushBatchActions(
            &batchActions,
            commandContext: context,
            output: output,
            exitCode: &exitCode,
            flushAll: true
        )

        do {
            try await output.flush()
        } catch MSPCommandStreamError.brokenPipe {
            return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
        }

        if exitCode != 0 {
            return .failure(
                exitCode: exitCode,
                stdoutData: await output.stdoutData,
                stderr: await output.stderr
            )
        }
        return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
    }

    private func runtimePredicateContext(
        for query: FindQuery,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> FindRuntimePredicateContext {
        var newerReferenceDates: [String: Date] = [:]
        for path in query.newerReferencePaths where newerReferenceDates[path] == nil {
            do {
                let resolved = try fileSystem.resolve(path, from: currentDirectory)
                let info = try fileSystem.stat(resolved.virtualPath, from: "/")
                newerReferenceDates[path] = info.modificationDate ?? Date(timeIntervalSince1970: 0)
            } catch {
                throw MSPCommandFailure(
                    result: .failure(
                        exitCode: 1,
                        stderr: "find: \(mspPOSIXFindQuote(MSPPOSIXCommandSupport.displayPath(path))): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                    )
                )
            }
        }
        return FindRuntimePredicateContext(newerReferenceDates: newerReferenceDates)
    }

    private func visit(
        _ info: MSPFileInfo,
        depth: Int,
        basePath: String,
        displayBasePath: String,
        query: FindQuery,
        runtimeContext: FindRuntimePredicateContext,
        fileSystem: any MSPWorkspaceFileSystem,
        commandContext: MSPCommandContext,
        output: any FindOutputWriter,
        batchActions: inout [FindBatchAction],
        exitCode: inout Int32
    ) async throws -> Bool {
        let displayPath = displayPath(
            for: info.virtualPath,
            basePath: basePath,
            displayBasePath: displayBasePath
        )

        if !query.requiresDepthFirstTraversal {
            let evaluation = try await evaluateItem(
                info,
                displayPath: displayPath,
                depth: depth,
                basePath: basePath,
                displayBasePath: displayBasePath,
                query: query,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext,
                output: output,
                batchActions: &batchActions,
                exitCode: &exitCode
            )
            if evaluation.quits {
                return true
            }
            guard !evaluation.prunes else {
                return false
            }
        }

        if query.requiresDepthFirstTraversal, info.type != .directory {
            let evaluation = try await evaluateItem(
                info,
                displayPath: displayPath,
                depth: depth,
                basePath: basePath,
                displayBasePath: displayBasePath,
                query: query,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext,
                output: output,
                batchActions: &batchActions,
                exitCode: &exitCode
            )
            return evaluation.quits
        }

        guard info.type == .directory else {
            return false
        }
        if let maxDepth = query.maxDepth, depth >= maxDepth {
            guard query.requiresDepthFirstTraversal else {
                return false
            }
            let evaluation = try await evaluateItem(
                info,
                displayPath: displayPath,
                depth: depth,
                basePath: basePath,
                displayBasePath: displayBasePath,
                query: query,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext,
                output: output,
                batchActions: &batchActions,
                exitCode: &exitCode
            )
            return evaluation.quits
        }

        var shouldQuit = false
        do {
            let options = query.childEnumerationOptions(forChildDepth: depth + 1)
            if !query.requiresDepthFirstTraversal,
               try await visitLeafDirectoryChildrenInBatchesIfPossible(
                info.virtualPath,
                childDepth: depth + 1,
                basePath: basePath,
                displayBasePath: displayBasePath,
                query: query,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                output: output,
                options: options
            ) {
                return false
            }
            try await enumerateDirectory(
                info.virtualPath,
                fileSystem: fileSystem,
                options: options
            ) { entry in
                let childShouldQuit = try await visit(
                    entry.info,
                    depth: depth + 1,
                    basePath: basePath,
                    displayBasePath: displayBasePath,
                    query: query,
                    runtimeContext: runtimeContext,
                    fileSystem: fileSystem,
                    commandContext: commandContext,
                    output: output,
                    batchActions: &batchActions,
                    exitCode: &exitCode
                )
                if childShouldQuit {
                    shouldQuit = true
                    return false
                }
                return true
            }
        } catch MSPCommandStreamError.brokenPipe {
            throw MSPCommandStreamError.brokenPipe
        } catch {
            if exitCode == 0 {
                exitCode = 1
            }
            let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
            try await output.appendDiagnostic("find: \(mspPOSIXFindQuote(displayPath)): \(reason)")
            return false
        }
        if shouldQuit {
            return true
        }
        guard query.requiresDepthFirstTraversal else {
            return false
        }
        let evaluation = try await evaluateItem(
            info,
            displayPath: displayPath,
            depth: depth,
            basePath: basePath,
            displayBasePath: displayBasePath,
            query: query,
            runtimeContext: runtimeContext,
            fileSystem: fileSystem,
            commandContext: commandContext,
            output: output,
            batchActions: &batchActions,
            exitCode: &exitCode
        )
        return evaluation.quits
    }

    private func evaluateItem(
        _ info: MSPFileInfo,
        displayPath: String,
        depth: Int,
        basePath: String,
        displayBasePath: String,
        query: FindQuery,
        runtimeContext: FindRuntimePredicateContext,
        fileSystem: any MSPWorkspaceFileSystem,
        commandContext: MSPCommandContext,
        output: any FindOutputWriter,
        batchActions: inout [FindBatchAction],
        exitCode: inout Int32
    ) async throws -> FindEvaluation {
        let aboveMinDepth = query.minDepth.map { depth >= $0 } ?? true
        let withinMaxDepth = query.maxDepth.map { depth <= $0 } ?? true
        let shouldEmitActions = aboveMinDepth && withinMaxDepth
        let expressionResult = await query.expression.evaluate(
            item: FindItem(
                info: info,
                displayPath: displayPath,
                basePath: basePath,
                displayBasePath: displayBasePath,
                depth: depth
            ),
            emitActions: shouldEmitActions,
            runtimeContext: runtimeContext,
            fileSystem: fileSystem,
            commandContext: commandContext
        )
        try await output.appendStdout(expressionResult.stdout)
        try await output.appendStderr(expressionResult.stderr)
        appendBatchActions(expressionResult.batchActions, to: &batchActions)
        if expressionResult.exitCode != 0, exitCode == 0 {
            exitCode = expressionResult.exitCode
        }
        try await flushBatchActions(
            &batchActions,
            commandContext: commandContext,
            output: output,
            exitCode: &exitCode,
            flushAll: false
        )

        if shouldEmitActions, !query.hasExplicitAction, expressionResult.evaluation.matches {
            try await output.appendStdout(displayPath + "\n")
        }
        return expressionResult.evaluation
    }

    private func visitLeafDirectoryChildrenInBatchesIfPossible(
        _ path: String,
        childDepth: Int,
        basePath: String,
        displayBasePath: String,
        query: FindQuery,
        runtimeContext: FindRuntimePredicateContext,
        fileSystem: any MSPWorkspaceFileSystem,
        output: any FindOutputWriter,
        options: MSPDirectoryEnumerationOptions?
    ) async throws -> Bool {
        guard let maxDepth = query.maxDepth,
              childDepth >= maxDepth,
              query.expression.supportsSynchronousLeafBatchEvaluation,
              let batchFileSystem = fileSystem as? any MSPWorkspaceBatchDirectoryEnumerating
        else {
            return false
        }

        try await batchFileSystem.enumerateDirectoryBatches(
            path,
            from: "/",
            options: options ?? .all,
            batchSize: Self.directoryBatchSize
        ) { entries in
            var stdout = ""
            var stderr = ""
            for entry in entries {
                let displayPath = displayPath(
                    for: entry.info.virtualPath,
                    basePath: basePath,
                    displayBasePath: displayBasePath
                )
                let aboveMinDepth = query.minDepth.map { childDepth >= $0 } ?? true
                let withinMaxDepth = query.maxDepth.map { childDepth <= $0 } ?? true
                let shouldEmitActions = aboveMinDepth && withinMaxDepth
                let expressionResult = query.expression.evaluateSynchronously(
                    item: FindItem(
                        info: entry.info,
                        displayPath: displayPath,
                        basePath: basePath,
                        displayBasePath: displayBasePath,
                        depth: childDepth
                    ),
                    emitActions: shouldEmitActions,
                    runtimeContext: runtimeContext
                )
                stdout += expressionResult.stdout
                stderr += expressionResult.stderr
                if shouldEmitActions, !query.hasExplicitAction, expressionResult.evaluation.matches {
                    stdout += displayPath + "\n"
                }
            }
            if !stdout.isEmpty {
                try await output.appendStdout(stdout)
            }
            if !stderr.isEmpty {
                try await output.appendStderr(stderr)
            }
            return true
        }
        return true
    }

    private func enumerateDirectory(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        options: MSPDirectoryEnumerationOptions?,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        if let options,
           let typedFileSystem = fileSystem as? any MSPWorkspaceTypedDirectoryEnumerating {
            try await typedFileSystem.enumerateDirectory(
                path,
                from: "/",
                options: options,
                visitor: visitor
            )
            return
        }
        try await fileSystem.enumerateDirectory(path, from: "/", visitor: visitor)
    }

    private func displayBasePath(rawPath: String, resolvedPath: String) -> String {
        guard !rawPath.hasPrefix("/") else {
            return resolvedPath
        }
        var display = rawPath.isEmpty ? "." : rawPath
        while display.count > 1, display.hasSuffix("/") {
            display.removeLast()
        }
        return display.isEmpty ? "." : display
    }

    private func displayPath(
        for virtualPath: String,
        basePath: String,
        displayBasePath: String
    ) -> String {
        guard virtualPath != basePath else {
            return displayBasePath
        }
        let baseComponents = MSPWorkspacePathResolver.components(in: basePath)
        let itemComponents = MSPWorkspacePathResolver.components(in: virtualPath)
        let relativeComponents = itemComponents.dropFirst(baseComponents.count)
        let relative = relativeComponents.joined(separator: "/")
        if displayBasePath == "/" {
            return "/" + relative
        }
        return displayBasePath + "/" + relative
    }
}
