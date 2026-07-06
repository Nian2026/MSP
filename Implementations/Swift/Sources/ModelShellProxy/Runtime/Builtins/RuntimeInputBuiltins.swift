import Foundation
import MSPCore
import MSPShell

typealias RuntimeBuiltinInputReader = (
    _ fd: Int,
    _ routing: MSPRedirectionRouting,
    _ mode: RuntimeBuiltinInputReadMode
) async throws -> (data: Data, descriptionID: Int?)

enum RuntimeBuiltinInputReadMode {
    case all
    case record(delimiter: Character, characterCount: Int?, timeoutIsZero: Bool)
}

extension RuntimeBuiltinContext {
    mutating func executeReadCommand(
        arguments: [String],
        routing: MSPRedirectionRouting,
        assignments: [MSPParsedAssignment],
        appliesStateChange: Bool,
        readInput: RuntimeBuiltinInputReader,
        consumeInputDescription: (_ descriptionID: Int, _ byteCount: Int) -> Void
    ) async -> MSPCommandResult {
        let options: MSPShellReadCommandOptions
        do {
            options = try parseReadCommandOptions(arguments)
        } catch let failure as MSPCommandFailure {
            return diagnostics.shellBuiltinDiagnosticResult(failure.result)
        } catch {
            return .failure(exitCode: 2, stderr: "read: \(error)\n")
        }

        let previousAssignmentValues = savedEnvironmentValues(for: assignments.map(\.name))
        if appliesStateChange {
            configuration.environment = environment(configuration.environment, applying: assignments)
        }
        defer {
            if appliesStateChange {
                var preserving = Set(options.names)
                if let arrayName = options.arrayName {
                    preserving.insert(arrayName)
                }
                restoreEnvironmentValues(previousAssignmentValues, preserving: preserving)
            }
        }

        let input: Data
        let inputDescriptionID: Int?
        do {
            let resolved = try await readInput(
                options.fileDescriptor,
                routing,
                .record(
                    delimiter: options.delimiter,
                    characterCount: options.characterCount,
                    timeoutIsZero: options.timeoutIsZero
                )
            )
            input = resolved.data
            inputDescriptionID = resolved.descriptionID
        } catch let failure as MSPCommandFailure {
            return diagnostics.shellBuiltinDiagnosticResult(failure.result)
        } catch {
            return .failure(exitCode: 1, stderr: "read: \(error)\n")
        }

        let text = String(decoding: input, as: UTF8.self)
        let value: String
        let exitCode: Int32
        let consumedByteCount: Int
        if let characterCount = options.characterCount {
            value = String(text.prefix(characterCount))
            consumedByteCount = Data(value.utf8).count
            exitCode = text.count >= characterCount ? 0 : 1
        } else if options.timeoutIsZero, text.isEmpty {
            value = ""
            consumedByteCount = 0
            exitCode = 0
        } else if text.firstIndex(of: options.delimiter) != nil {
            let logical = readLogicalRecord(
                from: text,
                delimiter: options.delimiter,
                removesBackslashNewline: !options.rawMode
            )
            value = logical.value
            consumedByteCount = logical.consumedByteCount
            exitCode = 0
        } else {
            value = text
            consumedByteCount = input.count
            exitCode = 1
        }

        if appliesStateChange {
            if let inputDescriptionID {
                consumeInputDescription(inputDescriptionID, consumedByteCount)
            } else if options.fileDescriptor == 0 {
                configuration.standardInput = Data(input.dropFirst(consumedByteCount))
            }
            if let arrayName = options.arrayName {
                assignReadArray(value, to: arrayName)
            } else {
                assignReadRecord(value, to: options.names)
            }
        }
        return MSPCommandResult(exitCode: exitCode)
    }

    mutating func executeMapfileCommand(
        commandName: String,
        arguments: [String],
        routing: MSPRedirectionRouting,
        appliesStateChange: Bool,
        readInput: RuntimeBuiltinInputReader,
        consumeInputDescription: (_ descriptionID: Int, _ byteCount: Int) -> Void
    ) async -> MSPCommandResult {
        let options: MSPShellMapfileCommandOptions
        do {
            options = try parseMapfileCommandOptions(commandName: commandName, arguments: arguments)
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 2, stderr: "\(commandName): \(error)\n")
        }

        guard appliesStateChange else {
            return .success()
        }

        let input: Data
        let inputDescriptionID: Int?
        do {
            let resolved = try await readInput(options.fileDescriptor, routing, .all)
            input = resolved.data
            inputDescriptionID = resolved.descriptionID
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 1, stderr: "\(commandName): \(error)\n")
        }

        let text = String(decoding: input, as: UTF8.self)
        let allRecords = mapfileRecords(from: text)
        let skippedCount = min(options.skipCount, allRecords.count)
        let recordsAfterSkipping = Array(allRecords.dropFirst(skippedCount))
        let records: [MSPShellMapfileRecord]
        if let maxCount = options.maxCount, maxCount > 0 {
            records = Array(recordsAfterSkipping.prefix(maxCount))
        } else {
            records = recordsAfterSkipping
        }
        let consumedRecordCount = skippedCount + records.count
        let consumedByteCount = allRecords
            .prefix(consumedRecordCount)
            .reduce(0) { $0 + $1.consumedByteCount }

        let values = records.map { record in
            options.stripTerminator || !record.terminated
                ? record.line
                : record.line + "\n"
        }

        var array = options.origin == 0
            ? MSPShellIndexedArray()
            : (shellArrays[options.arrayName] ?? MSPShellIndexedArray())
        for (offset, value) in values.enumerated() {
            array.assign(value, at: options.origin + offset)
        }
        shellArrays[options.arrayName] = array
        configuration.environment[options.arrayName] = array.first ?? ""
        if let inputDescriptionID {
            consumeInputDescription(inputDescriptionID, consumedByteCount)
        } else if options.fileDescriptor == 0 {
            configuration.standardInput = Data(input.dropFirst(consumedByteCount))
        }
        return .success()
    }

    mutating func assignReadRecord(_ record: String, to names: [String]) {
        let targetNames = names.isEmpty ? ["REPLY"] : names
        guard targetNames.count > 1 else {
            configuration.environment[targetNames[0]] = record
            return
        }

        let parts = mspShellReadFields(
            record,
            ifs: configuration.environment["IFS"] ?? " \t\n",
            maxFields: targetNames.count
        )
        for (index, name) in targetNames.enumerated() {
            configuration.environment[name] = parts.indices.contains(index) ? parts[index] : ""
        }
    }

    private mutating func assignReadArray(_ record: String, to name: String) {
        let parts = mspShellReadAllFields(
            record,
            ifs: configuration.environment["IFS"] ?? " \t\n"
        )
        shellArrays[name] = MSPShellIndexedArray(parts)
        shellAssociativeArrays.removeValue(forKey: name)
        shellNamerefs.removeValue(forKey: name)
        configuration.environment[name] = parts.first ?? ""
    }

    private func readLogicalRecord(
        from text: String,
        delimiter: Character,
        removesBackslashNewline: Bool
    ) -> (value: String, consumedByteCount: Int) {
        var value = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text[cursor]
            if next == delimiter {
                let afterDelimiter = text.index(after: cursor)
                return (value, Data(text[..<afterDelimiter].utf8).count)
            }
            if removesBackslashNewline,
               next == "\\",
               text.index(after: cursor) < text.endIndex,
               text[text.index(after: cursor)] == delimiter {
                cursor = text.index(after: text.index(after: cursor))
                continue
            }
            value.append(next)
            cursor = text.index(after: cursor)
        }
        return (value, Data(text.utf8).count)
    }

    private func mapfileRecords(from text: String) -> [MSPShellMapfileRecord] {
        guard !text.isEmpty else {
            return []
        }
        var records: [MSPShellMapfileRecord] = []
        var lineStart = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "\n" {
                let afterDelimiter = text.index(after: cursor)
                let rawRecord = text[lineStart..<afterDelimiter]
                records.append(MSPShellMapfileRecord(
                    line: String(text[lineStart..<cursor]),
                    terminated: true,
                    consumedByteCount: Data(rawRecord.utf8).count
                ))
                lineStart = afterDelimiter
            }
            cursor = text.index(after: cursor)
        }
        if lineStart < text.endIndex {
            let rawRecord = text[lineStart..<text.endIndex]
            records.append(MSPShellMapfileRecord(
                line: String(rawRecord),
                terminated: false,
                consumedByteCount: Data(rawRecord.utf8).count
            ))
        }
        return records
    }

    private func parseReadCommandOptions(_ arguments: [String]) throws -> MSPShellReadCommandOptions {
        var names: [String] = []
        var delimiter: Character = "\n"
        var characterCount: Int?
        var fileDescriptor = 0
        var arrayName: String?
        var rawMode = false
        var timeoutIsZero = false
        var index = 0
        var parsesOptions = true
        while index < arguments.count {
            let argument = arguments[index]
            guard parsesOptions, argument.hasPrefix("-"), argument != "-" else {
                break
            }
            if argument == "--" {
                parsesOptions = false
                index += 1
                continue
            }
            var optionCharacters = Array(argument.dropFirst())
            while !optionCharacters.isEmpty {
                let option = optionCharacters.removeFirst()
                switch option {
                case "r":
                    rawMode = true
                    continue
                case "a":
                    let rawValue: String
                    if optionCharacters.isEmpty {
                        index += 1
                        guard index < arguments.count else {
                            throw MSPCommandFailure.usage("read: option requires an argument -- a\n")
                        }
                        rawValue = arguments[index]
                    } else {
                        rawValue = String(optionCharacters)
                        optionCharacters.removeAll()
                    }
                    guard shellInputVariableName(rawValue) else {
                        throw MSPCommandFailure.usage("read: invalid variable name \(rawValue)\n")
                    }
                    arrayName = rawValue
                case "d":
                    let rawValue: String
                    if optionCharacters.isEmpty {
                        index += 1
                        guard index < arguments.count else {
                            throw MSPCommandFailure.usage("read: option requires an argument -- d\n")
                        }
                        rawValue = arguments[index]
                    } else {
                        rawValue = String(optionCharacters)
                        optionCharacters.removeAll()
                    }
                    delimiter = rawValue.isEmpty ? "\0" : rawValue.first ?? "\0"
                case "n":
                    let rawValue: String
                    if optionCharacters.isEmpty {
                        index += 1
                        guard index < arguments.count else {
                            throw MSPCommandFailure.usage("read: option requires an argument -- n\n")
                        }
                        rawValue = arguments[index]
                    } else {
                        rawValue = String(optionCharacters)
                        optionCharacters.removeAll()
                    }
                    guard let parsed = Int(rawValue), parsed >= 0 else {
                        throw MSPCommandFailure.usage("read: \(rawValue): invalid number\n")
                    }
                    characterCount = parsed
                case "p":
                    if optionCharacters.isEmpty {
                        index += 1
                        guard index < arguments.count else {
                            throw MSPCommandFailure.usage("read: option requires an argument -- p\n")
                        }
                    } else {
                        optionCharacters.removeAll()
                    }
                case "t":
                    let rawValue: String
                    if optionCharacters.isEmpty {
                        index += 1
                        guard index < arguments.count else {
                            throw MSPCommandFailure.usage("read: option requires an argument -- t\n")
                        }
                        rawValue = arguments[index]
                    } else {
                        rawValue = String(optionCharacters)
                        optionCharacters.removeAll()
                    }
                    timeoutIsZero = rawValue == "0" || rawValue == "0.0"
                case "u":
                    let rawValue: String
                    if optionCharacters.isEmpty {
                        index += 1
                        guard index < arguments.count else {
                            throw MSPCommandFailure.usage("read: option requires an argument -- u\n")
                        }
                        rawValue = arguments[index]
                    } else {
                        rawValue = String(optionCharacters)
                        optionCharacters.removeAll()
                    }
                    guard let parsed = Int(rawValue), parsed >= 0 else {
                        throw MSPCommandFailure.usage("read: \(rawValue): invalid file descriptor\n")
                    }
                    fileDescriptor = parsed
                default:
                    throw MSPCommandFailure.usage(
                        "read: -\(option): invalid option\nread: usage: read [-ers] [-a array] [-d delim] [-i text] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]\n"
                    )
                }
            }
            index += 1
        }

        names = Array(arguments.dropFirst(index))
        if names.isEmpty {
            names = ["REPLY"]
        }
        for name in names {
            guard shellInputVariableName(name) else {
                throw MSPCommandFailure.usage("read: invalid variable name \(name)\n")
            }
        }
        return MSPShellReadCommandOptions(
            names: names,
            delimiter: delimiter,
            characterCount: characterCount,
            fileDescriptor: fileDescriptor,
            arrayName: arrayName,
            rawMode: rawMode,
            timeoutIsZero: timeoutIsZero
        )
    }

    private func parseMapfileCommandOptions(
        commandName: String,
        arguments: [String]
    ) throws -> MSPShellMapfileCommandOptions {
        var stripTerminator = false
        var maxCount: Int?
        var skipCount = 0
        var origin = 0
        var arrayName = "MAPFILE"
        var fileDescriptor = 0
        var operands: [String] = []
        var index = 0
        var parsesOptions = true

        func optionValue(
            option: Character,
            remaining: inout [Character],
            index: inout Int
        ) throws -> String {
            if !remaining.isEmpty {
                let value = String(remaining)
                remaining.removeAll()
                return value
            }
            guard index + 1 < arguments.count else {
                throw MSPCommandFailure.usage("\(commandName): -\(option): option requires an argument\n")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            guard parsesOptions, argument.hasPrefix("-"), argument != "-" else {
                operands.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                parsesOptions = false
                index += 1
                continue
            }

            var optionCharacters = Array(argument.dropFirst())
            while !optionCharacters.isEmpty {
                let option = optionCharacters.removeFirst()
                switch option {
                case "t":
                    stripTerminator = true
                case "u":
                    let value = try optionValue(option: option, remaining: &optionCharacters, index: &index)
                    guard let parsed = Int(value), parsed >= 0 else {
                        throw MSPCommandFailure.usage("\(commandName): \(value): invalid file descriptor\n")
                    }
                    fileDescriptor = parsed
                case "n":
                    maxCount = try nonNegativeMapfileInteger(
                        try optionValue(option: option, remaining: &optionCharacters, index: &index),
                        commandName: commandName
                    )
                case "s":
                    skipCount = try nonNegativeMapfileInteger(
                        try optionValue(option: option, remaining: &optionCharacters, index: &index),
                        commandName: commandName
                    )
                case "O":
                    origin = try nonNegativeMapfileInteger(
                        try optionValue(option: option, remaining: &optionCharacters, index: &index),
                        commandName: commandName
                    )
                default:
                    throw MSPCommandFailure.usage("\(commandName): -\(option): invalid option\n")
                }
            }
            index += 1
        }

        guard operands.count <= 1 else {
            throw MSPCommandFailure.usage("\(commandName): too many arguments\n")
        }
        if let operand = operands.first {
            guard shellInputVariableName(operand) else {
                throw MSPCommandFailure.usage("\(commandName): invalid variable name \(operand)\n")
            }
            arrayName = operand
        }

        return MSPShellMapfileCommandOptions(
            arrayName: arrayName,
            stripTerminator: stripTerminator,
            maxCount: maxCount,
            skipCount: skipCount,
            origin: origin,
            fileDescriptor: fileDescriptor
        )
    }

    private func nonNegativeMapfileInteger(
        _ rawValue: String,
        commandName: String
    ) throws -> Int {
        guard let value = Int(rawValue), value >= 0 else {
            throw MSPCommandFailure.usage("\(commandName): \(rawValue): invalid number\n")
        }
        return value
    }

    private func savedEnvironmentValues(for names: [String]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, configuration.environment[$0]) })
    }

    private func environment(
        _ base: [String: String],
        applying assignments: [MSPParsedAssignment]
    ) -> [String: String] {
        var updated = base
        for assignment in assignments {
            updated[resolvedShellInputNamerefName(assignment.name)] = assignment.value
        }
        return updated
    }

    private mutating func restoreEnvironmentValues(
        _ values: [String: String?],
        preserving preservedNames: Set<String> = []
    ) {
        for (name, value) in values where !preservedNames.contains(name) {
            configuration.environment[name] = value
        }
    }

    private func shellInputVariableName(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private func resolvedShellInputNamerefName(_ name: String) -> String {
        var current = name
        var seen: Set<String> = []
        while let next = shellNamerefs[current],
              shellInputVariableName(next),
              !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }
}

private struct MSPShellReadCommandOptions {
    var names: [String]
    var delimiter: Character
    var characterCount: Int?
    var fileDescriptor: Int
    var arrayName: String?
    var rawMode: Bool
    var timeoutIsZero: Bool
}

private struct MSPShellMapfileCommandOptions {
    var arrayName: String
    var stripTerminator: Bool
    var maxCount: Int?
    var skipCount: Int
    var origin: Int
    var fileDescriptor: Int
}

private struct MSPShellMapfileRecord {
    var line: String
    var terminated: Bool
    var consumedByteCount: Int
}
