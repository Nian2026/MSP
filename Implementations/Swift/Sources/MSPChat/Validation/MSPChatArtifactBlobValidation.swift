import Foundation

extension MSPChatValidationRun {
    mutating func validateEmbeddedArtifactBlobRefs(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validateReferenceArray(
            named: "artifact_refs",
            in: event,
            timelinePath: timelinePath,
            requiredIDField: nil
        )
        validateReferenceArray(
            named: "blob_refs",
            in: event,
            timelinePath: timelinePath,
            requiredIDField: "blob_id"
        )
    }

    mutating func validateStandaloneArtifactRef(_ event: MSPChatTimelineValidationEvent, timelinePath: String) {
        validateArtifactBlobReferencePayload(
            event.payload,
            timelinePath: timelinePath,
            line: event.line,
            eventID: event.id,
            context: "artifact_ref",
            requiredIDField: nil
        )
    }

    private mutating func validateReferenceArray(
        named field: String,
        in event: MSPChatTimelineValidationEvent,
        timelinePath: String,
        requiredIDField: String?
    ) {
        guard event.payload[field] != nil else {
            return
        }
        guard let refs = arrayOfDictionaries(event.payload[field]) else {
            error("\(field.replacingOccurrences(of: "_", with: "-"))-shape", "\(field) must be an array of objects.", path: timelinePath, line: event.line, eventID: event.id)
            return
        }
        for (index, ref) in refs.enumerated() {
            validateArtifactBlobReferencePayload(
                ref,
                timelinePath: timelinePath,
                line: event.line,
                eventID: event.id,
                context: "\(field)[\(index)]",
                requiredIDField: requiredIDField
            )
        }
    }

    private mutating func validateArtifactBlobReferencePayload(
        _ payload: [String: Any],
        timelinePath: String,
        line: Int,
        eventID: String,
        context: String,
        requiredIDField: String?
    ) {
        if let requiredIDField {
            if string(payload[requiredIDField]) == nil {
                error("blob-ref-id", "\(context) requires \(requiredIDField).", path: timelinePath, line: line, eventID: eventID)
            }
        } else if string(payload["artifact_id"]) == nil, string(payload["blob_id"]) == nil {
            error("artifact-ref-id", "\(context) requires artifact_id or blob_id.", path: timelinePath, line: line, eventID: eventID)
        }

        let status = string(payload["status"]) ?? "available"
        guard ["available", "missing", "redacted", "external_only"].contains(status) else {
            error("artifact-status", "\(context) status must be available, missing, redacted, or external_only.", path: timelinePath, line: line, eventID: eventID)
            return
        }

        guard status == "available" else {
            return
        }

        guard let relative = string(payload["path"]) else {
            error("artifact-path-required", "available \(context) requires a package-relative path.", path: timelinePath, line: line, eventID: eventID)
            return
        }
        guard let target = validatedPackageRelativeURL(relative, timelinePath: timelinePath, line: line, eventID: eventID, context: context) else {
            return
        }
        guard fileManager.fileExists(atPath: target.path) else {
            error("artifact-path-missing", "\(context) path does not exist in package.", path: timelinePath, line: line, eventID: eventID)
            return
        }

        validateReferenceSize(payload, target: target, timelinePath: timelinePath, line: line, eventID: eventID, context: context)
        validateReferenceHash(payload, target: target, timelinePath: timelinePath, line: line, eventID: eventID, context: context)
    }

    private mutating func validatedPackageRelativeURL(
        _ relative: String,
        timelinePath: String,
        line: Int,
        eventID: String,
        context: String
    ) -> URL? {
        if relative.isEmpty || relative.hasPrefix("/") || relative.contains("\\") {
            error("artifact-path-unsafe", "\(context) path must be package-relative.", path: timelinePath, line: line, eventID: eventID)
            return nil
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains("..") || components.contains(".") || components.contains("") {
            error("artifact-path-unsafe", "\(context) path must not contain empty, '.', or '..' components.", path: timelinePath, line: line, eventID: eventID)
            return nil
        }

        let target = packageURL.appendingPathComponent(relative).standardizedFileURL
        let packagePath = packageURL.standardizedFileURL.path
        if target.path != packagePath, target.path.hasPrefix(packagePath + "/") {
            return target
        }
        error("artifact-path-unsafe", "\(context) path escapes the package.", path: timelinePath, line: line, eventID: eventID)
        return nil
    }

    private mutating func validateReferenceSize(
        _ payload: [String: Any],
        target: URL,
        timelinePath: String,
        line: Int,
        eventID: String,
        context: String
    ) {
        guard let expectedSize = int(payload["size"]) ?? int(payload["byte_count"]) else {
            return
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: target.path)
            let actualSize = (attributes[.size] as? NSNumber)?.intValue
            if actualSize != expectedSize {
                error("artifact-size-mismatch", "\(context) declared size \(expectedSize) does not match package file size \(actualSize ?? -1).", path: timelinePath, line: line, eventID: eventID)
            }
        } catch let readError {
            error("artifact-size-read", "Could not read \(context) file size: \(readError.localizedDescription)", path: timelinePath, line: line, eventID: eventID)
        }
    }

    private mutating func validateReferenceHash(
        _ payload: [String: Any],
        target: URL,
        timelinePath: String,
        line: Int,
        eventID: String,
        context: String
    ) {
        guard let declaredHash = string(payload["hash"]) ?? string(payload["sha256"]) ?? string(payload["content_hash"]) else {
            return
        }
        guard let expectedSHA256 = normalizedSHA256(declaredHash) else {
            error("artifact-hash-format", "\(context) hash must be sha256:<hex> or a 64-character SHA-256 hex string.", path: timelinePath, line: line, eventID: eventID)
            return
        }
        do {
            let data = try Data(contentsOf: target)
            let actual = MSPChatSHA256.hexDigest(data)
            if actual != expectedSHA256 {
                error("artifact-hash-mismatch", "\(context) SHA-256 \(expectedSHA256) does not match package file hash \(actual).", path: timelinePath, line: line, eventID: eventID)
            }
        } catch let readError {
            error("artifact-hash-read", "Could not read \(context) file for hash validation: \(readError.localizedDescription)", path: timelinePath, line: line, eventID: eventID)
        }
    }

    private func normalizedSHA256(_ value: String) -> String? {
        let lower = value.lowercased()
        let hex: String
        if lower.hasPrefix("sha256:") {
            hex = String(lower.dropFirst("sha256:".count))
        } else {
            hex = lower
        }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return hex
    }
}

private enum MSPChatSHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hexDigest(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var hash = initialHash
        var words = Array(repeating: UInt32(0), count: 64)

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] =
                    UInt32(message[offset]) << 24 |
                    UInt32(message[offset + 1]) << 16 |
                    UInt32(message[offset + 2]) << 8 |
                    UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7) ^ rotateRight(words[index - 15], by: 18) ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17) ^ rotateRight(words[index - 2], by: 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ roundConstants[index] &+ words[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, by bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}
