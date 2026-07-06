import Foundation

struct FinalGateOracleFixtureURLs {
    let core100: URL
    let noninteractive: URL
    let liveNoninteractive: URL
    let pty: URL
}

extension ModelShellProxyPressureGateFixtureSupport {
    static var finalGateLinuxCharacterOracleAlignmentFixture: [String: Any] {
        [
            "kind": "linux-character-level-oracle-alignment",
            "oracle_report_keys": [
                "core100_noninteractive_oracle_report",
                "debian12_noninteractive_oracle_report",
                "live_noninteractive_linux_vps_oracle_report",
                "debian12_linux_pty_oracle_report"
            ],
            "checked_report_keys": [
                "core100_noninteractive_oracle_report",
                "debian12_linux_pty_oracle_report",
                "debian12_noninteractive_oracle_report",
                "live_noninteractive_linux_vps_oracle_report"
            ],
            "scope": [
                "stdout",
                "stderr",
                "exit code",
                "file tree",
                "cwd",
                "path errors",
                "permission errors",
                "Python traceback",
                "PTY bytes"
            ],
            "total_selected_case_count": 1_162,
            "total_passed_case_count": 1_162,
            "total_failed_case_count": 0,
            "all_counts_present": true,
            "all_character_oracle_cases_passed": true,
            "compatibility_adjustments_empty": true,
            "compatibility_adjustments": []
        ]
    }

    static func writeFinalGateOracleFixtures(rootURL: URL) throws -> FinalGateOracleFixtureURLs {
        let noninteractiveURL = rootURL.appendingPathComponent("debian12-noninteractive-oracle-report.json")
        let requiredDebianNoninteractiveCaseIDs = [
            "existing-coreutils-text-pipeline",
            "complex-dash-heredoc-functions-case",
            "complex-bash-process-substitution-arrays",
            "complex-dash-posix-ifs-glob-trap",
            "overlong-single-line-command",
            "python-subprocess-file-side-effects",
            "python-binary-stdout-stderr-bytes",
            "python-error-branch-permissions",
            "node-fs-child-process-side-effects",
            "stdin-binary-od-roundtrip",
            "permissions-umask-chmod-side-effects",
            "find-symlink-realpath-readlink",
            "existing-find-print0-xargs-weird-names",
            "find-print0-sortz-while-copy-unicode",
            "python-pathlib-stat-rglob-writeback",
            "binary-stdout-stderr-null-bytes"
        ]
        let debianNoninteractivePassedCaseIDs = requiredDebianNoninteractiveCaseIDs
            + (1...(50 - requiredDebianNoninteractiveCaseIDs.count)).map {
                "debian-noninteractive-case-\($0)"
            }
        try writeJSONObject([
            "failedCaseCount": 0,
            "failedCaseIDs": [],
            "failures": [],
            "selectedCaseCount": 50,
            "passedCaseCount": 50,
            "passedCaseIDs": debianNoninteractivePassedCaseIDs
        ], to: noninteractiveURL)

        let liveNoninteractiveURL = rootURL.appendingPathComponent("live-noninteractive-linux-vps-oracle-report.json")
        try writeJSONObject([
            "artifactKind": "msp-live-noninteractive-linux-vps-oracle",
            "gate": "msp-live-noninteractive-linux-vps-oracle",
            "passed": true,
            "liveRun": true,
            "runnerBackend": "ssh-linux-vps",
            "runnerHost": "root@example.invalid",
            "runnerPlatform": "Linux-6.1.0-debian12-x86_64-with-glibc2.36",
            "runnerSystem": "Linux",
            "runnerRelease": "6.1.0",
            "runnerMachine": "x86_64",
            "runnerPython": "3.11.2",
            "runnerOSRelease": "PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"\nID=debian\nVERSION_ID=\"12\"\nVERSION_CODENAME=bookworm\n",
            "fixtureCaseCount": 50,
            "failedCaseCount": 0,
            "failedCaseIDs": [],
            "failures": [],
            "runnerFailures": [],
            "selectedCaseCount": 50,
            "passedCaseCount": 50,
            "passedCaseIDs": debianNoninteractivePassedCaseIDs,
            "compatibilityAdjustments": []
        ], to: liveNoninteractiveURL)

        let core100URL = rootURL.appendingPathComponent("core100-noninteractive-oracle-report.json")
        var core100CommandCounts = Dictionary(uniqueKeysWithValues: (1...100).map { index in
            ("core100-command-\(index)", 1)
        })
        core100CommandCounts.merge([
            "pwd": 10,
            "ls": 6,
            "find": 31,
            "xargs": 5,
            "cat": 52,
            "rm": 4,
            "mv": 4,
            "mkdir": 70,
            "rmdir": 12,
            "stat": 32,
            "chmod": 5,
            "ln": 11,
            "touch": 9,
            "mktemp": 5,
            "printf": 676,
            "grep": 37,
            "awk": 5,
            "sed": 11,
            "sort": 73,
            "head": 24,
            "tail": 12,
            "wc": 24,
            "python3": 54,
            "sh": 2,
            "source": 13,
            "test": 19,
            "read": 16,
            "umask": 12,
            "dd": 21,
            "od": 46,
            "strings": 12,
            "xxd": 4
        ]) { _, new in new }
        let requiredCore100CaseIDs = [
            "stress-s0-pipeline-basic",
            "stress-s0-redirection-basic",
            "stress-s0-group-redirection",
            "stress-s1-many-redirections",
            "core100-source-cwd",
            "core100-source-fd",
            "core100-required-mktemp-tmpdir-relative",
            "core100-required-cat-large-file-short-consumer",
            "stress-s2-large-directory-find-head",
            "core100-required-find-exec-plus",
            "core100-required-xargs-batch",
            "stress-s2-xargs-batching-long-input",
            "core100-required-rm-recursive-relative",
            "core100-required-mv-target-dir",
            "core100-required-cat-missing",
            "core100-required-chmod-missing",
            "core100-dd-space-path",
            "core100-required-cat-binary-passthrough",
            "core100-required-sort-long-input-stress-count",
            "core100-required-grep-recursive-include-exclude"
        ]
        let core100PassedCaseIDs = requiredCore100CaseIDs + (1...(905 - requiredCore100CaseIDs.count)).map {
            "core100-fixture-case-\($0)"
        }
        try writeJSONObject([
            "failedCaseCount": 0,
            "failedCaseIDs": [],
            "failedLikelyLayerCounts": [:],
            "failures": [],
            "selectedCaseCount": 905,
            "passedCaseCount": 905,
            "passedCaseIDs": core100PassedCaseIDs,
            "selectedCommandCounts": core100CommandCounts
        ], to: core100URL)

        let ptyURL = rootURL.appendingPathComponent("debian12-linux-pty-oracle-report.json")
        let requiredDebianPTYCaseIDs = [
            "pty_basic_split",
            "pty_stderr_exit",
            "pty_ctrl_d_eof",
            "pty_ctrl_c",
            "pty_quoted_pipe_payload",
            "pty_long_canonical_12000",
            "pty_stty_noecho",
            "pty_python_heredoc_exit",
            "pty_erase_delete",
            "pty_ctrl_u_kill_line",
            "pty_ctrl_w_erase_word",
            "pty_shell_pipeline_wc",
            "pty_shell_heredoc_cat",
            "pty_shell_redirection_order",
            "pty_stdin_loop_utf8",
            "pty_python_large_output_4k",
            "pty_live_grep_sed_pipeline",
            "pty_live_long_stdin_wc_12000",
            "pty_live_python_stdin_script_split",
            "pty_live_python_stdin_script_stderr_exit"
        ]
        let debianPTYPassedCaseIDs = requiredDebianPTYCaseIDs + (1...(157 - requiredDebianPTYCaseIDs.count)).map {
            "debian-pty-case-\($0)"
        }
        try writeJSONObject([
            "failedCaseCount": 0,
            "failedCaseIDs": [],
            "failures": [],
            "selectedCaseCount": 157,
            "passedCaseCount": 157,
            "passedCaseIDs": debianPTYPassedCaseIDs,
            "runnerPlatform": "debian linux",
            "compatibilityAdjustments": []
        ], to: ptyURL)

        return FinalGateOracleFixtureURLs(
            core100: core100URL,
            noninteractive: noninteractiveURL,
            liveNoninteractive: liveNoninteractiveURL,
            pty: ptyURL
        )
    }
}
