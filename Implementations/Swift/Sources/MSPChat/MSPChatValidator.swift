import Foundation

public struct MSPChatValidator {
    public static let version = "0.1.0"

    public init() {}

    public func validate(packageAt packageURL: URL) -> MSPChatValidationReport {
        var run = MSPChatValidationRun(packageURL: packageURL.standardizedFileURL)
        run.validate()
        return run.report()
    }
}
