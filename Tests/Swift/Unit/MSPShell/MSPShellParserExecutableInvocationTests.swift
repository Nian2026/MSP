import MSPShell
import XCTest

extension MSPShellParserTests {
    func testExtractsSingleSimpleCommandWithQuotedArguments() throws {
        let parsed = try MSPShellParser()
            .parseExecutableInvocation("hello 'two words' \"three words\"")

        XCTAssertEqual(parsed.commandName, "hello")
        XCTAssertEqual(parsed.arguments, ["two words", "three words"])
    }

    func testExtractsAssignmentPrefixedAndAssignmentOnlyCommands() throws {
        let prefixed = try MSPShellParser()
            .parseExecutableInvocation("FOO='two words' BAR=baz env")
        let assignmentOnly = try MSPShellParser()
            .parseExecutableInvocation("FOO=bar")

        XCTAssertEqual(prefixed.commandName, "env")
        XCTAssertEqual(
            prefixed.assignments,
            [
                MSPParsedAssignment(name: "FOO", value: "two words"),
                MSPParsedAssignment(name: "BAR", value: "baz")
            ]
        )
        XCTAssertFalse(prefixed.isAssignmentOnly)
        XCTAssertEqual(assignmentOnly.commandName, ":")
        XCTAssertEqual(assignmentOnly.assignments, [MSPParsedAssignment(name: "FOO", value: "bar")])
        XCTAssertTrue(assignmentOnly.isAssignmentOnly)
    }

    func testParsesPipelineWithoutTreatingItAsSimpleInvocation() throws {
        let script = try MSPShellParser().parse("ls -la | grep pdf")

        XCTAssertEqual(script.pipelineCount, 1)
        XCTAssertEqual(script.commandNodeCount, 2)
        XCTAssertFalse(script.isSingleSimpleCommand)

        XCTAssertThrowsError(
            try MSPShellParser().parseExecutableInvocation("ls -la | grep pdf")
        ) { error in
            XCTAssertEqual(
                error as? MSPShellParserError,
                .unsupportedExecutionForm("shell: execution for this shell form is not implemented yet")
            )
        }
    }

    func testExtractsExecutablePipelines() throws {
        let pipelines = try MSPShellParser()
            .parseExecutablePipelines("printf 'abc' | wc -c; cat missing |& wc -c")

        XCTAssertEqual(pipelines.count, 2)
        XCTAssertEqual(pipelines[0].commands.map(\.commandName), ["printf", "wc"])
        XCTAssertEqual(pipelines[0].commands.map(\.arguments), [["abc"], ["-c"]])
        XCTAssertEqual(pipelines[0].pipeOperators, [.stdout])
        XCTAssertEqual(pipelines[1].commands.map(\.commandName), ["cat", "wc"])
        XCTAssertEqual(pipelines[1].pipeOperators, [.stdoutAndStderr])
    }

    func testExtractsDoubleBracketConditionalAsExecutableCommand() throws {
        let pipelines = try MSPShellParser()
            .parseExecutablePipelines("[[ 3 -gt 2 ]]")

        XCTAssertEqual(pipelines.count, 1)
        XCTAssertEqual(pipelines[0].commands.map(\.commandName), ["[["])
        XCTAssertEqual(pipelines[0].commands[0].arguments, ["3", "-gt", "2", "]]"])
    }

    func testParsesAndOrList() throws {
        let script = try MSPShellParser().parse("mkdir out && cp a.txt out/")

        XCTAssertEqual(script.pipelineCount, 2)
        XCTAssertEqual(script.commandNodeCount, 2)
        XCTAssertFalse(script.isSingleSimpleCommand)
    }

    func testExtractsExecutableConditionalListOperators() throws {
        let parsed = try MSPShellParser()
            .parseExecutablePipelines("false && echo skipped || echo fallback; echo done")

        XCTAssertEqual(parsed.map(\.leadingOperator), [nil, .and, .or, .semicolon])
        XCTAssertEqual(parsed.map { $0.commands.map(\.commandName) }, [["false"], ["echo"], ["echo"], ["echo"]])
        XCTAssertEqual(parsed.map { $0.commands.flatMap(\.arguments) }, [[], ["skipped"], ["fallback"], ["done"]])
    }

    func testExtractsSemicolonSeparatedExecutableInvocations() throws {
        let parsed = try MSPShellParser()
            .parseExecutableInvocations("pwd; ls /docs; cat 'two words.txt'")

        XCTAssertEqual(parsed.map(\.commandName), ["pwd", "ls", "cat"])
        XCTAssertEqual(parsed.map(\.arguments), [[], ["/docs"], ["two words.txt"]])
    }

    func testExtractsNewlineSeparatedExecutableInvocations() throws {
        let parsed = try MSPShellParser()
            .parseExecutableInvocations("""
            pwd
            ls /
            """)

        XCTAssertEqual(parsed.map(\.commandName), ["pwd", "ls"])
        XCTAssertEqual(parsed.map(\.arguments), [[], ["/"]])
    }

    func testExtractsConditionalExecutableInvocationLists() throws {
        let parsed = try MSPShellParser()
            .parseExecutablePipelines("test -d docs && ls docs")

        XCTAssertEqual(parsed.map(\.leadingOperator), [nil, .and])
        XCTAssertEqual(parsed.flatMap(\.commands).map(\.commandName), ["test", "ls"])
    }

    func testExtractsNegatedPipelineAsSharedShellSemantic() throws {
        let parsed = try MSPShellParser()
            .parseExecutablePipelines("! false && echo yes")

        XCTAssertEqual(parsed.map(\.isNegated), [true, false])
        XCTAssertEqual(parsed.map(\.leadingOperator), [nil, .and])
        XCTAssertEqual(parsed.map { $0.commands.map(\.commandName) }, [["false"], ["echo"]])
    }

    func testExtractsArithmeticCommandAsExecutableShellSemantic() throws {
        let parsed = try MSPShellParser()
            .parseExecutablePipelines("(( COUNT += 2 )) && echo yes; (( 1 )) > out.txt")

        XCTAssertEqual(parsed.map(\.leadingOperator), [nil, .and, .semicolon])
        XCTAssertEqual(parsed.map { $0.commands.map(\.commandName) }, [["(("], ["echo"], ["(("]])
        XCTAssertEqual(parsed[0].commands[0].arithmeticExpression, " COUNT += 2 ")
        XCTAssertEqual(parsed[0].commands[0].arguments, [" COUNT += 2 ", "))"])
        XCTAssertEqual(parsed[2].commands[0].arithmeticExpression, " 1 ")
        XCTAssertEqual(parsed[2].commands[0].redirections.count, 1)
        XCTAssertEqual(parsed[2].commands[0].redirections[0].operation, .output)
        XCTAssertEqual(parsed[2].commands[0].redirections[0].target, "out.txt")
    }

    func testExtractsGroupAndSubshellCompoundCommandsAsExecutableShellSemantics() throws {
        let parsed = try MSPShellParser()
            .parseExecutablePipelines("{ FOO=bar; echo $FOO; } > out.txt; ( cd docs; pwd )")

        XCTAssertEqual(parsed.map(\.leadingOperator), [nil, .semicolon])
        XCTAssertEqual(parsed[0].commands[0].commandName, "{")
        XCTAssertEqual(parsed[0].commands[0].compoundKind, .group)
        XCTAssertEqual(parsed[0].commands[0].compoundBody, "FOO=bar ; echo $FOO")
        XCTAssertEqual(parsed[0].commands[0].redirections.count, 1)
        XCTAssertEqual(parsed[0].commands[0].redirections[0].operation, .output)
        XCTAssertEqual(parsed[0].commands[0].redirections[0].target, "out.txt")
        XCTAssertEqual(parsed[1].commands[0].commandName, "(")
        XCTAssertEqual(parsed[1].commands[0].compoundKind, .subshell)
        XCTAssertEqual(parsed[1].commands[0].compoundBody, "cd docs ; pwd")
        XCTAssertFalse(parsed[0].commands[0].compoundBody?.contains("'$FOO'") ?? true)
    }
}
