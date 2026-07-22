import Foundation

/// Controls how recoverable trash records are projected under a configured display root.
public enum MSPWorkspaceTrashDisplayStyle: String, Sendable, Codable, Equatable {
    /// Recreates each record's original parent hierarchy below the display root.
    case originalHierarchy

    /// Presents every removed item directly under the display root with collision-safe names.
    case flat
}

public enum MSPWorkspaceTrashRestoreCollisionPolicy: String, Sendable, Codable, Equatable {
    case unique
    case failIfDestinationExists
}

public struct MSPWorkspaceTrashEmptyAuthorization: Sendable, Equatable {
    public var confirmationID: String
    public var confirmedAt: Date

    private init(confirmationID: String, confirmedAt: Date) {
        self.confirmationID = confirmationID
        self.confirmedAt = confirmedAt
    }

    public static func userConfirmed(
        confirmationID: String = UUID().uuidString,
        confirmedAt: Date = Date()
    ) -> MSPWorkspaceTrashEmptyAuthorization {
        MSPWorkspaceTrashEmptyAuthorization(
            confirmationID: confirmationID,
            confirmedAt: confirmedAt
        )
    }
}

public struct MSPWorkspaceTrashConfiguration: Sendable, Codable, Equatable {
    public var storageRootPath: String
    public var displayRootPath: String?
    public var displayStyle: MSPWorkspaceTrashDisplayStyle
    public var restoreCollisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy

    public init(
        storageRootPath: String = "/.msp/trash",
        displayRootPath: String? = nil,
        displayStyle: MSPWorkspaceTrashDisplayStyle = .originalHierarchy,
        restoreCollisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy = .unique
    ) {
        self.storageRootPath = MSPWorkspacePathResolver.normalize(storageRootPath)
        self.displayRootPath = displayRootPath.map {
            MSPWorkspacePathResolver.normalize($0)
        }
        self.displayStyle = displayStyle
        self.restoreCollisionPolicy = restoreCollisionPolicy
    }

    public static var `default`: MSPWorkspaceTrashConfiguration {
        MSPWorkspaceTrashConfiguration()
    }

    public static func displayedTrash(
        displayRootPath: String,
        storageRootPath: String = "/.msp/trash",
        displayStyle: MSPWorkspaceTrashDisplayStyle = .originalHierarchy
    ) -> MSPWorkspaceTrashConfiguration {
        MSPWorkspaceTrashConfiguration(
            storageRootPath: storageRootPath,
            displayRootPath: displayRootPath,
            displayStyle: displayStyle
        )
    }

    private enum CodingKeys: String, CodingKey {
        case storageRootPath
        case displayRootPath
        case displayStyle
        case restoreCollisionPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            storageRootPath: try container.decodeIfPresent(
                String.self,
                forKey: .storageRootPath
            ) ?? "/.msp/trash",
            displayRootPath: try container.decodeIfPresent(
                String.self,
                forKey: .displayRootPath
            ),
            displayStyle: try container.decodeIfPresent(
                MSPWorkspaceTrashDisplayStyle.self,
                forKey: .displayStyle
            ) ?? .originalHierarchy,
            restoreCollisionPolicy: try container.decodeIfPresent(
                MSPWorkspaceTrashRestoreCollisionPolicy.self,
                forKey: .restoreCollisionPolicy
            ) ?? .unique
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storageRootPath, forKey: .storageRootPath)
        try container.encodeIfPresent(displayRootPath, forKey: .displayRootPath)
        try container.encode(displayStyle, forKey: .displayStyle)
        try container.encode(restoreCollisionPolicy, forKey: .restoreCollisionPolicy)
    }
}

public struct MSPWorkspaceTrashRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var originalPath: String
    public var originalName: String
    public var trashPath: String
    public var isDirectory: Bool
    public var trashedAt: Date

    public init(
        id: String,
        originalPath: String,
        originalName: String,
        trashPath: String,
        isDirectory: Bool,
        trashedAt: Date
    ) {
        self.id = id
        self.originalPath = MSPWorkspacePathResolver.normalize(originalPath)
        self.originalName = originalName
        self.trashPath = MSPWorkspacePathResolver.normalize(trashPath)
        self.isDirectory = isDirectory
        self.trashedAt = trashedAt
    }
}

public struct MSPWorkspaceTrashRestoreSummary: Sendable, Codable, Equatable {
    public var originalPath: String
    public var restoredPath: String
    public var originalName: String
    public var isDirectory: Bool

    public init(
        originalPath: String,
        restoredPath: String,
        originalName: String,
        isDirectory: Bool
    ) {
        self.originalPath = MSPWorkspacePathResolver.normalize(originalPath)
        self.restoredPath = MSPWorkspacePathResolver.normalize(restoredPath)
        self.originalName = originalName
        self.isDirectory = isDirectory
    }
}

public protocol MSPWorkspaceTrashCapable: Sendable {
    var trashConfiguration: MSPWorkspaceTrashConfiguration? { get }

    func trashRecords() throws -> [MSPWorkspaceTrashRecord]
    func listTrash(_ path: String) throws -> [MSPDirectoryEntry]
    func restoreTrash(
        _ paths: [String],
        from currentDirectory: String,
        collisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy
    ) throws -> [MSPWorkspaceTrashRestoreSummary]
    func emptyTrash(authorization: MSPWorkspaceTrashEmptyAuthorization) throws -> Int
}

public extension MSPWorkspaceTrashCapable {
    func restoreTrash(
        _ paths: [String],
        collisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy = .unique
    ) throws -> [MSPWorkspaceTrashRestoreSummary] {
        try restoreTrash(paths, from: "/", collisionPolicy: collisionPolicy)
    }
}
