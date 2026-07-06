import Foundation
import MSPCore
import MSPShell

extension ShellCompoundFunctionRuntime {
    func executeIfCommand(
        branches: [MSPParsedStructuredIfBranch],
        elseBody: MSPParsedCommandList,
        lastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var currentLastExitCode = lastExitCode

        for branch in branches {
            let condition = await runCommandList(
                branch.condition,
                initialLastExitCode: currentLastExitCode,
                suppressesErrexit: true,
                outputStream: outputStream,
                errorStream: errorStream
            )
            appendCompoundOutput(condition, stdout: &stdout, stderr: &stderr)
            currentLastExitCode = condition.exitCode
            if hasPendingShellControl {
                return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: condition.exitCode)
            }
            guard condition.exitCode == 0 else {
                continue
            }

            let body = await runCommandList(
                branch.body,
                initialLastExitCode: currentLastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
            appendCompoundOutput(body, stdout: &stdout, stderr: &stderr)
            return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: body.exitCode)
        }

        guard !elseBody.pipelines.isEmpty else {
            return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
        }
        let body = await runCommandList(
            elseBody,
            initialLastExitCode: currentLastExitCode,
            outputStream: outputStream,
            errorStream: errorStream
        )
        appendCompoundOutput(body, stdout: &stdout, stderr: &stderr)
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: body.exitCode)
    }

    func executeConditionalLoop(
        condition: MSPParsedCommandList,
        body: MSPParsedCommandList,
        loopName: String,
        lastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?,
        shouldRunForConditionExitCode: (Int32) -> Bool
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var finalExitCode: Int32 = 0
        var currentLastExitCode = lastExitCode
        context.setLoopDepth(context.loopDepth() + 1)
        defer { context.setLoopDepth(context.loopDepth() - 1) }

        for _ in 0..<context.compoundLoopIterationLimit {
            let conditionResult = await runCommandList(
                condition,
                initialLastExitCode: currentLastExitCode,
                suppressesErrexit: true,
                outputStream: outputStream,
                errorStream: errorStream
            )
            appendCompoundOutput(conditionResult, stdout: &stdout, stderr: &stderr)
            currentLastExitCode = conditionResult.exitCode
            if context.pendingFunctionReturnCode() != nil || context.pendingShellExitCode() != nil {
                return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: conditionResult.exitCode)
            }
            if let action = consumeLoopControlForCurrentLoop() {
                switch action {
                case .breakLoop:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                case .continueLoop:
                    currentLastExitCode = 0
                    continue
                case .propagate:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                }
            }
            guard shouldRunForConditionExitCode(conditionResult.exitCode) else {
                return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: finalExitCode)
            }

            let bodyResult = await runCommandList(
                body,
                initialLastExitCode: currentLastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
            appendCompoundOutput(bodyResult, stdout: &stdout, stderr: &stderr)
            finalExitCode = bodyResult.exitCode
            currentLastExitCode = bodyResult.exitCode
            if context.pendingFunctionReturnCode() != nil || context.pendingShellExitCode() != nil {
                return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: bodyResult.exitCode)
            }
            if let action = consumeLoopControlForCurrentLoop() {
                switch action {
                case .breakLoop:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                case .continueLoop:
                    finalExitCode = 0
                    currentLastExitCode = 0
                    continue
                case .propagate:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                }
            }
        }

        stderr += "\(loopName): maximum iteration count exceeded\n"
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 124)
    }

    func executeWhileRead(
        spec: MSPParsedReadSpec,
        body: MSPParsedCommandList,
        lastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var finalExitCode: Int32 = 0
        var currentLastExitCode = lastExitCode
        let inputDescriptionID = context.persistentInputFileDescriptor(0)
        let inputData: Data
        if let inputDescriptionID {
            do {
                inputData = try context.remainingInputData(inputDescriptionID)
            } catch {
                return MSPCommandResult.failure(exitCode: 1, stderr: "read: \(error)\n")
            }
        } else {
            inputData = context.configuration().standardInput
        }
        let delimiter = readDelimiter(from: spec.delimiter)
        let records = readRecordFrames(from: inputData, delimiter: delimiter)
        var consumedInputByteCount = 0
        context.setLoopDepth(context.loopDepth() + 1)
        defer { context.setLoopDepth(context.loopDepth() - 1) }

        for record in records.prefix(context.compoundLoopIterationLimit) {
            do {
                let previousAssignmentValues = context.savedEnvironmentValues(spec.assignments.map(\.name))
                let assignmentEnvironment = try await context.expandedReadAssignmentEnvironment(
                    spec,
                    currentLastExitCode,
                    &stderr
                )
                updateConfiguration { configuration in
                    configuration.environment = context.environmentApplyingAssignments(
                        configuration.environment,
                        assignmentEnvironment
                    )
                }
                context.assignReadRecord(record.record, spec.names)
                context.restoreEnvironmentValues(previousAssignmentValues, Set(spec.names))
            } catch let expansionError as MSPShellExpansionError {
                return MSPCommandResult.failure(
                    exitCode: 1,
                    stdout: stdout,
                    stderr: stderr + "\(expansionError)\n"
                )
            } catch {
                return MSPCommandResult.failure(
                    exitCode: 1,
                    stdout: stdout,
                    stderr: stderr + "shell: \(error)\n"
                )
            }

            consumedInputByteCount += record.consumedByteCount
            let previousConfiguration = context.configuration()
            if let inputDescriptionID {
                context.consumeInputOpenFileDescription(inputDescriptionID, record.consumedByteCount)
                updateConfiguration { configuration in
                    configuration.standardInput = (try? context.remainingInputData(inputDescriptionID)) ?? Data()
                    configuration.standardInputClosed = false
                }
            } else {
                let remainingStart = min(max(0, consumedInputByteCount), inputData.count)
                updateConfiguration { configuration in
                    configuration.standardInput = inputData.subdata(in: remainingStart..<inputData.count)
                    configuration.standardInputClosed = false
                }
            }
            let bodyResult = await runCommandList(
                body,
                initialLastExitCode: currentLastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
            updateConfiguration { configuration in
                configuration.standardInput = previousConfiguration.standardInput
                configuration.standardInputClosed = previousConfiguration.standardInputClosed
            }
            appendCompoundOutput(bodyResult, stdout: &stdout, stderr: &stderr)
            finalExitCode = bodyResult.exitCode
            currentLastExitCode = bodyResult.exitCode
            if context.pendingFunctionReturnCode() != nil || context.pendingShellExitCode() != nil {
                return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: bodyResult.exitCode)
            }
            if let action = consumeLoopControlForCurrentLoop() {
                switch action {
                case .breakLoop:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                case .continueLoop:
                    finalExitCode = 0
                    currentLastExitCode = 0
                    continue
                case .propagate:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                }
            }
        }

        if records.count > context.compoundLoopIterationLimit {
            stderr += "while: maximum iteration count exceeded\n"
            return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 124)
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: finalExitCode)
    }

    func executeForEach(
        variable: String,
        values: MSPParsedForValues,
        body: MSPParsedCommandList,
        lastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var expandedValues: [String] = []
        do {
            switch values {
            case .explicit(let words):
                for word in words {
                    let expansion = try await context.expandWordVariants(word, lastExitCode)
                    expandedValues.append(contentsOf: expansion.values)
                    stderr += expansion.stderr
                }
            case .positionalParameters:
                expandedValues = Array(context.positionalParameters().dropFirst())
            }
        } catch let expansionError as MSPShellExpansionError {
            return MSPCommandResult.failure(exitCode: 1, stderr: stderr + "\(expansionError)\n")
        } catch {
            return MSPCommandResult.failure(exitCode: 1, stderr: stderr + "shell: \(error)\n")
        }

        var finalExitCode: Int32 = 0
        var currentLastExitCode = lastExitCode
        context.setLoopDepth(context.loopDepth() + 1)
        defer { context.setLoopDepth(context.loopDepth() - 1) }
        for value in expandedValues.prefix(context.compoundLoopIterationLimit) {
            context.setEnvironmentValue(variable, value)
            let bodyResult = await runCommandList(
                body,
                initialLastExitCode: currentLastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
            appendCompoundOutput(bodyResult, stdout: &stdout, stderr: &stderr)
            finalExitCode = bodyResult.exitCode
            currentLastExitCode = bodyResult.exitCode
            if context.pendingFunctionReturnCode() != nil || context.pendingShellExitCode() != nil {
                return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: bodyResult.exitCode)
            }
            if let action = consumeLoopControlForCurrentLoop() {
                switch action {
                case .breakLoop:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                case .continueLoop:
                    finalExitCode = 0
                    currentLastExitCode = 0
                    continue
                case .propagate:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                }
            }
        }

        if expandedValues.count > context.compoundLoopIterationLimit {
            stderr += "for: maximum iteration count exceeded\n"
            return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 124)
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: finalExitCode)
    }
}
