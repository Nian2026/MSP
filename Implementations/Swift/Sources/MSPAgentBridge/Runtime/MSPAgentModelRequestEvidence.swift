import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

struct MSPAgentModelRequestEvidence: Sendable {
    var runID: String
    var sequence: Int
    var model: String
    var inputCount: Int
    var userInputHashes: [String]
    var toolCount: Int
    var stream: String

    init(runID: String, sequence: Int, request: MSPAgentRequestEnvelope) {
        self.runID = runID
        self.sequence = sequence
        self.model = request.payload["model"]?.stringValue ?? ""
        self.inputCount = request.input.count
        self.userInputHashes = Self.requestUserInputTexts(request)
            .map(Self.sha256Hex)
        self.toolCount = request.payload["tools"]?.arrayValue?.count ?? 0
        self.stream = Self.stringField(request.payload["stream"])
    }

    var requestFields: [String: String] {
        commonFields.merging([
            "request_layer": "runtime_provider",
            "request_run_id": runID,
            "request_sequence": "\(sequence)",
            "model": model,
            "input_count": "\(inputCount)",
            "tool_count": "\(toolCount)",
            "stream": stream
        ]) { _, new in new }
    }

    var responseFields: [String: String] {
        commonFields.merging([
            "model_request_layer": "runtime_provider",
            "model_request_run_id": runID,
            "model_request_sequence": "\(sequence)",
            "model_request_model": model
        ]) { _, new in new }
    }

    private var commonFields: [String: String] {
        [
            "request_user_input_count": "\(userInputHashes.count)",
            "request_user_input_hash_algorithm": "sha256-utf8",
            "request_user_input_sha256s": userInputHashes.joined(separator: ","),
            "request_last_user_input_sha256": userInputHashes.last ?? ""
        ]
    }

    private static func requestUserInputTexts(_ request: MSPAgentRequestEnvelope) -> [String] {
        request.input
            .compactMap(\.objectValue)
            .filter { $0["type"]?.stringValue == "message" && $0["role"]?.stringValue == "user" }
            .map { message in
                (message["content"]?.arrayValue ?? [])
                    .compactMap(\.objectValue)
                    .filter { $0["type"]?.stringValue == "input_text" }
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n")
            }
    }

    private static func stringField(_ value: MSPAgentJSONValue?) -> String {
        switch value {
        case .string(let string):
            return string
        case .bool(let bool):
            return "\(bool)"
        case .number(let number):
            return "\(number)"
        case .object, .array, .null, nil:
            return ""
        }
    }

    static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        #if canImport(CryptoKit)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        #else
        return MSPAgentSHA256.digest(data)
            .map { String(format: "%02x", $0) }
            .joined()
        #endif
    }
}

#if !canImport(CryptoKit)
private enum MSPAgentSHA256 {
    static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        message.append(contentsOf: [
            UInt8((bitLength >> 56) & 0xff),
            UInt8((bitLength >> 48) & 0xff),
            UInt8((bitLength >> 40) & 0xff),
            UInt8((bitLength >> 32) & 0xff),
            UInt8((bitLength >> 24) & 0xff),
            UInt8((bitLength >> 16) & 0xff),
            UInt8((bitLength >> 8) & 0xff),
            UInt8(bitLength & 0xff)
        ])

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] =
                    UInt32(message[offset]) << 24 |
                    UInt32(message[offset + 1]) << 16 |
                    UInt32(message[offset + 2]) << 8 |
                    UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18)
                    ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16]
                    &+ s0
                    &+ words[index - 7]
                    &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
        }

        return [h0, h1, h2, h3, h4, h5, h6, h7].flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let constants: [UInt32] = [
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
}
#endif
