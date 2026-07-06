import Foundation
import MSPChat
import MSPCore

public struct MSPChatReadCommand {
    public init() {}

    public func run(
        arguments: [String],
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try MSPChatReadOptionParser.parse(arguments, command: "chat read")
        guard parsed.positionals.count == 1 else {
            throw MSPCommandFailure.usage(Self.usage)
        }

        let displayPath = parsed.positionals[0]
        let packageURL = try resolvePackageURL(displayPath, context: context)

        do {
            let package = try MSPChatCoreReader().readPackage(at: packageURL)
            let projection = try MSPChatReadProjector.project(
                package,
                displayPath: displayPath,
                options: parsed.options
            )
            switch parsed.options.format {
            case .markdown:
                return .success(stdout: MSPChatReadMarkdownRenderer.markdown(for: projection) + "\n")
            case .json:
                return .success(stdout: try jsonString(for: projection) + "\n")
            }
        } catch let error as MSPChatReadProjectionError {
            switch error {
            case .invalidCursor(let cursor):
                throw MSPCommandFailure.usage("chat read: \(cursor): invalid conversation cursor\n")
            }
        } catch let error as MSPChatError {
            return .failure(stderr: "chat read: \(error.localizedDescription)\n")
        } catch {
            return .failure(stderr: "chat read: \(error.localizedDescription)\n")
        }
    }

    private func resolvePackageURL(
        _ path: String,
        context: MSPCommandContext
    ) throws -> URL {
        if let workspace = context.workspace {
            let resolved = try workspace.fileSystem.resolve(path, from: context.currentDirectory)
            if let physicalPath = resolved.physicalPath {
                return URL(fileURLWithPath: physicalPath, isDirectory: true).standardizedFileURL
            }
            throw MSPCommandFailure.usage("chat read: \(path): workspace path is not backed by a readable physical package\n")
        }

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        let basePath = context.currentDirectory.hasPrefix("/")
            ? context.currentDirectory
            : FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
            .standardizedFileURL
    }

    private func jsonString(for projection: MSPChatReadProjection) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(projection)
        return String(decoding: data, as: UTF8.self)
    }

    private static let usage = "chat read: usage: chat read <path> [--scope full|recent] [--cursor <cursor>] [--turn-limit <n>] [--include-outputs|--no-outputs] [--max-output-chars-per-item <n>]\n"
}
