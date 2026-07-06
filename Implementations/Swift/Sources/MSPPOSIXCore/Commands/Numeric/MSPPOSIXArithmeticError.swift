import MSPCore

enum MSPPOSIXArithmeticError {
    static func usage(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure.usage(message.hasSuffix("\n") ? message : message + "\n")
    }
}
