import Foundation
import MSPCore

struct MSPJoinEngine {
    var configuration: MSPJoinConfiguration
    var firstOperand: String
    var secondOperand: String

    func run(firstData: Data, secondData: Data) -> MSPCommandResult {
        var firstRows = mspJoinRows(
            in: firstData,
            recordDelimiter: configuration.recordDelimiter,
            separator: configuration.separator,
            joinField: configuration.firstJoinField,
            ignoreCase: configuration.ignoreCase
        )
        var secondRows = mspJoinRows(
            in: secondData,
            recordDelimiter: configuration.recordDelimiter,
            separator: configuration.separator,
            joinField: configuration.secondJoinField,
            ignoreCase: configuration.ignoreCase
        )
        let firstHeader = configuration.header && !firstRows.isEmpty ? firstRows.removeFirst() : nil
        let secondHeader = configuration.header && !secondRows.isEmpty ? secondRows.removeFirst() : nil

        if configuration.checkOrder == true {
            if let disorder = mspFirstDisorderedJoinLine(in: firstRows) {
                return MSPCommandResult(
                    stderr: "join: \(firstOperand):\(disorder.line): is not sorted: \(disorder.text)\n",
                    exitCode: 1
                )
            }
            if let disorder = mspFirstDisorderedJoinLine(in: secondRows) {
                return MSPCommandResult(
                    stderr: "join: \(secondOperand):\(disorder.line): is not sorted: \(disorder.text)\n",
                    exitCode: 1
                )
            }
        }

        let autoCounts: (first: Int, second: Int)? = configuration.autoFormat
            ? (
                firstHeader?.fields.count ?? firstRows.first?.fields.count ?? 0,
                secondHeader?.fields.count ?? secondRows.first?.fields.count ?? 0
            )
            : nil
        var output = [Data]()
        if configuration.header, firstHeader != nil || secondHeader != nil {
            output.append(outputLine(
                key: firstHeader?.key ?? secondHeader?.key ?? Data(),
                firstRow: firstHeader?.fields,
                secondRow: secondHeader?.fields,
                autoCounts: autoCounts
            ))
        }

        var firstIndex = 0
        var secondIndex = 0
        let onlyUnpaired = configuration.onlyUnpairedFirst || configuration.onlyUnpairedSecond
        var sawDefaultUnpairable = false

        while firstIndex < firstRows.count || secondIndex < secondRows.count {
            if firstIndex >= firstRows.count {
                let secondGroup = mspJoinRowGroup(in: secondRows, startingAt: secondIndex)
                sawDefaultUnpairable = true
                appendSecondUnpairedRows(secondGroup, to: &output, autoCounts: autoCounts)
                secondIndex = secondGroup.endIndex
                continue
            }

            if secondIndex >= secondRows.count {
                let firstGroup = mspJoinRowGroup(in: firstRows, startingAt: firstIndex)
                sawDefaultUnpairable = true
                appendFirstUnpairedRows(firstGroup, to: &output, autoCounts: autoCounts)
                firstIndex = firstGroup.endIndex
                continue
            }

            let firstKey = firstRows[firstIndex].key
            let secondKey = secondRows[secondIndex].key
            if mspJoinCompare(firstKey, secondKey) < 0 {
                let firstGroup = mspJoinRowGroup(in: firstRows, startingAt: firstIndex)
                sawDefaultUnpairable = true
                appendFirstUnpairedRows(firstGroup, to: &output, autoCounts: autoCounts)
                firstIndex = firstGroup.endIndex
                continue
            }

            if mspJoinCompare(secondKey, firstKey) < 0 {
                let secondGroup = mspJoinRowGroup(in: secondRows, startingAt: secondIndex)
                sawDefaultUnpairable = true
                appendSecondUnpairedRows(secondGroup, to: &output, autoCounts: autoCounts)
                secondIndex = secondGroup.endIndex
                continue
            }

            let firstGroup = mspJoinRowGroup(in: firstRows, startingAt: firstIndex)
            let secondGroup = mspJoinRowGroup(in: secondRows, startingAt: secondIndex)
            if !onlyUnpaired {
                for firstRow in firstGroup.rows {
                    for secondRow in secondGroup.rows {
                        output.append(outputLine(
                            key: firstGroup.key,
                            firstRow: firstRow.fields,
                            secondRow: secondRow.fields,
                            autoCounts: autoCounts
                        ))
                    }
                }
            }
            firstIndex = firstGroup.endIndex
            secondIndex = secondGroup.endIndex
        }

        let stdoutData = mspJoinOutputData(output, delimiter: configuration.outputDelimiter)
        if configuration.checkOrder == nil, sawDefaultUnpairable {
            var diagnostics = [String]()
            if let disorder = mspFirstDisorderedJoinLine(in: firstRows) {
                diagnostics.append("join: \(firstOperand):\(disorder.line): is not sorted: \(disorder.text)")
            }
            if let disorder = mspFirstDisorderedJoinLine(in: secondRows) {
                diagnostics.append("join: \(secondOperand):\(disorder.line): is not sorted: \(disorder.text)")
            }
            if !diagnostics.isEmpty {
                diagnostics.append("join: input is not in sorted order")
                return MSPCommandResult(
                    stdoutData: stdoutData,
                    stderr: diagnostics.joined(separator: "\n") + "\n",
                    exitCode: 1
                )
            }
        }
        return .success(stdoutData: stdoutData)
    }

    private func appendFirstUnpairedRows(
        _ group: MSPJoinRowGroup,
        to output: inout [Data],
        autoCounts: (first: Int, second: Int)?
    ) {
        guard configuration.includeUnpairedFirst || configuration.onlyUnpairedFirst else {
            return
        }
        for row in group.rows {
            output.append(outputLine(
                key: group.key,
                firstRow: row.fields,
                secondRow: nil,
                autoCounts: autoCounts
            ))
        }
    }

    private func appendSecondUnpairedRows(
        _ group: MSPJoinRowGroup,
        to output: inout [Data],
        autoCounts: (first: Int, second: Int)?
    ) {
        guard configuration.includeUnpairedSecond || configuration.onlyUnpairedSecond else {
            return
        }
        for row in group.rows {
            output.append(outputLine(
                key: group.key,
                firstRow: nil,
                secondRow: row.fields,
                autoCounts: autoCounts
            ))
        }
    }

    private func outputLine(
        key: Data,
        firstRow: [Data]?,
        secondRow: [Data]?,
        autoCounts: (first: Int, second: Int)?
    ) -> Data {
        mspJoinOutputLine(
            key: key,
            firstRow: firstRow,
            secondRow: secondRow,
            firstJoinField: configuration.firstJoinField,
            secondJoinField: configuration.secondJoinField,
            outputFields: configuration.outputFields,
            autoCounts: autoCounts,
            separator: configuration.outputSeparator,
            emptyReplacement: configuration.emptyReplacement
        )
    }
}
