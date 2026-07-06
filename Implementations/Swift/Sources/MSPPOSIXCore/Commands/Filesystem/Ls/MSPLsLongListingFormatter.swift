import Foundation
import MSPCore

struct MSPLsLongListingRow {
    var mode: String
    var linkCount: Int
    var owner: String
    var group: String
    var sizeText: String
    var timestamp: String
    var name: String
    var allocatedKilobytes: Int64
}

struct MSPLsLongListingWidths {
    var linkCount: Int
    var owner: Int
    var group: Int
    var size: Int

    init(rows: [MSPLsLongListingRow]) {
        linkCount = max(1, rows.map { String($0.linkCount).count }.max() ?? 1)
        owner = max(1, rows.map(\.owner.count).max() ?? 1)
        group = max(1, rows.map(\.group.count).max() ?? 1)
        size = max(1, rows.map(\.sizeText.count).max() ?? 1)
    }
}

func mspLsListingBody(
    entries: [MSPDirectoryEntry],
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions,
    includeTotal: Bool
) throws -> String {
    guard options.long else {
        return entries
            .map(\.name)
            .joined(separator: options.lineTerminator)
    }

    let rows = entries.map { entry in
        mspLsLongListingRow(for: entry, fileSystem: fileSystem, options: options)
    }
    var lines: [String] = []
    if includeTotal {
        lines.append(mspLsLongListingTotalLine(rows: rows, options: options))
    }
    let widths = MSPLsLongListingWidths(rows: rows)
    lines.append(contentsOf: rows.map { mspLsLongListingLine(row: $0, widths: widths) })
    return lines.joined(separator: options.lineTerminator)
}

func mspLsLongListingRow(
    for entry: MSPDirectoryEntry,
    fileSystem: any MSPWorkspaceFileSystem,
    options: MSPLsListingOptions
) -> MSPLsLongListingRow {
    let bytes = mspLsLongListingByteSize(entry.info)
    let sizeText = options.humanReadable ? MSPPOSIXCommandSupport.humanSize(bytes) : String(bytes)
    let displayName: String
    if entry.info.type == .symbolicLink, let target = entry.info.symbolicLinkTarget {
        displayName = "\(entry.name) -> \(target)"
    } else {
        displayName = entry.name
    }
    return MSPLsLongListingRow(
        mode: MSPPOSIXCommandSupport.modeString(for: entry.info),
        linkCount: mspLsLongListingLinkCount(for: entry.info, fileSystem: fileSystem),
        owner: MSPPOSIXVirtualIdentity.currentUser.name,
        group: MSPPOSIXVirtualIdentity.currentUser.groupName,
        sizeText: sizeText,
        timestamp: mspLsLongListingTimestamp(entry.info.modificationDate),
        name: displayName,
        allocatedKilobytes: mspLsLongListingAllocatedKilobytes(entry.info)
    )
}

func mspLsLongListingLine(
    row: MSPLsLongListingRow,
    widths: MSPLsLongListingWidths
) -> String {
    [
        row.mode,
        mspLsPadLeft(String(row.linkCount), width: widths.linkCount),
        mspLsPadRight(row.owner, width: widths.owner),
        mspLsPadRight(row.group, width: widths.group),
        mspLsPadLeft(row.sizeText, width: widths.size),
        row.timestamp,
        row.name
    ].joined(separator: " ")
}

func mspLsLongListingTotalLine(
    rows: [MSPLsLongListingRow],
    options: MSPLsListingOptions
) -> String {
    let total = rows.reduce(Int64(0)) { $0 + $1.allocatedKilobytes }
    if options.humanReadable {
        return "total \(MSPPOSIXCommandSupport.humanSize(total * 1024))"
    }
    return "total \(total)"
}

func mspLsLongListingLinkCount(
    for info: MSPFileInfo,
    fileSystem: any MSPWorkspaceFileSystem
) -> Int {
    guard info.type == .directory else {
        return 1
    }
    guard let children = try? fileSystem.listDirectory(info.virtualPath, from: "/") else {
        return 2
    }
    let childDirectoryCount = children.filter { $0.info.type == .directory }.count
    return max(2, 2 + childDirectoryCount)
}

func mspLsLongListingByteSize(_ info: MSPFileInfo) -> Int64 {
    if info.type == .symbolicLink,
       info.size == nil,
       let target = info.symbolicLinkTarget {
        return Int64(target.utf8.count)
    }
    return MSPPOSIXCommandSupport.byteSize(info)
}

func mspLsLongListingAllocatedKilobytes(_ info: MSPFileInfo) -> Int64 {
    switch info.type {
    case .directory:
        return 4
    case .symbolicLink:
        return 0
    case .regularFile, .other:
        let bytes = mspLsLongListingByteSize(info)
        guard bytes > 0 else {
            return 0
        }
        return ((bytes + 4095) / 4096) * 4
    }
}

func mspLsLongListingTimestamp(_ date: Date?) -> String {
    let date = date ?? Date(timeIntervalSince1970: 0)
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents(in: timeZone, from: date)
    let month = mspLsLongListingMonth(date)
    let day = String(format: "%2d", components.day ?? 1)

    let now = Date()
    let sixMonths: TimeInterval = 60 * 60 * 24 * 365 / 2
    let isOld = now.timeIntervalSince(date) > sixMonths
    let isFuture = date.timeIntervalSince(now) > 60 * 60
    if isOld || isFuture {
        return "\(month) \(day)  \(String(format: "%04d", components.year ?? 1970))"
    }
    return "\(month) \(day) \(String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0))"
}

func mspLsLongListingMonth(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MMM"
    return formatter.string(from: date)
}

func mspLsPadLeft(_ value: String, width: Int) -> String {
    guard value.count < width else {
        return value
    }
    return String(repeating: " ", count: width - value.count) + value
}

func mspLsPadRight(_ value: String, width: Int) -> String {
    guard value.count < width else {
        return value
    }
    return value + String(repeating: " ", count: width - value.count)
}
