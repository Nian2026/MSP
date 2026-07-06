import Foundation
import MSPCore
import MSPShell

extension ShellCompoundFunctionRuntime {
    func executeCStyleFor(
        header: MSPParsedCStyleForHeader,
        body: MSPParsedCommandList,
        lastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var finalExitCode: Int32 = 0
        var currentLastExitCode = lastExitCode
        context.setLoopDepth(context.loopDepth() + 1)
        defer { context.setLoopDepth(context.loopDepth() - 1) }

        do {
            if !header.initExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try context.evaluateArithmetic(header.initExpression)
            }
            for _ in 0..<context.compoundLoopIterationLimit {
                if !header.conditionExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   try context.evaluateArithmetic(header.conditionExpression).value == 0 {
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
                        if !header.updateExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            _ = try context.evaluateArithmetic(header.updateExpression)
                        }
                        continue
                    case .propagate:
                        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                    }
                }

                if !header.updateExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try context.evaluateArithmetic(header.updateExpression)
                }
            }
        } catch let expansionError as MSPShellExpansionError {
            return MSPCommandResult.failure(exitCode: 1, stdout: stdout, stderr: stderr + "\(expansionError)\n")
        } catch {
            return MSPCommandResult.failure(exitCode: 1, stdout: stdout, stderr: stderr + "arithmetic expansion: \(error)\n")
        }

        stderr += "for: maximum iteration count exceeded\n"
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 124)
    }

    func executeCase(
        subject: MSPParsedWord,
        arms: [MSPParsedStructuredCaseArm],
        lastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var finalExitCode: Int32 = 0
        var fallThrough = false

        do {
            let subjectExpansion = try await context.expandWordText(
                subject,
                lastExitCode,
                false,
                false
            )
            let subjectValue = subjectExpansion.value
            stderr += subjectExpansion.stderr

            for arm in arms {
                var matched = fallThrough
                if !fallThrough {
                    for patternWord in arm.patterns {
                        let patternExpansion = try await context.expandWordText(
                            patternWord,
                            finalExitCode,
                            false,
                            false
                        )
                        stderr += patternExpansion.stderr
                        if mspShellGlobPattern(
                            patternExpansion.value,
                            matches: subjectValue,
                            pathSeparatorsAreSpecial: false
                        ) {
                            matched = true
                            break
                        }
                    }
                }

                guard matched else {
                    fallThrough = false
                    continue
                }

                let bodyResult = await runCommandList(
                    arm.body,
                    initialLastExitCode: finalExitCode,
                    outputStream: outputStream,
                    errorStream: errorStream
                )
                appendCompoundOutput(bodyResult, stdout: &stdout, stderr: &stderr)
                finalExitCode = bodyResult.exitCode
                if hasPendingShellControl {
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: bodyResult.exitCode)
                }

                switch arm.terminator {
                case .breakArm:
                    return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: finalExitCode)
                case .fallThrough:
                    fallThrough = true
                case .continueMatching:
                    fallThrough = false
                }
            }
        } catch let expansionError as MSPShellExpansionError {
            return MSPCommandResult.failure(exitCode: 1, stdout: stdout, stderr: stderr + "\(expansionError)\n")
        } catch {
            return MSPCommandResult.failure(exitCode: 1, stdout: stdout, stderr: stderr + "shell: \(error)\n")
        }

        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: finalExitCode)
    }
}
