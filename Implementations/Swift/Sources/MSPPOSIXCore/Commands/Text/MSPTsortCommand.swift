import Foundation
import MSPCore

public struct MSPTsortCommand: MSPCommand {
    public let name = "tsort"
    public let summary: String? = "Topologically sort a directed graph."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspTsortUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "tsort (GNU coreutils) 9.1\n")
        }
        let parsed = try parse(invocation.arguments)
        let input: Data
        do {
            if let path = parsed.path {
                let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                input = try fileSystem.readFile(path, from: context.currentDirectory)
            } else {
                input = try MSPPOSIXCommandSupport.standardInputData(from: context)
            }
        } catch {
            return MSPCommandResult(
                stderr: "tsort: \(parsed.path ?? "-"): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n",
                exitCode: 1
            )
        }

        let label = parsed.path ?? "-"
        let tokens = tsortTokens(input)
        guard tokens.count.isMultiple(of: 2) else {
            return MSPCommandResult(
                stderr: "tsort: \(label): input contains an odd number of tokens\n",
                exitCode: 1
            )
        }

        let result = sort(tokens: tokens, label: label)
        return MSPCommandResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    private func parse(_ arguments: [String]) throws -> MSPTsortParsedArguments {
        var operands: [String] = []
        for argument in arguments {
            if argument.hasPrefix("-"), argument != "-" {
                let option = argument.dropFirst().first ?? "?"
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "tsort: invalid option -- '\(option)'\nTry 'tsort --help' for more information.\n"
                ))
            }
            operands.append(argument)
        }
        if operands.count > 1 {
            throw MSPCommandFailure.usage("tsort: extra operand \(MSPPOSIXCommandSupport.gnuQuote(operands[1]))\n")
        }
        return MSPTsortParsedArguments(path: operands.first == "-" ? nil : operands.first)
    }

    private func sort(tokens: [String], label: String) -> MSPTsortResult {
        var order: [String] = []
        var seen = Set<String>()
        var outgoing: [String: [String]] = [:]
        var indegree: [String: Int] = [:]
        var edges = Set<String>()

        func ensure(_ node: String) {
            guard !seen.contains(node) else {
                return
            }
            seen.insert(node)
            order.append(node)
            outgoing[node] = []
            indegree[node] = 0
        }

        var index = 0
        while index < tokens.count {
            let source = tokens[index]
            let target = tokens[index + 1]
            ensure(source)
            ensure(target)
            if source != target {
                let edge = source + "\u{0}" + target
                if !edges.contains(edge) {
                    edges.insert(edge)
                    outgoing[source, default: []].append(target)
                    indegree[target, default: 0] += 1
                }
            }
            index += 2
        }

        var printed = Set<String>()
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0

        while printed.count < order.count {
            var queue = order.filter { !printed.contains($0) && (indegree[$0] ?? 0) == 0 }
            if queue.isEmpty {
                let remaining = order.filter { !printed.contains($0) }
                guard !remaining.isEmpty else {
                    break
                }
                exitCode = 1
                stderr += "tsort: \(label): input contains a loop:\n"
                for node in remaining {
                    stderr += "tsort: \(node)\n"
                }
                for node in remaining {
                    stdout += "\(node)\n"
                    printed.insert(node)
                }
                break
            }

            while !queue.isEmpty {
                let node = queue.removeFirst()
                guard !printed.contains(node) else {
                    continue
                }
                stdout += "\(node)\n"
                printed.insert(node)
                for successor in outgoing[node] ?? [] {
                    indegree[successor, default: 0] -= 1
                    if indegree[successor] == 0, !printed.contains(successor) {
                        queue.append(successor)
                    }
                }
            }
        }

        return MSPTsortResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}

private struct MSPTsortParsedArguments {
    var path: String?
}

private struct MSPTsortResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

private func tsortTokens(_ data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    return text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

private let mspTsortUsageText = """
Usage: tsort [OPTION] [FILE]
Write totally ordered list consistent with the partial ordering in FILE.
With no FILE, or when FILE is -, read standard input.

      --help        display this help and exit
      --version     output version information and exit

"""
