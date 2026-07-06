import Foundation

struct IORedirectionReadWriteFile {
    var data: Data
    var virtualPath: String
}

struct IORedirectionEnvironment {
    var readInput: (String) throws -> Data
    var openReadWriteFile: (String) throws -> IORedirectionReadWriteFile
    var makeOutputSink: (String, Bool) throws -> MSPRedirectionFileSink
    var writeFileOutput: (Data, String, Bool) throws -> Void
    var readVirtualPath: (String) throws -> Data
    var writeVirtualPath: (String, Data) throws -> Void
    var diagnosticReason: (Error) -> String
    var redirectionFailure: (String) -> Error
    var commandFailure: (Int32, String) -> Error
}

struct IORedirectionInputResolution {
    var data: Data
    var descriptionID: Int?
    var isClosed: Bool
}
