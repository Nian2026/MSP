import Foundation
import MSPCore

func mspLsStreamingDirectoryListingIsSafe(
    options: MSPLsListingOptions,
    operands: [String]
) -> Bool {
    options.sortMode == .none
        && !options.reverseSort
        && !options.long
        && !options.directoryAsSelf
        && operands.count <= 1
}

func mspLsStreamListedEntries(
    for directory: MSPFileInfo,
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions,
    standardOutput: any MSPCommandOutputStream
) async throws {
    if options.dotfileMode == .all {
        try await standardOutput.write(Data(".".utf8))
        try await standardOutput.write(Data(options.lineTerminator.utf8))
        try await standardOutput.write(Data("..".utf8))
        try await standardOutput.write(Data(options.lineTerminator.utf8))
    }

    try await fileSystem.enumerateDirectory(directory.virtualPath, from: "/") { entry in
        switch options.dotfileMode {
        case .visibleOnly where entry.name.hasPrefix("."):
            return true
        case .visibleOnly, .almostAll, .all:
            break
        }
        try await standardOutput.write(Data(entry.name.utf8))
        try await standardOutput.write(Data(options.lineTerminator.utf8))
        return true
    }
}

func mspLsStreamRecursiveListedEntries(
    for directory: MSPFileInfo,
    displayPath: String,
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions,
    standardOutput: any MSPCommandOutputStream,
    isFirstSection: inout Bool
) async throws {
    if isFirstSection {
        isFirstSection = false
    } else {
        try await standardOutput.write(Data(options.lineTerminator.utf8))
    }
    try await standardOutput.write(Data("\(displayPath):\(options.lineTerminator)".utf8))

    var childDirectories: [(name: String, info: MSPFileInfo)] = []
    if options.dotfileMode == .all {
        try await standardOutput.write(Data(".".utf8))
        try await standardOutput.write(Data(options.lineTerminator.utf8))
        try await standardOutput.write(Data("..".utf8))
        try await standardOutput.write(Data(options.lineTerminator.utf8))
    }

    try await fileSystem.enumerateDirectory(directory.virtualPath, from: "/") { entry in
        switch options.dotfileMode {
        case .visibleOnly where entry.name.hasPrefix("."):
            return true
        case .visibleOnly, .almostAll, .all:
            break
        }
        try await standardOutput.write(Data(entry.name.utf8))
        try await standardOutput.write(Data(options.lineTerminator.utf8))
        if entry.info.type == .directory {
            childDirectories.append((entry.name, entry.info))
        }
        return true
    }

    for child in childDirectories where child.name != "." && child.name != ".." {
        try await mspLsStreamRecursiveListedEntries(
            for: child.info,
            displayPath: mspLsChildDisplayPath(parent: displayPath, child: child.name),
            fileSystem: fileSystem,
            options: options,
            standardOutput: standardOutput,
            isFirstSection: &isFirstSection
        )
    }
}
