import Foundation

enum MSPBaseEncodingKind {
    case base64
    case base64URL
    case base32
    case base32Hex
    case base16
    case base2MSBF
    case base2LSBF

    var inputGroupSize: Int {
        switch self {
        case .base64, .base64URL:
            return 3
        case .base32, .base32Hex:
            return 5
        case .base16, .base2MSBF, .base2LSBF:
            return 1
        }
    }

    var decodeBlockSize: Int {
        switch self {
        case .base64, .base64URL:
            return 4
        case .base32, .base32Hex:
            return 8
        case .base16:
            return 2
        case .base2MSBF, .base2LSBF:
            return 8
        }
    }

    var allowsPadding: Bool {
        switch self {
        case .base64, .base64URL, .base32, .base32Hex:
            return true
        case .base16, .base2MSBF, .base2LSBF:
            return false
        }
    }

    func encode(_ data: Data) -> String {
        switch self {
        case .base64:
            return data.base64EncodedString()
        case .base64URL:
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        case .base32:
            return mspBaseEncodingBase32Encode(data, alphabet: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8))
        case .base32Hex:
            return mspBaseEncodingBase32Encode(data, alphabet: Array("0123456789ABCDEFGHIJKLMNOPQRSTUV".utf8))
        case .base16:
            return data.map { String(format: "%02X", $0) }.joined()
        case .base2MSBF:
            return data.map { byte in
                (0..<8).reversed().map { ((byte >> UInt8($0)) & 1) == 1 ? "1" : "0" }.joined()
            }.joined()
        case .base2LSBF:
            return data.map { byte in
                (0..<8).map { ((byte >> UInt8($0)) & 1) == 1 ? "1" : "0" }.joined()
            }.joined()
        }
    }

    func decode(_ data: Data, ignoreGarbage: Bool) -> MSPBaseEncodingDecodeResult {
        var decoder = MSPBaseEncodingStreamingDecoder(kind: self, ignoreGarbage: ignoreGarbage)
        decoder.append(data)
        return decoder.finalize()
    }

    func value(for byte: UInt8) -> UInt8? {
        switch self {
        case .base64:
            return mspBaseEncodingBase64Value(byte)
        case .base64URL:
            if byte == UInt8(ascii: "-") {
                return 62
            }
            if byte == UInt8(ascii: "_") {
                return 63
            }
            return mspBaseEncodingBase64Value(byte)
        case .base32:
            return mspBaseEncodingBase32Value(byte, alphabet: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8))
        case .base32Hex:
            return mspBaseEncodingBase32Value(byte, alphabet: Array("0123456789ABCDEFGHIJKLMNOPQRSTUV".utf8))
        case .base16:
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                return byte - UInt8(ascii: "0")
            }
            if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "F") {
                return byte - UInt8(ascii: "A") + 10
            }
            return nil
        case .base2MSBF, .base2LSBF:
            if byte == UInt8(ascii: "0") {
                return 0
            }
            if byte == UInt8(ascii: "1") {
                return 1
            }
            return nil
        }
    }
}
