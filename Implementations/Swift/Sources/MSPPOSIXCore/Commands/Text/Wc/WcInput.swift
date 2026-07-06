import Foundation
import MSPCore

extension MSPWcCommand {
    func wcInputRows(
        operands: [String],
        context: MSPCommandContext,
        readStandardInputWhenEmpty: Bool
    ) throws -> WcInputResult {
        if operands.isEmpty {
            guard readStandardInputWhenEmpty else {
                return WcInputResult(rows: [], diagnostics: [], exitCode: 0)
            }
            do {
                return WcInputResult(
                    rows: [WcRow(counts: WcCounts(data: try MSPPOSIXCommandSupport.standardInputData(from: context)), label: nil)],
                    diagnostics: [],
                    exitCode: 0
                )
            } catch {
                return WcInputResult(
                    rows: [],
                    diagnostics: ["\(name): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"],
                    exitCode: 1
                )
            }
        }

        var fileSystem: (any MSPWorkspaceFileSystem)?
        var standardInputConsumed = false
        var rows: [WcRow] = []
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        for operand in operands {
            if operand == "-" {
                let data: Data
                if standardInputConsumed {
                    data = Data()
                } else {
                    standardInputConsumed = true
                    do {
                        data = try MSPPOSIXCommandSupport.standardInputData(from: context)
                    } catch {
                        diagnostics.append("\(name): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                        exitCode = 1
                        continue
                    }
                }
                rows.append(WcRow(counts: WcCounts(data: data), label: "-"))
                continue
            }

            do {
                if fileSystem == nil {
                    fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                }
                rows.append(WcRow(
                    counts: try wcCountsForFile(
                        operand,
                        fileSystem: fileSystem!,
                        currentDirectory: context.currentDirectory
                    ),
                    label: operand
                ))
            } catch {
                diagnostics.append(
                    "\(name): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                )
                exitCode = 1
            }
        }

        return WcInputResult(rows: rows, diagnostics: diagnostics, exitCode: exitCode)
    }

    func wcCountsForFile(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> WcCounts {
        var counter = WcStreamingCounter()
        var offset: UInt64 = 0
        let chunkSize = 32 * 1024
        while true {
            let chunk = try fileSystem.readFileRange(
                path,
                from: currentDirectory,
                offset: offset,
                length: chunkSize
            )
            guard !chunk.isEmpty else {
                break
            }
            counter.append(chunk)
            offset += UInt64(chunk.count)
        }
        counter.finish()
        return counter.counts
    }

    func fileListOperands(from listPath: String, context: MSPCommandContext) throws -> [String] {
        let data: Data
        if listPath == "-" {
            do {
                data = try MSPPOSIXCommandSupport.standardInputData(from: context)
            } catch {
                throw MSPCommandFailure(result: .failure(
                    stderr: "wc: stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                ))
            }
        } else {
            do {
                let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                data = try fileSystem.readFile(listPath, from: context.currentDirectory)
            } catch {
                throw MSPCommandFailure(result: .failure(
                    stderr: "wc: cannot open \(MSPPOSIXCommandSupport.gnuQuote(listPath)) for reading: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                ))
            }
        }

        var operands: [String] = []
        var start = data.startIndex
        var recordNumber = 1
        for index in data.indices where data[index] == 0 {
            let nameData = data[start..<index]
            guard !nameData.isEmpty else {
                throw MSPCommandFailure(result: .failure(
                    stderr: "wc: \(MSPPOSIXCommandSupport.gnuQuote(listPath)):\(recordNumber): invalid zero-length file name\n"
                ))
            }
            let name = String(decoding: nameData, as: UTF8.self)
            if listPath == "-", name == "-" {
                throw MSPCommandFailure(result: .failure(
                    stderr: "wc: when reading file names from stdin, no file name of \(MSPPOSIXCommandSupport.gnuQuote("-")) allowed\n"
                ))
            }
            operands.append(name)
            start = data.index(after: index)
            recordNumber += 1
        }
        if start < data.endIndex {
            let nameData = data[start..<data.endIndex]
            let name = String(decoding: nameData, as: UTF8.self)
            if listPath == "-", name == "-" {
                throw MSPCommandFailure(result: .failure(
                    stderr: "wc: when reading file names from stdin, no file name of \(MSPPOSIXCommandSupport.gnuQuote("-")) allowed\n"
                ))
            }
            operands.append(name)
        }
        return operands
    }
}
