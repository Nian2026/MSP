import MSPShell
import XCTest

extension MSPShellParserTests {
    func testRecognizesWhileReadWithLeadingAssignmentsAsDedicatedRuntimeForm() throws {
        let parsed = try MSPShellParser()
            .parseExecutablePipelines("while IFS= read -r item; do echo \"$item\"; done < input.txt")

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].commands[0].commandName, "while")
        XCTAssertEqual(parsed[0].commands[0].compoundKind, .whileRead)
        XCTAssertEqual(parsed[0].commands[0].redirections.count, 1)
        XCTAssertEqual(parsed[0].commands[0].redirections[0].operation, .input)
        XCTAssertEqual(parsed[0].commands[0].redirections[0].target, "input.txt")

        let multiCommand = try MSPShellParser().parseExecutablePipelines("""
        printf 'alpha\\n' > input.txt
        while IFS= read -r item; do echo "$item"; done < input.txt
        """)
        XCTAssertEqual(multiCommand.count, 2)
        XCTAssertEqual(multiCommand[1].commands[0].commandName, "while")
        XCTAssertEqual(multiCommand[1].commands[0].compoundKind, .whileRead)

        let nestedCase = try MSPShellParser().parseExecutablePipelines("""
        while IFS= read -r item; do
          case "$item" in
            *) printf 'OTHER:%s\\n' "$(printf '%s' "$item" | sed 's/a/A/g')" ;;
          esac
        done < input.txt
        """)
        guard case .whileRead(_, let body) = nestedCase[0].commands[0].compoundCommand else {
            return XCTFail("expected while-read compound command")
        }
        XCTAssertTrue(body.contains(#""$(printf '%s' "$item" | sed 's/a/A/g')""#))
        XCTAssertFalse(body.contains(#"\"$item\""#))

        let nestedIf = try MSPShellParser().parseExecutablePipelines("""
        while IFS= read -r p; do
          b=${p##*/}
          if [ -e "source/$b" ]; then
            if mv "source/$b" target/ 2>/dev/null; then
              moved=$((moved+1))
            else
              failed=$((failed+1))
            fi
          else
            skipped=$((skipped+1))
          fi
        done < input.txt
        """)
        guard case .whileRead(_, let structuredBody) = nestedIf[0].commands[0].structuredCompoundCommand else {
            return XCTFail("expected structured while-read compound command")
        }
        XCTAssertTrue(
            structuredBody.pipelines
                .flatMap(\.commands)
                .contains { $0.structuredCompoundCommand != nil }
        )
    }

    func testExtractsFunctionDefinitionsAsExecutableShellSemantics() throws {
        let parsed = try MSPShellParser().parseExecutablePipelines("""
        greet() { echo hi; }
        function wrap { echo "$1"; } > out.txt
        localcwd() ( cd docs; pwd )
        """)

        XCTAssertEqual(parsed.map(\.leadingOperator), [nil, .semicolon, .semicolon])
        XCTAssertEqual(parsed.map { $0.commands[0].commandName }, ["function", "function", "function"])
        XCTAssertEqual(parsed.map { $0.commands[0].arguments }, [["greet"], ["wrap"], ["localcwd"]])

        let greet = try XCTUnwrap(parsed[0].commands[0].functionDefinition)
        XCTAssertEqual(greet.name, "greet")
        XCTAssertEqual(greet.bodyKind, .braceGroup)
        XCTAssertEqual(greet.body, "echo hi")
        XCTAssertEqual(greet.redirections, [])

        let wrap = try XCTUnwrap(parsed[1].commands[0].functionDefinition)
        XCTAssertEqual(wrap.name, "wrap")
        XCTAssertEqual(wrap.bodyKind, .braceGroup)
        XCTAssertEqual(wrap.body, "echo \"$1\"")
        XCTAssertEqual(wrap.redirections.count, 1)
        XCTAssertEqual(wrap.redirections[0].operation, .output)
        XCTAssertEqual(wrap.redirections[0].target, "out.txt")

        let localcwd = try XCTUnwrap(parsed[2].commands[0].functionDefinition)
        XCTAssertEqual(localcwd.name, "localcwd")
        XCTAssertEqual(localcwd.bodyKind, .subshell)
        XCTAssertEqual(localcwd.body, "cd docs ; pwd")
    }

    func testExtractsStructuredCompoundCommandsAsExecutableShellSemantics() throws {
        let parsed = try MSPShellParser().parseExecutablePipelines("""
        if test -f a; then echo yes; elif false; then echo no; else echo maybe; fi
        while (( COUNT < 2 )); do echo $COUNT; (( COUNT++ )); done
        until true; do echo never; done
        for item in a b; do echo $item; done
        for (( i=0; i < 2; i++ )); do echo $i; done
        case $item in a) echo A ;; b|c) echo BC ;; esac
        """)

        XCTAssertEqual(parsed.map { $0.commands[0].compoundKind }, [
            .ifThen,
            .whileLoop,
            .untilLoop,
            .forEach,
            .cStyleFor,
            .caseOf
        ])
        guard case .ifThen(let branches, let elseBody) = parsed[0].commands[0].compoundCommand else {
            return XCTFail("expected if compound command")
        }
        XCTAssertEqual(branches.map(\.condition), ["test -f a", "false"])
        XCTAssertEqual(branches.map(\.body), ["echo yes", "echo no"])
        XCTAssertEqual(elseBody, "echo maybe")

        guard case .forEach(let variable, let values, let body) = parsed[3].commands[0].compoundCommand else {
            return XCTFail("expected for compound command")
        }
        XCTAssertEqual(variable, "item")
        XCTAssertEqual(body, "echo $item")
        XCTAssertEqual(values, .explicit([
            MSPParsedWord(parts: [.init(text: "a", isExpandable: true, isQuoted: false)]),
            MSPParsedWord(parts: [.init(text: "b", isExpandable: true, isQuoted: false)])
        ]))

        guard case .cStyleFor(let header, let cStyleBody) = parsed[4].commands[0].compoundCommand else {
            return XCTFail("expected c-style for compound command")
        }
        XCTAssertEqual(header.initExpression, "i=0")
        XCTAssertEqual(header.conditionExpression, "i < 2")
        XCTAssertEqual(header.updateExpression, "i++")
        XCTAssertEqual(cStyleBody, "echo $i")

        guard case .caseOf(let subject, let arms) = parsed[5].commands[0].compoundCommand else {
            return XCTFail("expected case compound command")
        }
        XCTAssertEqual(subject.rawText, "$item")
        XCTAssertEqual(arms.count, 2)
        XCTAssertEqual(arms[0].body, "echo A")
        XCTAssertEqual(arms[1].patterns.map(\.rawText), ["b", "c"])
    }

    func testKeepsShellControlCommandsInsideCompoundBodies() throws {
        let parsed = try MSPShellParser().parseExecutablePipelines("""
        for item in a b; do echo $item; break; continue; exit 7; done
        case $item in a) continue ;; b) break ;; *) exit 9 ;; esac
        """)

        guard case .forEach(_, _, let forBody) = parsed[0].commands[0].compoundCommand else {
            return XCTFail("expected for compound command")
        }
        XCTAssertEqual(forBody, "echo $item ; break ; continue ; exit 7")

        guard case .caseOf(_, let arms) = parsed[1].commands[0].compoundCommand else {
            return XCTFail("expected case compound command")
        }
        XCTAssertEqual(arms.map(\.body), ["continue", "break", "exit 9"])
    }
}
