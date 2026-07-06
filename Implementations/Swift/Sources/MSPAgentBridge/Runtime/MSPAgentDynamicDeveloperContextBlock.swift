import Foundation

public struct MSPAgentDynamicDeveloperContextBlock: Sendable {
    public var id: String
    public var refresh: @Sendable () async -> String

    public init(
        id: String,
        refresh: @escaping @Sendable () async -> String
    ) {
        self.id = id
        self.refresh = refresh
    }

    public func resolve() async -> String {
        await refresh()
    }

    static func resolveAll(_ blocks: [MSPAgentDynamicDeveloperContextBlock]) async -> [String] {
        guard !blocks.isEmpty else {
            return []
        }

        return await withTaskGroup(of: (Int, String).self, returning: [String].self) { group in
            for (index, block) in blocks.enumerated() {
                group.addTask {
                    (index, await block.resolve())
                }
            }

            var resolved = Array(repeating: "", count: blocks.count)
            for await (index, text) in group {
                resolved[index] = text
            }
            return resolved
        }
    }
}
