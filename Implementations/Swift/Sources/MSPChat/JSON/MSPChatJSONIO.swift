import Foundation

enum MSPChatJSON {
    static func readObject(from url: URL) throws -> [String: MSPChatJSONValue] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw MSPChatError.invalidJSON("\(url.path) must contain a JSON object.")
        }
        guard case let .object(value) = try MSPChatJSONValue.fromAny(dictionary) else {
            throw MSPChatError.invalidJSON("\(url.path) must contain a JSON object.")
        }
        return value
    }

    static func readNDJSONObjects(from url: URL) throws -> [(line: Int, object: [String: MSPChatJSONValue])] {
        var records: [(Int, [String: MSPChatJSONValue])] = []
        try forEachNDJSONObject(from: url) { line, object in
            records.append((line, object))
        }
        return records
    }

    static func forEachNDJSONObject(
        from url: URL,
        _ body: (Int, [String: MSPChatJSONValue]) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var lineNumber = 1
        var lineData = Data()

        func emitRecordIfNeeded(from rawLineData: Data, lineNumber: Int) throws {
            let line = String(decoding: rawLineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                return
            }
            guard let lineData = line.data(using: .utf8) else {
                throw MSPChatError.invalidJSON("\(url.path):\(lineNumber) is not UTF-8.")
            }
            try body(
                lineNumber,
                try object(
                    fromLineData: lineData,
                    sourceDescription: "\(url.path):\(lineNumber)"
                )
            )
        }

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            for byte in chunk {
                if byte == 0x0A {
                    try emitRecordIfNeeded(from: lineData, lineNumber: lineNumber)
                    lineData.removeAll(keepingCapacity: true)
                    lineNumber += 1
                } else {
                    lineData.append(byte)
                }
            }
        }
        if !lineData.isEmpty {
            try emitRecordIfNeeded(from: lineData, lineNumber: lineNumber)
        }
    }

    static func object(
        fromLineData data: Data,
        sourceDescription: String
    ) throws -> [String: MSPChatJSONValue] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw MSPChatError.invalidJSON("\(sourceDescription) must contain a JSON object.")
        }
        guard case let .object(value) = try MSPChatJSONValue.fromAny(dictionary) else {
            throw MSPChatError.invalidJSON("\(sourceDescription) must contain a JSON object.")
        }
        return value
    }

    static func readNextSeq(fromNDJSONAt url: URL) throws -> Int {
        let records = try readNDJSONObjects(from: url)
        return ((records.map { $0.object["seq"]?.intValue ?? 0 }.max()) ?? 0) + 1
    }

    static func writeObject(_ object: [String: MSPChatJSONValue], to url: URL) throws {
        let data = try writeJSONObject(object, prettyPrinted: true)
        try data.write(to: url, options: .atomic)
    }

    static func writeJSONObject(_ object: [String: MSPChatJSONValue], prettyPrinted: Bool) throws -> Data {
        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: object.mapValues { $0.toAny() }, options: options)
    }
}
