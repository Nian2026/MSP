import Foundation
import MSPCore

func rgDisplayPath(for argument: String, resolvedPath: String, isImplicitRoot: Bool) -> String {
    if isImplicitRoot, argument == "." {
        return ""
    }
    if argument.hasPrefix("/") {
        return resolvedPath
    }
    return argument.isEmpty ? "." : argument
}

func rgJoinDisplayPath(_ parent: String, _ child: String) -> String {
    switch parent {
    case "":
        return child
    case "/":
        return "/" + child
    case ".":
        return "./" + child
    default:
        return parent.hasSuffix("/") ? parent + child : parent + "/" + child
    }
}

func rgFileSystemDiagnostic(path: String, error: Error) -> String {
    "\(MSPPOSIXCommandSupport.displayPath(path)): \(rgDiagnosticReason(from: error))"
}

private func rgDiagnosticReason(from error: Error) -> String {
    guard let fileSystemError = error as? MSPWorkspaceFileSystemError else {
        return MSPPOSIXCommandSupport.diagnosticReason(from: error)
    }
    switch fileSystemError {
    case .accessDenied, .hiddenPath:
        return "Permission denied (os error 13)"
    case .invalidPath:
        return "Invalid argument (os error 22)"
    case .notFound:
        return "No such file or directory (os error 2)"
    case .notDirectory:
        return "Not a directory (os error 20)"
    case .isDirectory:
        return "Is a directory (os error 21)"
    case .directoryNotEmpty:
        return "Directory not empty (os error 39)"
    case .notSymbolicLink:
        return "Invalid argument (os error 22)"
    case .alreadyExists:
        return "File exists (os error 17)"
    case .encodingFailed:
        return "Invalid or incomplete multibyte or wide character"
    case .io:
        return "Input/output error (os error 5)"
    }
}
