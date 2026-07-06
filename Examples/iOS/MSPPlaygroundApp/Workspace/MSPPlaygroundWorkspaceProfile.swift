import Foundation
import ModelShellProxy
import MSPApple

enum MSPPlaygroundWorkspaceProfile: String, Equatable {
    case hostBacked = "host-backed"
    case mixedBackend = "mixed-backend"

    static func configured(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MSPPlaygroundWorkspaceProfile {
        let rawValue = argumentValue(named: "--msp-workspace-profile", in: arguments)
            ?? environment["MSP_PLAYGROUND_WORKSPACE_PROFILE"]
            ?? ""
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mixed", "mixed-backend", "mixed_backend":
            return .mixedBackend
        default:
            return .hostBacked
        }
    }

    func makeWorkspace(hostWorkspace: MSPAppleWorkspace) -> any MSPWorkspace {
        switch self {
        case .hostBacked:
            return hostWorkspace
        case .mixedBackend:
            return MSPCompositeWorkspace(
                baseFileSystem: hostWorkspace.fileSystem,
                mounts: [
                    MSPWorkspaceMount(path: "/media", fileSystem: Self.makeMediaFixture())
                ],
                policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
            )
        }
    }

    private static func makeMediaFixture() -> MSPPlaygroundMemoryFileSystem {
        MSPPlaygroundMemoryFileSystem(files: [
            "/clip.txt": Data("virtual-media\n".utf8)
        ])
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = name + "="
        if let inline = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }
}
