import Foundation
import MSPCore

enum FindAction: Equatable {
    case print(separator: String)
    case printf(String)
    case delete
    case exec([String], batch: Bool)
    case quit

    var supportsSynchronousLeafBatchEvaluation: Bool {
        switch self {
        case .print, .printf:
            return true
        case .delete, .exec, .quit:
            return false
        }
    }

    var requiresDepthFirstTraversal: Bool {
        switch self {
        case .delete:
            return true
        case .print, .printf, .exec, .quit:
            return false
        }
    }

    func runSynchronously(item: FindItem) -> FindExpressionResult {
        switch self {
        case .print(let separator):
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: true, prunes: false),
                stdout: item.displayPath + separator
            )
        case .printf(let format):
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: true, prunes: false),
                stdout: formatFindPrintf(format, item: item)
            )
        case .delete, .exec, .quit:
            return FindExpressionResult(evaluation: FindEvaluation(matches: false, prunes: false))
        }
    }

    func run(
        item: FindItem,
        fileSystem: any MSPWorkspaceFileSystem,
        commandContext: MSPCommandContext
    ) async -> FindExpressionResult {
        switch self {
        case .print(let separator):
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: true, prunes: false),
                stdout: item.displayPath + separator
            )
        case .printf(let format):
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: true, prunes: false),
                stdout: formatFindPrintf(format, item: item)
            )
        case .delete:
            do {
                if item.info.type == .directory {
                    let entries = try fileSystem.listDirectory(item.info.virtualPath, from: "/")
                    guard entries.isEmpty else {
                        throw FindDeleteError.directoryNotEmpty
                    }
                    try ensureDirectoryHasNoUnlistedPhysicalEntries(
                        item.info.virtualPath,
                        fileSystem: fileSystem
                    )
                    try fileSystem.remove(item.info.virtualPath, from: "/", recursive: true)
                } else {
                    try fileSystem.remove(item.info.virtualPath, from: "/", recursive: false)
                }
                return FindExpressionResult(evaluation: FindEvaluation(matches: true, prunes: false))
            } catch {
                return FindExpressionResult(
                    evaluation: FindEvaluation(matches: false, prunes: false),
                    exitCode: 1,
                    stderr: "find: cannot delete \(mspPOSIXFindQuote(item.displayPath)): \(findDeleteDiagnosticReason(from: error))\n"
                )
            }
        case .exec(let template, false):
            let commandWords = template.map {
                $0.replacingOccurrences(of: "{}", with: item.displayPath)
            }
            let result = await runFindSubcommand(commandWords, commandContext: commandContext)
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: result.exitCode == 0, prunes: false),
                stdout: result.stdout,
                stderr: result.stderr
            )
        case .exec(_, true):
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: true, prunes: false),
                batchActions: [FindBatchAction(action: self, items: [item])]
            )
        case .quit:
            return FindExpressionResult(
                evaluation: FindEvaluation(matches: true, prunes: false, quits: true)
            )
        }
    }
}

struct FindBatchAction {
    var action: FindAction
    var items: [FindItem]

    fileprivate func run(commandContext: MSPCommandContext) async -> MSPCommandResult {
        guard case .exec(let template, true) = action,
              let placeholderIndex = template.firstIndex(of: "{}") else {
            return .success()
        }
        let commandWords = Array(template[..<placeholderIndex])
            + items.map(\.displayPath)
            + Array(template[template.index(after: placeholderIndex)...])
        return await runFindSubcommand(commandWords, commandContext: commandContext)
    }

    fileprivate mutating func nextBatch(flushAll: Bool) -> FindBatchAction? {
        guard !items.isEmpty else {
            return nil
        }
        guard flushAll || shouldFlush else {
            return nil
        }
        let count = batchItemCount()
        let batchItems = Array(items.prefix(count))
        items.removeFirst(count)
        return FindBatchAction(action: action, items: batchItems)
    }

    private var shouldFlush: Bool {
        items.count >= findExecBatchMaxItems || estimatedCommandBytes(forFirst: items.count) >= findExecBatchMaxCommandBytes
    }

    private func batchItemCount() -> Int {
        var count = 0
        while count < items.count, count < findExecBatchMaxItems {
            let candidateCount = count + 1
            if candidateCount > 1,
               estimatedCommandBytes(forFirst: candidateCount) > findExecBatchMaxCommandBytes {
                break
            }
            count = candidateCount
        }
        return max(1, count)
    }

    private func estimatedCommandBytes(forFirst count: Int) -> Int {
        guard case .exec(let template, true) = action,
              let placeholderIndex = template.firstIndex(of: "{}") else {
            return 0
        }
        let fixedWords = Array(template[..<placeholderIndex])
            + Array(template[template.index(after: placeholderIndex)...])
        let fixedBytes = fixedWords.reduce(0) { total, word in
            total + word.utf8.count + 1
        }
        let itemBytes = items.prefix(count).reduce(0) { total, item in
            total + item.displayPath.utf8.count + 1
        }
        return fixedBytes + itemBytes
    }
}

func appendBatchActions(_ additions: [FindBatchAction], to batchActions: inout [FindBatchAction]) {
    for addition in additions {
        if let index = batchActions.firstIndex(where: { $0.action == addition.action }) {
            batchActions[index].items.append(contentsOf: addition.items)
        } else {
            batchActions.append(addition)
        }
    }
}

private let findExecBatchMaxItems = 128
private let findExecBatchMaxCommandBytes = 32 * 1024

func flushBatchActions(
    _ batchActions: inout [FindBatchAction],
    commandContext: MSPCommandContext,
    output: any FindOutputWriter,
    exitCode: inout Int32,
    flushAll: Bool
) async throws {
    var pending: [FindBatchAction] = []
    for var action in batchActions {
        while let readyBatch = action.nextBatch(flushAll: flushAll) {
            let batchResult = await readyBatch.run(commandContext: commandContext)
            try await output.appendStdout(batchResult.stdoutData)
            try await output.appendStderr(batchResult.stderrData)
            if batchResult.exitCode != 0, exitCode == 0 {
                exitCode = 1
            }
        }
        if !action.items.isEmpty {
            pending.append(action)
        }
    }
    batchActions = pending
}

private enum FindDeleteError: Error {
    case directoryNotEmpty
}

private func ensureDirectoryHasNoUnlistedPhysicalEntries(
    _ virtualPath: String,
    fileSystem: any MSPWorkspaceFileSystem
) throws {
    guard let physicalPath = try fileSystem.resolve(virtualPath, from: "/").physicalPath else {
        return
    }
    let physicalEntries: [String]
    do {
        physicalEntries = try FileManager.default.contentsOfDirectory(atPath: physicalPath)
    } catch {
        throw MSPWorkspaceFileSystemError.io(path: virtualPath, operation: "list")
    }
    guard physicalEntries.isEmpty else {
        throw FindDeleteError.directoryNotEmpty
    }
}

private func findDeleteDiagnosticReason(from error: Error) -> String {
    if case FindDeleteError.directoryNotEmpty = error {
        return "Directory not empty"
    }
    return MSPPOSIXCommandSupport.diagnosticReason(from: error)
}
