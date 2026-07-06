import MSPCore

enum MSPPOSIXSedError {
    static func usage(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(exitCode: 1, stderr: lineTerminated(message)))
    }

    static func failure(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(stderr: lineTerminated(message)))
    }

    private static func lineTerminated(_ message: String) -> String {
        message.hasSuffix("\n") ? message : message + "\n"
    }
}
