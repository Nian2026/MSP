public enum MSPWorkspacePathResolver {
    public static func normalize(_ path: String, from currentDirectory: String = "/") -> String {
        let baseComponents: [String]
        if path.hasPrefix("/") {
            baseComponents = []
        } else {
            baseComponents = normalizedComponents(in: currentDirectory, startingWith: [])
        }

        let normalized = normalizedComponents(in: path, startingWith: baseComponents)
        guard !normalized.isEmpty else {
            return "/"
        }
        return "/" + normalized.joined(separator: "/")
    }

    public static func components(in virtualPath: String) -> [String] {
        virtualPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public static func isSyntacticallyValid(_ path: String) -> Bool {
        !path.contains("\0")
    }

    private static func normalizedComponents(
        in path: String,
        startingWith initialComponents: [String]
    ) -> [String] {
        var normalized = initialComponents
        for component in components(in: path) {
            switch component {
            case ".", "":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }
        return normalized
    }
}
