import MSPCore

struct MSPAppleWorkspaceTrashDisplayIndex {
    private let displayPathsByRecordID: [String: String]

    init(
        records: [MSPWorkspaceTrashRecord],
        configuration: MSPWorkspaceTrashConfiguration
    ) {
        guard let displayRootPath = configuration.displayRootPath else {
            displayPathsByRecordID = Dictionary(
                uniqueKeysWithValues: records.map { ($0.id, $0.originalPath) }
            )
            return
        }

        switch configuration.displayStyle {
        case .originalHierarchy:
            displayPathsByRecordID = Dictionary(
                uniqueKeysWithValues: records.map { record in
                    let path = record.originalPath == "/"
                        ? displayRootPath
                        : displayRootPath + record.originalPath
                    return (record.id, path)
                }
            )

        case .flat:
            var usedNames: Set<String> = []
            var paths: [String: String] = [:]
            for record in records.sorted(by: Self.recordOrdering) {
                let displayName = Self.uniqued(record.originalName, usedNames: &usedNames)
                paths[record.id] = MSPWorkspacePathResolver.normalize(
                    displayRootPath + "/" + displayName
                )
            }
            displayPathsByRecordID = paths
        }
    }

    func displayPath(for record: MSPWorkspaceTrashRecord) -> String {
        displayPathsByRecordID[record.id] ?? record.originalPath
    }

    private static func recordOrdering(
        _ first: MSPWorkspaceTrashRecord,
        _ second: MSPWorkspaceTrashRecord
    ) -> Bool {
        if first.trashedAt == second.trashedAt {
            return first.id < second.id
        }
        return first.trashedAt < second.trashedAt
    }

    private static func uniqued(
        _ rawName: String,
        usedNames: inout Set<String>
    ) -> String {
        guard usedNames.contains(rawName) else {
            usedNames.insert(rawName)
            return rawName
        }

        let dotIndex = rawName.lastIndex(of: ".")
        let base: String
        let suffix: String
        if let dotIndex, dotIndex != rawName.startIndex {
            base = String(rawName[..<dotIndex])
            suffix = String(rawName[dotIndex...])
        } else {
            base = rawName
            suffix = ""
        }

        var index = 2
        while true {
            let candidate = "\(base) \(index)\(suffix)"
            if !usedNames.contains(candidate) {
                usedNames.insert(candidate)
                return candidate
            }
            index += 1
        }
    }
}
