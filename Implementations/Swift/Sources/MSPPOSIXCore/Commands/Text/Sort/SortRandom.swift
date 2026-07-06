import CryptoKit
import Foundation
import MSPCore

func sortRandomSeed(options: SortOptions, context: MSPCommandContext) throws -> Data {
    guard let randomSourcePath = options.randomSourcePath else {
        return Data()
    }
    do {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: "sort")
        let source = try fileSystem.readFile(randomSourcePath, from: context.currentDirectory)
        guard source.count >= 16 else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: \(randomSourcePath): end of file\n"
            ))
        }
        return source.prefix(16)
    } catch let failure as MSPCommandFailure {
        throw failure
    } catch {
        throw MSPCommandFailure(result: .failure(
            exitCode: 2,
            stderr: "sort: open failed: \(randomSourcePath): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
        ))
    }
}

func randomSortComparison(_ lhs: String, _ rhs: String, seed: Data) -> ComparisonResult {
    let lhsDigest = sortRandomDigest(seed: seed, key: Data(lhs.utf8))
    let rhsDigest = sortRandomDigest(seed: seed, key: Data(rhs.utf8))
    if lhsDigest.lexicographicallyPrecedes(rhsDigest) {
        return .orderedAscending
    }
    if rhsDigest.lexicographicallyPrecedes(lhsDigest) {
        return .orderedDescending
    }
    return bytewiseComparison(lhs, rhs)
}

private func sortRandomDigest(seed: Data, key: Data) -> Data {
    var data = Data()
    data.append(seed)
    data.append(key)
    data.append(0)
    return Data(Insecure.MD5.hash(data: data))
}
