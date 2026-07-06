import Foundation
import MSPCore

struct MSPLsListingGroup {
    var rawPath: String
    var info: MSPFileInfo
}

func mspLsSections(
    groups: [MSPLsListingGroup],
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions
) throws -> String {
    var sections: [String] = []
    let multipleGroups = groups.count > 1
    let usesDirectorySections = groups.contains { $0.info.type == .directory && !options.directoryAsSelf }
    let sectionSeparator = usesDirectorySections
        ? options.lineTerminator + options.lineTerminator
        : options.lineTerminator

    for group in groups {
        if options.directoryAsSelf {
            sections.append(try mspLsListingBody(
                entries: [
                    MSPDirectoryEntry(
                        name: mspLsDisplayName(for: group),
                        info: group.info
                    )
                ],
                fileSystem: fileSystem,
                options: options,
                includeTotal: false
            ))
        } else if options.recursive, group.info.type == .directory {
            sections.append(try mspLsRecursiveListing(
                for: group.info,
                displayPath: mspLsDisplayName(for: group),
                fileSystem: fileSystem,
                options: options,
                includeHeader: true
            ))
        } else if group.info.type == .directory {
            let children = try mspLsSortedForListing(
                mspLsListedEntries(
                    for: group.info,
                    fileSystem: fileSystem,
                    options: options
                ),
                sortMode: options.sortMode,
                reverse: options.reverseSort
            )
            let body = try mspLsListingBody(
                entries: children,
                fileSystem: fileSystem,
                options: options,
                includeTotal: true
            )
            if multipleGroups {
                sections.append("\(mspLsDisplayName(for: group)):\(options.lineTerminator)\(body)")
            } else {
                sections.append(body)
            }
        } else {
            sections.append(try mspLsListingBody(
                entries: [
                    MSPDirectoryEntry(
                        name: mspLsDisplayName(for: group),
                        info: group.info
                    )
                ],
                fileSystem: fileSystem,
                options: options,
                includeTotal: false
            ))
        }
    }

    return sections.filter { !$0.isEmpty }.joined(separator: sectionSeparator)
}

func mspLsRecursiveListing(
    for directory: MSPFileInfo,
    displayPath: String,
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions,
    includeHeader: Bool
) throws -> String {
    let children = try mspLsSortedForListing(
        mspLsListedEntries(
            for: directory,
            fileSystem: fileSystem,
            options: options
        ),
        sortMode: options.sortMode,
        reverse: options.reverseSort
    )
    let body = try mspLsListingBody(
        entries: children,
        fileSystem: fileSystem,
        options: options,
        includeTotal: true
    )

    var sections: [String]
    if includeHeader {
        sections = [body.isEmpty ? "\(displayPath):" : "\(displayPath):\(options.lineTerminator)\(body)"]
    } else {
        sections = [body]
    }
    for child in children where child.info.type == .directory && child.name != "." && child.name != ".." {
        sections.append(try mspLsRecursiveListing(
            for: child.info,
            displayPath: mspLsChildDisplayPath(parent: displayPath, child: child.name),
            fileSystem: fileSystem,
            options: options,
            includeHeader: true
        ))
    }
    return sections.filter { !$0.isEmpty }.joined(
        separator: options.lineTerminator + options.lineTerminator
    )
}

func mspLsListedEntries(
    for directory: MSPFileInfo,
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions
) throws -> [MSPDirectoryEntry] {
    let entries = try fileSystem
        .listDirectory(directory.virtualPath, from: "/")
        .filter { entry in
            switch options.dotfileMode {
            case .visibleOnly:
                return !entry.name.hasPrefix(".")
            case .almostAll, .all:
                return true
            }
        }
    guard options.dotfileMode == .all else {
        return entries
    }

    let parentPath = mspLsParentVirtualPath(of: directory.virtualPath)
    let parentInfo = (try? fileSystem.stat(parentPath, from: "/")) ?? directory
    return [
        MSPDirectoryEntry(name: ".", info: directory),
        MSPDirectoryEntry(name: "..", info: parentInfo)
    ] + entries
}

func mspLsSortedForListing(
    _ entries: [MSPDirectoryEntry],
    sortMode: MSPLsSortMode,
    reverse: Bool
) throws -> [MSPDirectoryEntry] {
    let sortedByMode: [MSPDirectoryEntry]
    switch sortMode {
    case .none:
        sortedByMode = entries
    case .name:
        sortedByMode = entries.sorted {
            $0.name < $1.name
        }
    case .modifiedDate:
        sortedByMode = entries.sorted { lhs, rhs in
            if lhs.info.modificationDate != rhs.info.modificationDate {
                return (lhs.info.modificationDate ?? .distantPast) > (rhs.info.modificationDate ?? .distantPast)
            }
            return lhs.name < rhs.name
        }
    case .size:
        sortedByMode = entries.sorted { lhs, rhs in
            let lhsSize = MSPPOSIXCommandSupport.byteSize(lhs.info)
            let rhsSize = MSPPOSIXCommandSupport.byteSize(rhs.info)
            if lhsSize != rhsSize {
                return lhsSize > rhsSize
            }
            return lhs.name < rhs.name
        }
    }
    guard reverse else {
        return sortedByMode
    }
    return sortedByMode.reversed()
}

func mspLsDisplayName(for group: MSPLsListingGroup) -> String {
    group.rawPath.isEmpty ? "." : group.rawPath
}

func mspLsParentVirtualPath(of path: String) -> String {
    var components = MSPWorkspacePathResolver.components(in: path)
    guard !components.isEmpty else {
        return "/"
    }
    components.removeLast()
    guard !components.isEmpty else {
        return "/"
    }
    return "/" + components.joined(separator: "/")
}

func mspLsChildDisplayPath(parent: String, child: String) -> String {
    if parent == "/" {
        return "/" + child
    }
    if parent == "." {
        return "./" + child
    }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}
