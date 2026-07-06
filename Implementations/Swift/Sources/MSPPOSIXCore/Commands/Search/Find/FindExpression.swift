import Foundation
import MSPCore

indirect enum FindExpression {
    case always
    case predicate(FindPredicate)
    case action(FindAction)
    case not(FindExpression)
    case and(FindExpression, FindExpression)
    case or(FindExpression, FindExpression)

    func evaluate(
        item: FindItem,
        emitActions: Bool,
        runtimeContext: FindRuntimePredicateContext,
        fileSystem: any MSPWorkspaceFileSystem,
        commandContext: MSPCommandContext
    ) async -> FindExpressionResult {
        switch self {
        case .always:
            return FindExpressionResult(evaluation: FindEvaluation(matches: true, prunes: false))
        case .predicate(let predicate):
            do {
                return FindExpressionResult(evaluation: FindEvaluation(
                    matches: try await predicate.matches(
                        item: item,
                        runtimeContext: runtimeContext,
                        fileSystem: fileSystem
                    ),
                    prunes: predicate == .prune
                ))
            } catch {
                return FindExpressionResult(
                    evaluation: FindEvaluation(matches: false, prunes: false),
                    exitCode: 1,
                    stderr: "find: \(mspPOSIXFindQuote(item.displayPath)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                )
            }
        case .action(let action):
            guard emitActions else {
                return FindExpressionResult(evaluation: FindEvaluation(matches: true, prunes: false))
            }
            return await action.run(
                item: item,
                fileSystem: fileSystem,
                commandContext: commandContext
            )
        case .not(let expression):
            var result = await expression.evaluate(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext
            )
            result.evaluation.matches.toggle()
            return result
        case .and(let lhs, let rhs):
            var lhsResult = await lhs.evaluate(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext
            )
            if lhsResult.evaluation.quits || !lhsResult.evaluation.matches {
                return lhsResult
            }
            let rhsResult = await rhs.evaluate(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext
            )
            lhsResult.append(rhsResult)
            lhsResult.evaluation = FindEvaluation(
                matches: rhsResult.evaluation.matches,
                prunes: lhsResult.evaluation.prunes || rhsResult.evaluation.prunes,
                quits: rhsResult.evaluation.quits
            )
            return lhsResult
        case .or(let lhs, let rhs):
            var lhsResult = await lhs.evaluate(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext
            )
            if lhsResult.evaluation.matches || lhsResult.evaluation.quits {
                return lhsResult
            }
            let rhsResult = await rhs.evaluate(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext,
                fileSystem: fileSystem,
                commandContext: commandContext
            )
            lhsResult.append(rhsResult)
            lhsResult.evaluation = FindEvaluation(
                matches: rhsResult.evaluation.matches,
                prunes: lhsResult.evaluation.prunes || rhsResult.evaluation.prunes,
                quits: rhsResult.evaluation.quits
            )
            return lhsResult
        }
    }

    func evaluateSynchronously(
        item: FindItem,
        emitActions: Bool,
        runtimeContext: FindRuntimePredicateContext
    ) -> FindExpressionResult {
        switch self {
        case .always:
            return FindExpressionResult(evaluation: FindEvaluation(matches: true, prunes: false))
        case .predicate(let predicate):
            return FindExpressionResult(evaluation: FindEvaluation(
                matches: predicate.matchesSynchronously(
                    item: item,
                    runtimeContext: runtimeContext
                ),
                prunes: false
            ))
        case .action(let action):
            guard emitActions else {
                return FindExpressionResult(evaluation: FindEvaluation(matches: true, prunes: false))
            }
            return action.runSynchronously(item: item)
        case .not(let expression):
            var result = expression.evaluateSynchronously(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext
            )
            result.evaluation.matches.toggle()
            return result
        case .and(let lhs, let rhs):
            var lhsResult = lhs.evaluateSynchronously(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext
            )
            if lhsResult.evaluation.quits || !lhsResult.evaluation.matches {
                return lhsResult
            }
            let rhsResult = rhs.evaluateSynchronously(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext
            )
            lhsResult.append(rhsResult)
            lhsResult.evaluation = FindEvaluation(
                matches: rhsResult.evaluation.matches,
                prunes: lhsResult.evaluation.prunes || rhsResult.evaluation.prunes,
                quits: rhsResult.evaluation.quits
            )
            return lhsResult
        case .or(let lhs, let rhs):
            var lhsResult = lhs.evaluateSynchronously(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext
            )
            if lhsResult.evaluation.matches || lhsResult.evaluation.quits {
                return lhsResult
            }
            let rhsResult = rhs.evaluateSynchronously(
                item: item,
                emitActions: emitActions,
                runtimeContext: runtimeContext
            )
            lhsResult.append(rhsResult)
            lhsResult.evaluation = FindEvaluation(
                matches: rhsResult.evaluation.matches,
                prunes: lhsResult.evaluation.prunes || rhsResult.evaluation.prunes,
                quits: rhsResult.evaluation.quits
            )
            return lhsResult
        }
    }

    var supportsSynchronousLeafBatchEvaluation: Bool {
        switch self {
        case .always:
            return true
        case .predicate(let predicate):
            return predicate.supportsSynchronousLeafBatchEvaluation
        case .action(let action):
            return action.supportsSynchronousLeafBatchEvaluation
        case .not(let expression):
            return expression.supportsSynchronousLeafBatchEvaluation
        case .and(let lhs, let rhs), .or(let lhs, let rhs):
            return lhs.supportsSynchronousLeafBatchEvaluation
                && rhs.supportsSynchronousLeafBatchEvaluation
        }
    }

    var requiredMatchType: MSPFileType? {
        switch self {
        case .always, .action:
            return nil
        case .predicate(let predicate):
            return predicate.requiredMatchType
        case .not:
            return nil
        case .and(let lhs, let rhs):
            return lhs.requiredMatchType ?? rhs.requiredMatchType
        case .or(let lhs, let rhs):
            guard let lhsType = lhs.requiredMatchType,
                  let rhsType = rhs.requiredMatchType,
                  lhsType == rhsType else {
                return nil
            }
            return lhsType
        }
    }

    var requiresDepthFirstTraversal: Bool {
        switch self {
        case .always, .predicate:
            return false
        case .action(let action):
            return action.requiresDepthFirstTraversal
        case .not(let expression):
            return expression.requiresDepthFirstTraversal
        case .and(let lhs, let rhs), .or(let lhs, let rhs):
            return lhs.requiresDepthFirstTraversal || rhs.requiresDepthFirstTraversal
        }
    }
}

struct FindExpressionResult {
    var evaluation: FindEvaluation
    var exitCode: Int32 = 0
    var stdout = ""
    var stderr = ""
    var batchActions: [FindBatchAction] = []

    mutating func append(_ other: FindExpressionResult) {
        stdout += other.stdout
        stderr += other.stderr
        if other.exitCode != 0, exitCode == 0 {
            exitCode = other.exitCode
        }
        appendBatchActions(other.batchActions, to: &batchActions)
    }
}

enum FindPredicate: Equatable {
    case name(pattern: String, caseInsensitive: Bool)
    case path(pattern: String, caseInsensitive: Bool)
    case regex(pattern: String, caseInsensitive: Bool)
    case type(Character)
    case empty
    case readable
    case writable
    case executable
    case newer(referencePath: String)
    case modifiedTime(FindTimeComparison)
    case size(FindSizeComparison)
    case permission(FindPermissionPredicate)
    case prune

    var requiredMatchType: MSPFileType? {
        guard case .type(let type) = self else {
            return nil
        }
        switch type {
        case "f":
            return .regularFile
        case "d":
            return .directory
        case "l":
            return .symbolicLink
        default:
            return nil
        }
    }

    var supportsSynchronousLeafBatchEvaluation: Bool {
        switch self {
        case .empty, .prune:
            return false
        case .name, .path, .regex, .type, .readable, .writable, .executable,
             .newer, .modifiedTime, .size, .permission:
            return true
        }
    }

    func matchesSynchronously(
        item: FindItem,
        runtimeContext: FindRuntimePredicateContext
    ) -> Bool {
        switch self {
        case .name(let pattern, let caseInsensitive):
            return globMatches(
                MSPPOSIXCommandSupport.basename(item.info.virtualPath),
                pattern: pattern,
                caseInsensitive: caseInsensitive
            )
        case .path(let pattern, let caseInsensitive):
            return globMatches(item.displayPath, pattern: pattern, caseInsensitive: caseInsensitive)
        case .regex(let pattern, let caseInsensitive):
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return false
            }
            let range = NSRange(item.displayPath.startIndex..<item.displayPath.endIndex, in: item.displayPath)
            return regex.firstMatch(in: item.displayPath, range: range).map { $0.range == range } ?? false
        case .type(let type):
            switch type {
            case "f":
                return item.info.type == .regularFile
            case "d":
                return item.info.type == .directory
            case "l":
                return item.info.type == .symbolicLink
            default:
                return false
            }
        case .empty, .prune:
            return false
        case .readable:
            return (MSPPOSIXCommandSupport.mode(for: item.info) & 0o444) != 0
        case .writable:
            return (MSPPOSIXCommandSupport.mode(for: item.info) & 0o222) != 0
        case .executable:
            return (MSPPOSIXCommandSupport.mode(for: item.info) & 0o111) != 0
        case .newer(let referencePath):
            guard let referenceDate = runtimeContext.newerReferenceDates[referencePath],
                  let itemDate = item.info.modificationDate else {
                return false
            }
            return itemDate > referenceDate
        case .modifiedTime(let comparison):
            guard let modificationDate = item.info.modificationDate else {
                return false
            }
            return comparison.matches(modifiedAt: modificationDate)
        case .size(let comparison):
            guard item.info.type != .directory else {
                return false
            }
            return comparison.matches(byteCount: MSPPOSIXCommandSupport.byteSize(item.info))
        case .permission(let predicate):
            return predicate.matches(mode: MSPPOSIXCommandSupport.mode(for: item.info))
        }
    }

    func matches(
        item: FindItem,
        runtimeContext: FindRuntimePredicateContext,
        fileSystem: any MSPWorkspaceFileSystem
    ) async throws -> Bool {
        switch self {
        case .name(let pattern, let caseInsensitive):
            return globMatches(
                MSPPOSIXCommandSupport.basename(item.info.virtualPath),
                pattern: pattern,
                caseInsensitive: caseInsensitive
            )
        case .path(let pattern, let caseInsensitive):
            return globMatches(item.displayPath, pattern: pattern, caseInsensitive: caseInsensitive)
        case .regex(let pattern, let caseInsensitive):
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return false
            }
            let range = NSRange(item.displayPath.startIndex..<item.displayPath.endIndex, in: item.displayPath)
            return regex.firstMatch(in: item.displayPath, range: range).map { $0.range == range } ?? false
        case .type(let type):
            switch type {
            case "f":
                return item.info.type == .regularFile
            case "d":
                return item.info.type == .directory
            case "l":
                return item.info.type == .symbolicLink
            default:
                return false
            }
        case .empty:
            if item.info.type == .directory {
                var hasChild = false
                try await fileSystem.enumerateDirectory(item.info.virtualPath, from: "/") { _ in
                    hasChild = true
                    return false
                }
                return !hasChild
            }
            return MSPPOSIXCommandSupport.byteSize(item.info) == 0
        case .readable:
            return (MSPPOSIXCommandSupport.mode(for: item.info) & 0o444) != 0
        case .writable:
            return (MSPPOSIXCommandSupport.mode(for: item.info) & 0o222) != 0
        case .executable:
            return (MSPPOSIXCommandSupport.mode(for: item.info) & 0o111) != 0
        case .newer(let referencePath):
            guard let referenceDate = runtimeContext.newerReferenceDates[referencePath],
                  let itemDate = item.info.modificationDate else {
                return false
            }
            return itemDate > referenceDate
        case .modifiedTime(let comparison):
            guard let modificationDate = item.info.modificationDate else {
                return false
            }
            return comparison.matches(modifiedAt: modificationDate)
        case .size(let comparison):
            guard item.info.type != .directory else {
                return false
            }
            return comparison.matches(byteCount: MSPPOSIXCommandSupport.byteSize(item.info))
        case .permission(let predicate):
            return predicate.matches(mode: MSPPOSIXCommandSupport.mode(for: item.info))
        case .prune:
            return true
        }
    }
}
