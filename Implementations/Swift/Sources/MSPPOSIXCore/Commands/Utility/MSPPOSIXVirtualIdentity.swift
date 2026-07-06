enum MSPPOSIXVirtualIdentity {
    static let profile = MSPPOSIXVirtualLinuxProfile()

    static let hostName = profile.hostName
    static let shortHostName = profile.shortHostName
    static let domainName = profile.domainName
    static let processorCount = profile.processorCount

    static let currentUser = MSPPOSIXVirtualUser(
        uid: 65_534,
        gid: 65_534,
        name: "nobody",
        groupName: "nogroup"
    )
    static let rootUser = MSPPOSIXVirtualUser(
        uid: 0,
        gid: 0,
        name: "root",
        groupName: "root"
    )

    static let unameFields: [MSPUnameField] = [
        .kernelName,
        .nodeName,
        .kernelRelease,
        .kernelVersion,
        .machine,
        .processor,
        .hardwarePlatform,
        .operatingSystem
    ]

    static func user(namedOrID name: String) -> MSPPOSIXVirtualUser? {
        switch name {
        case currentUser.name, "\(currentUser.uid)":
            return currentUser
        case rootUser.name, "\(rootUser.uid)":
            return rootUser
        default:
            return nil
        }
    }

    static func user(loginName name: String) -> MSPPOSIXVirtualUser? {
        switch name {
        case currentUser.name:
            return currentUser
        case rootUser.name:
            return rootUser
        default:
            return nil
        }
    }
}

struct MSPPOSIXVirtualLinuxProfile: Sendable, Equatable {
    var hostName = "happy-swan-1.localdomain"
    var shortHostName = "happy-swan-1"
    var domainName = "localdomain"
    var processorCount: UInt = 3
    var virtualTTYPath: String? = nil
}

struct MSPPOSIXVirtualUser: Sendable, Equatable {
    var uid: Int
    var gid: Int
    var name: String
    var groupName: String
}
