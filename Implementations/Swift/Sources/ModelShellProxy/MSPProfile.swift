import MSPCore
import MSPPOSIXCore

public extension MSPProfile {
    static var posixCore: MSPProfile {
        posixCore(excluding: [])
    }

    static func posixCore(excluding excludedCommandNames: Set<String>) -> MSPProfile {
        MSPProfile(name: "posix-core") { registry in
            try MSPPOSIXCoreCommandPack(excluding: excludedCommandNames).registerCommands(into: registry)
        }
    }
}
