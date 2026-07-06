import Foundation

public struct MSPResolvedPath: Sendable, Equatable {
    public var virtualPath: String
    public var physicalPath: String?

    public init(virtualPath: String, physicalPath: String? = nil) {
        self.virtualPath = virtualPath
        self.physicalPath = physicalPath
    }
}

public enum MSPFileType: String, Sendable, Equatable, Hashable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public struct MSPDirectoryEnumerationOptions: Sendable, Equatable {
    public var typeFilter: Set<MSPFileType>?

    public init(typeFilter: Set<MSPFileType>? = nil) {
        self.typeFilter = typeFilter
    }

    public static let all = MSPDirectoryEnumerationOptions()

    public func includes(_ type: MSPFileType) -> Bool {
        typeFilter?.contains(type) ?? true
    }
}

public struct MSPFileInfo: Sendable, Equatable {
    public var virtualPath: String
    public var type: MSPFileType
    public var size: Int64?
    public var modificationDate: Date?
    public var permissions: UInt16?
    public var symbolicLinkTarget: String?
    public var fileIdentity: String?

    public init(
        virtualPath: String,
        type: MSPFileType,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        symbolicLinkTarget: String? = nil,
        fileIdentity: String? = nil
    ) {
        self.virtualPath = virtualPath
        self.type = type
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.symbolicLinkTarget = symbolicLinkTarget
        self.fileIdentity = fileIdentity
    }

    public var isDirectory: Bool {
        type == .directory
    }
}

public struct MSPDirectoryEntry: Sendable, Equatable {
    public var name: String
    public var info: MSPFileInfo

    public init(name: String, info: MSPFileInfo) {
        self.name = name
        self.info = info
    }

    public var virtualPath: String {
        info.virtualPath
    }

    public var type: MSPFileType {
        info.type
    }
}

public struct MSPFileWriteOptions: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let overwriteExisting = MSPFileWriteOptions(rawValue: 1 << 0)
    public static let createParentDirectories = MSPFileWriteOptions(rawValue: 1 << 1)
    public static let atomic = MSPFileWriteOptions(rawValue: 1 << 2)
}

public struct MSPFileCopyOptions: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let recursive = MSPFileCopyOptions(rawValue: 1 << 0)
    public static let overwriteExisting = MSPFileCopyOptions(rawValue: 1 << 1)
    public static let createParentDirectories = MSPFileCopyOptions(rawValue: 1 << 2)
}

public struct MSPFileCopyRequest: Sendable, Equatable {
    public var sourcePath: String
    public var destinationPath: String

    public init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public struct MSPFileMoveOptions: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let overwriteExisting = MSPFileMoveOptions(rawValue: 1 << 0)
    public static let createParentDirectories = MSPFileMoveOptions(rawValue: 1 << 1)
}

public enum MSPWorkspaceFileSystemError: Error, Equatable, CustomStringConvertible {
    case accessDenied(String)
    case hiddenPath(String)
    case invalidPath(String)
    case notFound(String)
    case notDirectory(String)
    case isDirectory(String)
    case directoryNotEmpty(String)
    case notSymbolicLink(String)
    case alreadyExists(String)
    case encodingFailed(String)
    case io(path: String, operation: String)

    public var description: String {
        switch self {
        case .accessDenied(let path):
            return "workspace access denied: \(path)"
        case .hiddenPath(let path):
            return "workspace path is hidden: \(path)"
        case .invalidPath(let path):
            return "invalid workspace path: \(path)"
        case .notFound(let path):
            return "workspace path not found: \(path)"
        case .notDirectory(let path):
            return "workspace path is not a directory: \(path)"
        case .isDirectory(let path):
            return "workspace path is a directory: \(path)"
        case .directoryNotEmpty(let path):
            return "workspace directory is not empty: \(path)"
        case .notSymbolicLink(let path):
            return "workspace path is not a symbolic link: \(path)"
        case .alreadyExists(let path):
            return "workspace path already exists: \(path)"
        case .encodingFailed(let path):
            return "workspace text encoding failed: \(path)"
        case .io(let path, let operation):
            return "workspace \(operation) failed: \(path)"
        }
    }
}
