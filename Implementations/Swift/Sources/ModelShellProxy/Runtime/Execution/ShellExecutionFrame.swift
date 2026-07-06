import Foundation
import MSPCore

struct ShellExecutionFrame {
    var standardInput: Data
    var standardInputClosed: Bool
    var standardInputOverridesFileDescriptor: Bool
    var stdoutBindingOverride: MSPRedirectionOutputBinding?
    var stderrBindingOverride: MSPRedirectionOutputBinding?
    var appliesStateChange: Bool
    var lastExitCode: Int32
    var sourceLineNumber: Int?
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}
