import Foundation
import XCTest
import MSPApple
import MSPCore
import MSPExternalRunner

final class MSPExternalCommandPathMapperTests: XCTestCase {
    func testMapsArgumentsOptionValuesFileURLsAndEnvironmentPathLists() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/docs")
        let mapper = MSPExternalCommandPathMapper(
            executableURL: URL(fileURLWithPath: "/runtime/bin/qpdf")
        )

        let mappedArguments = try mapper.arguments(
            [
                "/docs/input.pdf",
                "--replace-input=/docs/output.pdf",
                "file:///docs/other%20input.pdf",
                "--linearize"
            ],
            context: context
        )

        XCTAssertEqual(mappedArguments[0], rootURL.path + "/docs/input.pdf")
        XCTAssertEqual(mappedArguments[1], "--replace-input=" + rootURL.path + "/docs/output.pdf")
        XCTAssertEqual(
            mappedArguments[2],
            rootURL.appendingPathComponent("docs/other input.pdf").standardizedFileURL.absoluteString
        )
        XCTAssertEqual(mappedArguments[3], "--linearize")

        let environment = try mapper.environment(
            request: MSPExternalCommandRequest(
                executableName: "qpdf",
                arguments: [],
                environment: [
                    "INPUT": "/docs/input.pdf",
                    "SEARCH": "/docs:/tmp",
                    "REMOTE": "https://example.com/input.pdf"
                ],
                workingDirectory: "/docs"
            ),
            context: context
        )

        XCTAssertEqual(environment["HOME"], rootURL.path)
        XCTAssertEqual(environment["PWD"], rootURL.path + "/docs")
        XCTAssertEqual(environment["TMPDIR"], rootURL.path + "/tmp")
        XCTAssertEqual(environment["MSP_WORKSPACE_ROOT"], rootURL.path)
        XCTAssertEqual(environment["INPUT"], rootURL.path + "/docs/input.pdf")
        XCTAssertEqual(environment["SEARCH"], rootURL.path + "/docs:" + rootURL.path + "/tmp")
        XCTAssertEqual(environment["REMOTE"], "https://example.com/input.pdf")
        XCTAssertEqual(
            environment["PATH"],
            "/runtime/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
    }

    func testSanitizerRestoresWorkspaceAndRuntimePathsForModelOutput() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let context = MSPCommandContext(workspace: workspace)
        let mapper = MSPExternalCommandPathMapper(
            executableURL: URL(fileURLWithPath: "/runtime/bin/qpdf")
        )
        let sanitizer = try mapper.outputSanitizer(context: context)

        let hostFileURL = rootURL
            .appendingPathComponent("docs/report file.pdf")
            .standardizedFileURL
            .absoluteString
        let sanitized = sanitizer.sanitize(
            "INPUT=\(rootURL.path)/docs/input.pdf\n"
                + "INPUT_URL=\(hostFileURL)\n"
                + "SELF=/runtime/bin/qpdf\n"
        )

        XCTAssertEqual(
            sanitized,
            "INPUT=/docs/input.pdf\n"
                + "INPUT_URL=file:///docs/report%20file.pdf\n"
                + "SELF=/usr/local/bin/qpdf\n"
        )
        XCTAssertFalse(sanitized.contains(rootURL.path))
        XCTAssertFalse(sanitized.contains("/runtime/bin"))
    }

    func testRejectsWorkspaceWithoutPhysicalMapping() throws {
        let mapper = MSPExternalCommandPathMapper(
            executableURL: URL(fileURLWithPath: "/runtime/bin/qpdf")
        )
        let context = MSPCommandContext()

        XCTAssertThrowsError(
            try mapper.workingDirectoryURL(virtualPath: "/", context: context)
        ) { error in
            XCTAssertEqual(
                error as? MSPExternalCommandPathMapperError,
                .missingWorkspace
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPExternalCommandPathMapperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
