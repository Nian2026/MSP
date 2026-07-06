import MSPCore

public struct MSPCommandHelp: Sendable {
    public var commandName: String
    public var root: String
    public var topics: [String: String]
    public var topicAliases: [String: String]

    public init(
        commandName: String,
        root: String,
        topics: [String: String],
        topicAliases: [String: String] = [:]
    ) {
        self.commandName = commandName
        self.root = root
        self.topics = topics
        self.topicAliases = topicAliases
    }

    public func result(for arguments: [String]) -> MSPCommandResult? {
        guard !arguments.isEmpty else {
            return nil
        }

        let topic: [String]
        if arguments.first == "help" {
            topic = Array(arguments.dropFirst())
        } else if let helpIndex = arguments.firstIndex(where: Self.isHelpArgument) {
            topic = Array(arguments.prefix(upTo: helpIndex))
        } else {
            return nil
        }

        switch text(for: topic) {
        case .success(let text):
            return .success(stdout: text + "\n")
        case .failure(let message):
            return .failure(exitCode: 2, stderr: message + "\n")
        }
    }

    private func text(for topic: [String]) -> HelpTextResult {
        let key = topic.joined(separator: " ")
        if key.isEmpty {
            return .success(root)
        }
        let canonicalKey = topicAliases[key] ?? key
        guard let text = topics[canonicalKey] else {
            return .failure("\(commandName) help: unknown topic \(key)\n\n\(root)")
        }
        return .success(text)
    }

    private static func isHelpArgument(_ argument: String) -> Bool {
        argument == "--help" || argument == "-h"
    }
}

private enum HelpTextResult {
    case success(String)
    case failure(String)
}
