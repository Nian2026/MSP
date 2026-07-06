import MSPShell
import XCTest

extension MSPShellParserTests {
    func testCommandSubstitutionInsideDoubleQuotesPreservesNestedArrayQuotes() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf 'SUB:%s\n' "$(printf '%s' "${rows[*]}" | wc -c)""#
        )
        XCTAssertEqual(
            parsed.argumentWords.map(\.rawText),
            ["SUB:%s\\n", #"$(printf '%s' "${rows[*]}" | wc -c)"#]
        )
        let expansion = MSPShellExpansionContext(
            arrays: ["rows": MSPShellIndexedArray(["alpha", "beta", "zeta"])]
        )
        let commandLog = MSPShellParserCommandSubstitutionLog()
        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: expansion,
            resolver: { command in
                await commandLog.append(command)
                return MSPShellCommandSubstitutionResult(stdout: "15\n")
            }
        )

        let observedCommands = await commandLog.commands
        XCTAssertEqual(observedCommands, [#"printf '%s' "${rows[*]}" | wc -c"#])
        XCTAssertEqual(expanded.commandLine.commandName, "printf")
        XCTAssertEqual(expanded.commandLine.arguments, ["SUB:%s\\n", "15"])
    }

    func testAsyncTextExpansionScannerResolvesCommandSubstitutionsInOrder() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' "$(one)" "`two words`" "$((N + 2))" "${WORD}""#
        )
        let commandLog = MSPShellParserCommandSubstitutionLog()
        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(environment: ["N": "3", "WORD": "alpha"]),
            resolver: { command in
                await commandLog.append(command)
                return MSPShellCommandSubstitutionResult(
                    stdout: "out:\(command)\n\n",
                    stderr: "err:\(command)\n"
                )
            }
        )

        let observedCommands = await commandLog.commands
        XCTAssertEqual(observedCommands, ["one", "two words"])
        XCTAssertEqual(expanded.stderr, "err:one\nerr:two words\n")
        XCTAssertEqual(expanded.commandLine.commandName, "printf")
        XCTAssertEqual(
            expanded.commandLine.arguments,
            ["%s\\n", "out:one", "out:two words", "5", "alpha"]
        )
    }

    func testAsyncSubstitutionEffectsStayOrderedAcrossCommandAndProcessSubstitution() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' <(one) "$(two)" >(three)"#
        )
        let commandLog = MSPShellParserCommandSubstitutionLog()
        let processLog = MSPShellParserCommandSubstitutionLog()
        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(),
            resolver: { command in
                await commandLog.append(command)
                return MSPShellCommandSubstitutionResult(
                    stdout: "cmd:\(command)\n\n",
                    stderr: "stderr:cmd:\(command)\n"
                )
            },
            processSubstitutionResolver: { request in
                await processLog.append("\(request.mode.operatorText):\(request.command)")
                return MSPShellProcessSubstitutionResult(
                    path: "/tmp/\(request.mode.rawValue)-\(request.command)",
                    stderr: "stderr:\(request.mode.operatorText):\(request.command)\n"
                )
            }
        )

        let observedCommands = await commandLog.commands
        let observedProcesses = await processLog.commands
        XCTAssertEqual(observedCommands, ["two"])
        XCTAssertEqual(observedProcesses, ["<:one", ">:three"])
        XCTAssertEqual(expanded.stderr, "stderr:<:one\nstderr:cmd:two\nstderr:>:three\n")
        XCTAssertEqual(
            expanded.commandLine.arguments,
            ["%s\\n", "/tmp/I-one", "cmd:two", "/tmp/O-three"]
        )
    }

    func testAsyncParameterOperationEffectsStayOrdered() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' "$(one)" "${value:=$(two)}" "$(three)" "$value""#
        )
        let commandLog = MSPShellParserCommandSubstitutionLog()
        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(),
            resolver: { command in
                await commandLog.append(command)
                return MSPShellCommandSubstitutionResult(
                    stdout: "\(command)\n",
                    stderr: "stderr:\(command)\n"
                )
            }
        )

        let observedCommands = await commandLog.commands
        XCTAssertEqual(observedCommands, ["one", "two", "three"])
        XCTAssertEqual(expanded.stderr, "stderr:one\nstderr:two\nstderr:three\n")
        XCTAssertEqual(expanded.environment["value"], "two")
        XCTAssertEqual(
            expanded.commandLine.arguments,
            ["%s\\n", "one", "two", "three", "two"]
        )
    }

    func testAsyncAssociativeArrayDefaultAssignmentExpandsKeyOnce() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' "${map[$(key)]:=stored}" "${map["a b"]}""#
        )
        let commandLog = MSPShellParserCommandSubstitutionLog()
        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(associativeArrays: ["map": [:]]),
            resolver: { command in
                await commandLog.append(command)
                return MSPShellCommandSubstitutionResult(stdout: "a b\n", stderr: "key-stderr\n")
            }
        )

        let observedCommands = await commandLog.commands
        XCTAssertEqual(observedCommands, ["key"])
        XCTAssertEqual(expanded.stderr, "key-stderr\n")
        XCTAssertEqual(expanded.associativeArrays["map"]?["a b"], "stored")
        XCTAssertEqual(expanded.commandLine.arguments, ["%s\\n", "stored", "stored"])
    }

    func testAsyncDefaultAssignmentExpansionReturnsMutatedEnvironment() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' "${MISSING:=fallback}" "$MISSING""#
        )

        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(),
            resolver: { _ in MSPShellCommandSubstitutionResult() }
        )

        XCTAssertEqual(expanded.commandLine.commandName, "printf")
        XCTAssertEqual(expanded.commandLine.arguments, ["%s\\n", "fallback", "fallback"])
        XCTAssertEqual(expanded.environment["MISSING"], "fallback")
    }

    func testAsyncDefaultAssignmentExpansionReturnsMutatedShellValues() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' "${ref:=scalar}" "$target" "${arr[1]:=array}" "${arr[1]}" "${map["a b"]:-present}" "${map[$(key)]:-fallback}""#
        )
        let commandLog = MSPShellParserCommandSubstitutionLog()
        let expanded = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(
                associativeArrays: ["map": ["a b": "present"]],
                namerefVariables: ["ref": "target"]
            ),
            resolver: { command in
                await commandLog.append(command)
                return MSPShellCommandSubstitutionResult(stdout: "a b\n", stderr: "key-stderr\n")
            }
        )

        let observedCommands = await commandLog.commands
        XCTAssertEqual(observedCommands, ["key"])
        XCTAssertEqual(expanded.stderr, "key-stderr\n")
        XCTAssertEqual(
            expanded.commandLine.arguments,
            ["%s\\n", "scalar", "scalar", "array", "array", "present", "present"]
        )
        XCTAssertEqual(expanded.environment["target"], "scalar")
        XCTAssertNil(expanded.environment["ref"])
        XCTAssertEqual(expanded.arrays["arr"]?[1], "array")
        XCTAssertEqual(expanded.associativeArrays["map"]?["a b"], "present")
    }

    func testExpansionResultsExposeUnifiedStateAndCompatibilityFields() async throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            #"printf '%s\n' "${value:=$(cmd)}""#
        )
        let commandExpansion = try await parsed.expandedResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(),
            resolver: { command in
                MSPShellCommandSubstitutionResult(stdout: "\(command)-stored\n")
            }
        )

        XCTAssertEqual(commandExpansion.state.environment["value"], "cmd-stored")
        XCTAssertEqual(commandExpansion.environment["value"], commandExpansion.state.environment["value"])

        var mutableCommandExpansion = commandExpansion
        mutableCommandExpansion.environment["compat"] = "yes"
        XCTAssertEqual(mutableCommandExpansion.state.environment["compat"], "yes")

        let textWord = MSPParsedWord(parts: [
            .init(
                text: #"${ref:=scalar}:${arr[1]:=array}:${map[$(key)]:=stored}"#,
                isExpandable: true,
                isQuoted: true
            )
        ])
        let textExpansion = try await textWord.expandedTextResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(
                associativeArrays: ["map": [:]],
                namerefVariables: ["ref": "target"]
            ),
            resolver: { command in
                MSPShellCommandSubstitutionResult(stdout: "\(command)-slot\n", stderr: "stderr:\(command)\n")
            }
        )

        XCTAssertEqual(textExpansion.value, "scalar:array:stored")
        XCTAssertEqual(textExpansion.stderr, "stderr:key\n")
        XCTAssertEqual(textExpansion.state.environment["target"], "scalar")
        XCTAssertEqual(textExpansion.state.arrays["arr"]?[1], "array")
        XCTAssertEqual(textExpansion.state.associativeArrays["map"]?["key-slot"], "stored")
        XCTAssertEqual(textExpansion.environment["target"], textExpansion.state.environment["target"])
        XCTAssertEqual(textExpansion.arrays["arr"]?[1], textExpansion.state.arrays["arr"]?[1])
        XCTAssertEqual(
            textExpansion.associativeArrays["map"]?["key-slot"],
            textExpansion.state.associativeArrays["map"]?["key-slot"]
        )

        let variantsWord = MSPParsedWord(parts: [
            .init(text: #"${next:=one two}"#, isExpandable: true, isQuoted: false)
        ])
        let variantsExpansion = try await variantsWord.expandedVariantsResolvingCommandSubstitutions(
            in: MSPShellExpansionContext(),
            resolver: { _ in MSPShellCommandSubstitutionResult() }
        )

        XCTAssertEqual(variantsExpansion.values, ["one", "two"])
        XCTAssertEqual(variantsExpansion.state.environment["next"], "one two")
        XCTAssertEqual(variantsExpansion.environment["next"], variantsExpansion.state.environment["next"])
    }
}

private actor MSPShellParserCommandSubstitutionLog {
    private var storage: [String] = []

    var commands: [String] {
        storage
    }

    func append(_ command: String) {
        storage.append(command)
    }
}
