import XCTest
@testable import MSPPythonRuntime

final class MSPPythonBootstrapSourceTests: XCTestCase {
    func testVirtualFileSystemBootstrapSourceJoinsOwnerSectionsInOrder() {
        let sections = [
            MSPPythonVFSBootstrapPreludeSource.source,
            MSPPythonVFSBootstrapFileSystemSource.source,
            MSPPythonVFSBootstrapTracebackSource.source,
            MSPPythonVFSBootstrapSubprocessSource.source,
            MSPPythonVFSBootstrapPatchSource.source,
        ]

        let source = MSPPythonVirtualFileSystemBootstrapSource.source

        XCTAssertEqual(source, sections.joined(separator: "\n\n"))
        XCTAssertTrue(source.hasPrefix("import atexit as _msp_vfs_atexit\n"))
        XCTAssertContainsInOrder(
            source,
            [
                "def _msp_vfs_install_audit_hook():",
                "def _msp_vfs_existing_bytes(virtual_path):",
                "def _msp_vfs_virtualize_traceback_lines(lines):",
                "_MSP_VFS_PREVIOUS_PATCHES = {}",
                "def _msp_vfs_capture_patch(name, getter):",
                "_msp_vfs_atexit.register(_msp_vfs_flush_pending_writebacks)",
                "_msp_install_python_vfs()"
            ]
        )
    }

    func testVFSPreludeBootstrapSourceJoinsOwnerSectionsInOrder() {
        let sections = [
            MSPPythonVFSBootstrapPreludeImportsSource.source,
            MSPPythonVFSBootstrapOriginalsSource.source,
            MSPPythonVFSBootstrapRuntimeEnvironmentSource.source,
            MSPPythonVFSBootstrapRuntimePathMappingSource.source,
            MSPPythonVFSBootstrapRuntimePolicySource.source,
            MSPPythonVFSBootstrapPathConversionSource.source,
            MSPPythonVFSBootstrapBrokerRequestSource.source,
            MSPPythonVFSBootstrapTextOpenSource.source,
            MSPPythonVFSBootstrapAuditHookSource.source,
        ]

        let source = MSPPythonVFSBootstrapPreludeSource.source

        XCTAssertEqual(source, sections.joined(separator: "\n\n"))
        XCTAssertTrue(source.hasPrefix("import atexit as _msp_vfs_atexit\n"))
        XCTAssertContainsInOrder(
            source,
            [
                "_MSP_VFS_ORIGINALS_NAME = \"__msp_python_vfs_originals__\"",
                "def _msp_vfs_norm_or_empty(value):",
                "def _msp_vfs_register_runtime_virtual_path(real_path, virtual_path):",
                "def _msp_vfs_under(path, prefix):",
                "def _msp_vfs_virtualize_real_path(value):",
                "def _msp_vfs_error(response):",
                "def _msp_vfs_mode_writes(mode):",
                "def _msp_vfs_audit_hook(event, args):",
                "def _msp_vfs_install_audit_hook():"
            ]
        )
    }

    func testVFSFileSystemBootstrapSourceJoinsOwnerSectionsInOrder() {
        let sections = [
            MSPPythonVFSBootstrapFileMaterializationSource.source,
            MSPPythonVFSBootstrapFileOpenSource.source,
            MSPPythonVFSBootstrapFileMetadataSource.source,
            MSPPythonVFSBootstrapFileOperationsSource.source,
            MSPPythonVFSBootstrapPathQuerySource.source,
            MSPPythonVFSBootstrapShutilSource.source,
            MSPPythonVFSBootstrapPathlibSource.source,
            MSPPythonVFSBootstrapOutputVirtualizationSource.source,
        ]

        let source = MSPPythonVFSBootstrapFileSystemSource.source

        XCTAssertEqual(source, sections.joined(separator: "\n\n"))
        XCTAssertContainsInOrder(
            source,
            [
                "def _msp_vfs_existing_bytes(virtual_path):",
                "def _msp_vfs_file_display_name(file, virtual_path):",
                "def _msp_vfs_info_mode(info):",
                "def _msp_vfs_mkdir(path, mode=0o777, *args, **kwargs):",
                "def _msp_vfs_chdir(path):",
                "def _msp_vfs_copyfile(src, dst, *args, **kwargs):",
                "def _msp_vfs_pathlib_virtual_str(self):",
                "class _MSPVirtualizingTextWriter:"
            ]
        )
    }

    func testSubprocessBootstrapSourceJoinsOwnerSectionsInOrder() {
        let sections = [
            MSPPythonVFSBootstrapSubprocessCoreSource.source,
            MSPPythonVFSBootstrapSubprocessRunSource.source,
            MSPPythonVFSBootstrapSubprocessPipesSource.source,
            MSPPythonVFSBootstrapSubprocessPopenSource.source,
            MSPPythonVFSBootstrapSubprocessOSSource.source,
        ]

        let source = MSPPythonVFSBootstrapSubprocessSource.source

        XCTAssertEqual(source, sections.joined(separator: "\n\n"))
        XCTAssertContainsInOrder(
            source,
            [
                "def _msp_vfs_subprocess_run(args, input=None",
                "class _MSPPythonInputPipe(",
                "class _MSPPythonPopen:",
                "def _msp_vfs_os_system(command):"
            ]
        )
    }

    func testVFSBrokerResponsePollingBypassesVirtualizedPathExists() {
        let source = MSPPythonVFSBootstrapPreludeSource.source

        XCTAssertContainsInOrder(
            source,
            [
                "_MSP_VFS_REAL_PATH_EXISTS = _MSP_VFS_ORIGINALS[\"os_path_exists\"]",
                "def _msp_vfs_request(action, **payload):",
                "while not _MSP_VFS_REAL_PATH_EXISTS(response_path):",
                "with _MSP_VFS_REAL_OPEN(response_path, \"r\", encoding=\"utf-8\") as response_file:"
            ]
        )

        guard
            let requestStart = source.range(of: "def _msp_vfs_request(action, **payload):"),
            let readStart = source.range(of: "with _MSP_VFS_REAL_OPEN(response_path, \"r\", encoding=\"utf-8\") as response_file:", range: requestStart.upperBound..<source.endIndex)
        else {
            XCTFail("Missing VFS request response-polling markers")
            return
        }

        let pollingBody = source[requestStart.upperBound..<readStart.lowerBound]
        XCTAssertFalse(
            pollingBody.contains("_msp_vfs_os.path.exists(response_path)"),
            "VFS broker response polling must use the captured real os.path.exists, otherwise patched exists recursively emits broker requests."
        )
    }

    func testVFSInternalRuntimePrefixesTakePrecedenceOverWorkspaceVirtualization() {
        let source = MSPPythonVFSBootstrapPreludeSource.source

        XCTAssertContainsInOrder(
            source,
            [
                "def _msp_vfs_is_internal_real_path(value):",
                "if any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_internal_write_prefixes()):",
                "return True",
                "if _MSP_VFS_WORKSPACE_ROOT and _msp_vfs_under(absolute, _MSP_VFS_WORKSPACE_ROOT):",
                "return False",
                "return any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_runtime_read_prefixes())"
            ]
        )

        XCTAssertContainsInOrder(
            source,
            [
                "def _msp_vfs_real_path_allowed(value, write=False, allow_chdir=False):",
                "if any(_msp_vfs_under(absolute, prefix) for prefix in _msp_vfs_internal_write_prefixes()):",
                "return True",
                "if _MSP_VFS_WORKSPACE_ROOT and _msp_vfs_under(absolute, _MSP_VFS_WORKSPACE_ROOT):",
                "return False"
            ]
        )
    }

    func testVFSStatResultsExposePlatformFieldsForShutilCopystat() {
        let source = MSPPythonVirtualFileSystemBootstrapSource.source

        XCTAssertContainsInOrder(
            source,
            [
                "\"os_chflags\": getattr(_msp_vfs_os, \"chflags\", None)",
                "_MSP_VFS_REAL_CHFLAGS = _MSP_VFS_ORIGINALS[\"os_chflags\"]",
                "def _msp_vfs_stat_result_with_platform_fields(base_fields):",
                "platform_fields[\"st_flags\"] = 0",
                "return _msp_vfs_os.stat_result(values, platform_fields)",
                "def _msp_vfs_chflags(path, flags, *args, **kwargs):",
                "_msp_vfs_capture_patch(\"os_chflags\", lambda: getattr(_msp_vfs_os, \"chflags\", None))",
                "if _MSP_VFS_REAL_CHFLAGS is not None:",
                "_msp_vfs_os.chflags = _msp_vfs_chflags",
                "_msp_vfs_restore_value(_msp_vfs_os, \"chflags\", patches, \"os_chflags\")"
            ]
        )
    }

    func testLauncherSourceInstallsVFSBootstrapBeforeLauncherCode() {
        let bootstrap = MSPPythonVirtualFileSystemBootstrapSource.source

        XCTAssertTrue(MSPPythonLauncherSource.source.hasPrefix(bootstrap + "\nimport builtins\n"))
    }

    func testBootstrapHidesInternalEnvironmentAfterReadingRuntimeConfiguration() {
        let source = MSPPythonVirtualFileSystemBootstrapSource.source
        let markers = [
            "_msp_vfs_os.environ.get(\"MSP_PYTHON_WORKSPACE_ROOT\", \"\")",
            "_msp_vfs_os.environ.get(\"MSP_PYTHON_VFS_BROKER_DIR\", \"\")",
            "_msp_vfs_os.environ.get(\"MSP_PYTHON_VFS_MATERIALIZED_DIR\", \"\")",
            "_msp_vfs_os.environ.get(\"MSP_PYTHON_SUBPROCESS_BROKER_DIR\", \"\")",
            "_msp_vfs_os.environ.get(\"MSP_PYTHON_VIRTUAL_CWD\", \"/\")",
            "_msp_vfs_os.environ.get(\"MSP_PYTHON_FILE_CREATION_MASK\")",
            "_msp_vfs_os.environ[\"HOME\"] = _msp_vfs_os.environ.get(\"MSP_PYTHON_VIRTUAL_HOME\", \"/\") or \"/\"",
            "_msp_vfs_os.environ[\"TMPDIR\"] = _msp_vfs_os.environ.get(\"MSP_PYTHON_VIRTUAL_TMPDIR\", \"/tmp\") or \"/tmp\"",
            "_msp_vfs_os.environ[\"PATH\"] = _msp_vfs_os.environ.get(\"MSP_PYTHON_VIRTUAL_PATH\", \"/usr/bin:/bin\") or \"/usr/bin:/bin\"",
            "_msp_vfs_os.environ[\"PWD\"] = _MSP_VFS_VIRTUAL_CWD",
            "for _msp_vfs_internal_env_name in (",
            "\"MSP_PYTHON_WORKSPACE_ROOT\"",
            "\"MSP_PYTHON_VIRTUAL_CWD\"",
            "\"MSP_PYTHON_VIRTUAL_HOME\"",
            "\"MSP_PYTHON_VIRTUAL_TMPDIR\"",
            "\"MSP_PYTHON_VIRTUAL_PATH\"",
            "\"MSP_PYTHON_VFS_BROKER_DIR\"",
            "\"MSP_PYTHON_VFS_MATERIALIZED_DIR\"",
            "\"MSP_PYTHON_SUBPROCESS_BROKER_DIR\"",
            "\"MSP_PYTHON_FILE_CREATION_MASK\"",
            "_msp_vfs_os.environ.pop(_msp_vfs_internal_env_name, None)"
        ]

        XCTAssertContainsInOrder(source, markers)
    }

    private func XCTAssertContainsInOrder(
        _ source: String,
        _ markers: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for marker in markers {
            guard let range = source.range(of: marker, range: lowerBound..<source.endIndex) else {
                XCTFail("Missing marker: \(marker)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}
