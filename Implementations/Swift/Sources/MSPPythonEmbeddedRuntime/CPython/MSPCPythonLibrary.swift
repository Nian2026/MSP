import Foundation

public enum MSPCPythonLibrary: Sendable, Equatable {
    case currentProcess
    case path(URL)
}
