import Foundation

#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
enum ModelShellProxyPTYCanonicalPaste {
    static let macOSEOFVisualEraseEcho = Data([94, 68, 8, 8])

    private static let linuxCanonicalInputByteLimit = 4_095
    private static let darwinCanonicalBypassThreshold = 1_024

    struct Plan {
        var forwardedInput: Data
        var echoOutput: Data
        var nativeEchoOutput: Data
    }

    static func plan(for data: Data) -> Plan? {
        guard !data.isEmpty else {
            return nil
        }

        var forwardedInput = Data()
        var echoOutput = Data()
        var line = Data()
        var needsBypass = false
        for byte in data {
            guard !isUnsupportedCanonicalPasteControlByte(byte) else {
                return nil
            }
            if byte == 10 {
                if line.count > darwinCanonicalBypassThreshold {
                    needsBypass = true
                }
                forwardedInput.append(contentsOf: line.prefix(linuxCanonicalInputByteLimit))
                forwardedInput.append(10)
                echoOutput.append(13)
                echoOutput.append(10)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                echoOutput.append(byte)
            }
        }

        guard line.isEmpty, needsBypass else {
            return nil
        }
        return Plan(
            forwardedInput: forwardedInput,
            echoOutput: echoOutput,
            nativeEchoOutput: terminalEchoOutput(for: forwardedInput)
        )
    }

    private static func isUnsupportedCanonicalPasteControlByte(_ byte: UInt8) -> Bool {
        if byte == 127 {
            return true
        }
        if byte >= 32 {
            return false
        }
        return byte != 9 && byte != 10
    }

    private static func terminalEchoOutput(for data: Data) -> Data {
        var output = Data()
        for byte in data {
            if byte == 10 {
                output.append(13)
                output.append(10)
            } else {
                output.append(byte)
            }
        }
        return output
    }
}
#endif
