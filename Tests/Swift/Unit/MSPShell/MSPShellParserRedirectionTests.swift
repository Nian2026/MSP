import MSPShell
import XCTest

extension MSPShellParserTests {
    func testParsesHereDocument() throws {
        let script = try MSPShellParser().parse("""
        cat <<EOF
        hello
        EOF
        """)

        XCTAssertEqual(script.pipelineCount, 1)
        XCTAssertEqual(script.commandNodeCount, 1)
        XCTAssertTrue(script.isSingleSimpleCommand)

        let parsed = try MSPShellParser().parseExecutableInvocation("""
            cat <<EOF
            hello
            EOF
            """)

        XCTAssertEqual(parsed.commandName, "cat")
        XCTAssertEqual(parsed.redirections.count, 1)
        XCTAssertEqual(parsed.redirections[0].operation, .hereDocument)
        XCTAssertEqual(parsed.redirections[0].hereDocumentBody, "hello\n")
    }

    func testParsesDescriptorAndReadWriteRedirections() throws {
        let duplicate = try MSPShellParser()
            .parseExecutableInvocation("missing-command 2>&1")
        let readWrite = try MSPShellParser()
            .parseExecutableInvocation("cat <> scratch.txt")

        XCTAssertEqual(duplicate.redirections.count, 1)
        XCTAssertEqual(duplicate.redirections[0].fd, 2)
        XCTAssertEqual(duplicate.redirections[0].operation, .duplicateOutput)
        XCTAssertEqual(duplicate.redirections[0].target, "1")
        XCTAssertEqual(readWrite.redirections.count, 1)
        XCTAssertEqual(readWrite.redirections[0].operation, .readWrite)
        XCTAssertEqual(readWrite.redirections[0].target, "scratch.txt")
    }
}
