import Foundation
import MSPCore

extension MSPHeadTailCommand {
    func streamHead(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        selection: HeadTailSelection
    ) async throws {
        switch selection.unit {
        case .bytes:
            switch selection.direction {
            case .head:
                guard selection.count > 0 else {
                    await standardInput.closeRead()
                    return
                }
                try await streamHeadBytes(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    count: selection.count
                )
            case .headAllButLast:
                try await streamHeadAllButLastBytes(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    count: selection.count
                )
            case .tail, .tailFromStart:
                return
            }
        case .lines:
            switch selection.direction {
            case .head:
                guard selection.count > 0 else {
                    await standardInput.closeRead()
                    return
                }
                try await streamHeadRecords(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    count: selection.count,
                    separator: selection.separator
                )
            case .headAllButLast:
                try await streamHeadAllButLastRecords(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    count: selection.count,
                    separator: selection.separator
                )
            case .tail, .tailFromStart:
                return
            }
        }
    }

    private func streamHeadBytes(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        count: Int
    ) async throws {
        var remaining = count
        while remaining > 0, let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            if chunk.count <= remaining {
                try await standardOutput.write(chunk)
                remaining -= chunk.count
            } else {
                try await standardOutput.write(chunk.headTailPrefixData(remaining))
                remaining = 0
            }
        }
        if remaining == 0 {
            await standardInput.closeRead()
        }
    }

    private func streamHeadAllButLastBytes(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        count: Int
    ) async throws {
        guard count > 0 else {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                try await standardOutput.write(chunk)
            }
            return
        }

        var window = Data()
        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            window.append(chunk)
            if window.count > count {
                let outputCount = window.count - count
                try await standardOutput.write(window.headTailPrefixData(outputCount))
                window.removeFirst(outputCount)
            }
        }
    }

    private func streamHeadRecords(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        count: Int,
        separator: UInt8
    ) async throws {
        var remaining = count
        while remaining > 0, let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            var selectedEnd = chunk.count
            var index = 0
            while index < chunk.count {
                if chunk[index] == separator {
                    remaining -= 1
                    if remaining == 0 {
                        selectedEnd = index + 1
                        break
                    }
                }
                index += 1
            }
            if selectedEnd > 0 {
                try await standardOutput.write(chunk.headTailPrefixData(selectedEnd))
            }
            if remaining == 0 {
                await standardInput.closeRead()
                return
            }
        }
    }

    private func streamHeadAllButLastRecords(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        count: Int,
        separator: UInt8
    ) async throws {
        guard count > 0 else {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                try await standardOutput.write(chunk)
            }
            return
        }

        var pendingRecords: [Data] = []
        var currentRecord = Data()
        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            for byte in chunk {
                currentRecord.append(byte)
                if byte == separator {
                    pendingRecords.append(currentRecord)
                    currentRecord.removeAll(keepingCapacity: true)
                    while pendingRecords.count > count {
                        try await standardOutput.write(pendingRecords.removeFirst())
                    }
                }
            }
        }
        if !currentRecord.isEmpty {
            pendingRecords.append(currentRecord)
        }
        while pendingRecords.count > count {
            try await standardOutput.write(pendingRecords.removeFirst())
        }
    }

    func streamTail(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        selection: HeadTailSelection
    ) async throws {
        switch selection.unit {
        case .bytes:
            switch selection.direction {
            case .tailFromStart:
                try await streamTailBytesFromStart(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    startCount: selection.count
                )
            case .tail:
                try await streamTailLastBytes(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    count: selection.count
                )
            case .head, .headAllButLast:
                try await streamHead(standardInput: standardInput, standardOutput: standardOutput, selection: selection)
            }
        case .lines:
            switch selection.direction {
            case .tailFromStart:
                try await streamTailRecordsFromStart(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    startCount: selection.count,
                    separator: selection.separator
                )
            case .tail:
                try await streamTailLastRecords(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    count: selection.count,
                    separator: selection.separator
                )
            case .head, .headAllButLast:
                try await streamHead(standardInput: standardInput, standardOutput: standardOutput, selection: selection)
            }
        }
    }

    private func streamTailLastBytes(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        count: Int
    ) async throws {
        guard count > 0 else {
            while try await standardInput.read(maxBytes: 32 * 1024) != nil {}
            return
        }
        var window = Data()
        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            window.append(chunk)
            if window.count > count {
                window.removeFirst(window.count - count)
            }
        }
        if !window.isEmpty {
            try await standardOutput.write(window)
        }
    }

    private func streamTailBytesFromStart(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        startCount: Int
    ) async throws {
        var bytesToSkip = max(0, startCount - 1)
        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            if bytesToSkip == 0 {
                try await standardOutput.write(chunk)
                continue
            }
            if chunk.count <= bytesToSkip {
                bytesToSkip -= chunk.count
                continue
            }
            try await standardOutput.write(chunk.headTailSuffixData(chunk.count - bytesToSkip))
            bytesToSkip = 0
        }
    }

    private func streamTailLastRecords(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        count: Int,
        separator: UInt8
    ) async throws {
        guard count > 0 else {
            while try await standardInput.read(maxBytes: 32 * 1024) != nil {}
            return
        }
        var records: [Data] = []
        var currentRecord = Data()
        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            for byte in chunk {
                currentRecord.append(byte)
                if byte == separator {
                    records.append(currentRecord)
                    currentRecord.removeAll(keepingCapacity: true)
                    if records.count > count {
                        records.removeFirst(records.count - count)
                    }
                }
            }
        }
        if !currentRecord.isEmpty {
            records.append(currentRecord)
            if records.count > count {
                records.removeFirst(records.count - count)
            }
        }
        for record in records {
            try await standardOutput.write(record)
        }
    }

    private func streamTailRecordsFromStart(
        standardInput: any MSPCommandInputStream,
        standardOutput: any MSPCommandOutputStream,
        startCount: Int,
        separator: UInt8
    ) async throws {
        var recordsToSkip = max(0, startCount - 1)
        while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
            guard recordsToSkip > 0 else {
                try await standardOutput.write(chunk)
                continue
            }
            var outputStart: Int?
            var index = 0
            while index < chunk.count {
                if chunk[index] == separator {
                    recordsToSkip -= 1
                    if recordsToSkip == 0 {
                        outputStart = index + 1
                        break
                    }
                }
                index += 1
            }
            if let outputStart, outputStart < chunk.count {
                try await standardOutput.write(chunk.headTailSuffixData(chunk.count - outputStart))
            }
        }
    }
}
