import MSPCore
import MSPShell

extension ModelShellProxy {
    func shellExpansionContext(
        lastExitCode: Int32,
        enablesPathnameExpansion: Bool = true,
        enablesWordSplitting: Bool = true,
        requiresPathnameCandidates: Bool = true
    ) async throws -> MSPShellExpansionContext {
        try await runtime.shellExpansionContext(
            lastExitCode: lastExitCode,
            enablesPathnameExpansion: enablesPathnameExpansion,
            enablesWordSplitting: enablesWordSplitting,
            requiresPathnameCandidates: requiresPathnameCandidates,
            pathnameCandidates: { [self] in
                try await pathnameExpansionCandidates()
            }
        )
    }

    private func pathnameExpansionCandidates() async throws -> [String] {
        guard let workspace = configuration.workspace else {
            return []
        }
        var candidates: [String] = []
        let fileSystem = workspace.fileSystem

        func walk(_ path: String) async throws {
            try await fileSystem.enumerateDirectory(path, from: "/") { entry in
                candidates.append(entry.virtualPath)
                if entry.type == .directory {
                    try await walk(entry.virtualPath)
                }
                return true
            }
        }

        try await walk("/")
        return candidates
    }
}
