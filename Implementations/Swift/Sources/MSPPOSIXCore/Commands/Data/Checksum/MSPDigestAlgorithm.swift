import CryptoKit
import Foundation
import MSPCore

public enum MSPDigestAlgorithm: Sendable, Equatable {
    case md5
    case sha1
    case sha224
    case sha256
    case sha384
    case sha512
    case sm3
    case blake2b(byteCount: Int)

    var label: String {
        switch self {
        case .md5:
            return "MD5"
        case .sha1:
            return "SHA1"
        case .sha224:
            return "SHA224"
        case .sha256:
            return "SHA256"
        case .sha384:
            return "SHA384"
        case .sha512:
            return "SHA512"
        case .sm3:
            return "SM3"
        case .blake2b:
            return "BLAKE2b"
        }
    }

    var tagLabel: String {
        switch self {
        case .blake2b(let byteCount) where byteCount < 64:
            return "BLAKE2b-\(byteCount * 8)"
        default:
            return label
        }
    }

    func digestHex(_ data: Data) -> String {
        switch self {
        case .md5:
            return mspPOSIXHexString(Insecure.MD5.hash(data: data))
        case .sha1:
            return mspPOSIXHexString(Insecure.SHA1.hash(data: data))
        case .sha224:
            var hasher = MSPSHA224()
            hasher.update(data)
            return mspPOSIXHexString(hasher.finalize())
        case .sha256:
            return mspPOSIXHexString(SHA256.hash(data: data))
        case .sha384:
            return mspPOSIXHexString(SHA384.hash(data: data))
        case .sha512:
            return mspPOSIXHexString(SHA512.hash(data: data))
        case .sm3:
            var hasher = MSPSM3()
            hasher.update(data)
            return mspPOSIXHexString(hasher.finalize())
        case .blake2b(let byteCount):
            var hasher = MSPBLAKE2b(outputByteCount: byteCount)
            hasher.update(data)
            return mspPOSIXHexString(hasher.finalize())
        }
    }

    func digestHex(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String
    ) throws -> String {
        switch self {
        case .md5:
            var hasher = Insecure.MD5()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(data: chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .sha1:
            var hasher = Insecure.SHA1()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(data: chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .sha224:
            var hasher = MSPSHA224()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .sha256:
            var hasher = SHA256()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(data: chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .sha384:
            var hasher = SHA384()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(data: chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .sha512:
            var hasher = SHA512()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(data: chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .sm3:
            var hasher = MSPSM3()
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        case .blake2b(let byteCount):
            var hasher = MSPBLAKE2b(outputByteCount: byteCount)
            try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
                hasher.update(chunk)
            }
            return mspPOSIXHexString(hasher.finalize())
        }
    }

    var hexLength: Int {
        switch self {
        case .md5:
            return 32
        case .sha1:
            return 40
        case .sha224:
            return 56
        case .sha256:
            return 64
        case .sha384:
            return 96
        case .sha512:
            return 128
        case .sm3:
            return 64
        case .blake2b(let byteCount):
            return byteCount * 2
        }
    }

    var supportsLengthOption: Bool {
        if case .blake2b = self {
            return true
        }
        return false
    }

    func effectiveAlgorithm(from options: [MSPPOSIXOption], command: String) throws -> MSPDigestAlgorithm {
        guard supportsLengthOption else {
            return self
        }
        var byteCount: Int?
        for option in options where option.matches(short: "l") || option.matches(long: "length") {
            guard let rawValue = option.value,
                  let bitCount = Int(rawValue),
                  bitCount > 0,
                  bitCount <= 512,
                  bitCount % 8 == 0 else {
                throw MSPCommandFailure(
                    result: .failure(
                        exitCode: 1,
                        stderr: "\(command): invalid length: \(MSPPOSIXCommandSupport.gnuQuote(option.value ?? ""))\n"
                    )
                )
            }
            byteCount = bitCount / 8
        }
        guard let byteCount else {
            return self
        }
        return .blake2b(byteCount: byteCount)
    }
}
