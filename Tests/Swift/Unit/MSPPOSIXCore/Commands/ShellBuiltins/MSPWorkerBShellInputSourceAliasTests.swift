import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPWorkerBShellInputSourceAliasTests: XCTestCase {
    func testAliasAndUnaliasLookupShouldReportShellBuiltins() async throws {
        let commandAlias = await runCommand("command", ["-v", "alias"])
        let commandUnalias = await runCommand("command", ["-v", "unalias"])
        let typeAlias = await runCommand("type", ["alias"])
        let typeUnalias = await runCommand("type", ["unalias"])

        let expectedFailure = XCTExpectedFailure.Options()
        expectedFailure.isStrict = false
        XCTExpectFailure(
            "Core100 B: alias and unalias need shared shell builtin registration and runtime state.",
            options: expectedFailure
        ) {
            XCTAssertEqual(commandAlias.exitCode, 0)
            XCTAssertEqual(commandAlias.stdout, "alias\n")
            XCTAssertEqual(commandUnalias.exitCode, 0)
            XCTAssertEqual(commandUnalias.stdout, "unalias\n")
            XCTAssertEqual(typeAlias.exitCode, 0)
            XCTAssertEqual(typeAlias.stdout, "alias is a shell builtin\n")
            XCTAssertEqual(typeUnalias.exitCode, 0)
            XCTAssertEqual(typeUnalias.stdout, "unalias is a shell builtin\n")
        }
    }

    private func runCommand(_ name: String, _ arguments: [String]) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        let subcommandRunner: MSPSubcommandRunner = { invocation, childContext in
            await executor.run(invocation: invocation, context: childContext)
        }
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(
                availableCommandNames: registry.commandNames,
                subcommandRunner: subcommandRunner
            )
        )
    }
}
