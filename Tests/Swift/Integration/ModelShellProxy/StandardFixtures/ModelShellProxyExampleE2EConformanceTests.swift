import Foundation
import XCTest

final class ModelShellProxyExampleE2EConformanceTests: XCTestCase {
    func testCPythonAppleSupportCacheScriptProvidesIOSAndMacOSEnvironmentPaths() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let scriptURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("cache_beeware_cpython_apple_support.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        for required in [
            "beeware/Python-Apple-support",
            "MSP_CPYTHON_APPLE_SUPPORT_TAG",
            "MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS",
            "MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH",
            "MSP_CPYTHON_LIBRARY_PATH",
            "MSP_CPYTHON_HOME",
            ".build/msp-cpython-ios-cache",
            ".build/msp-cpython-macos-cache",
            "Python.xcframework",
            "browser_download_url"
        ] {
            XCTAssertTrue(script.contains(required), "CPython cache script missing \(required)")
        }
    }

    func testPlaygroundE2EScriptsUseIsolatedDerivedData() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let e2eURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("MSPPlaygroundApp")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")

        let shellDiagnostic = try String(
            contentsOf: e2eURL.appendingPathComponent("run-shell-diagnostic.sh"),
            encoding: .utf8
        )
        for required in [
            "MSP_PLAYGROUND_SHELL_DIAGNOSTIC_DERIVED_DATA_PATH",
            "STAMP=\"$(date +%Y%m%d-%H%M%S)\"",
            "DERIVED_DATA_PATH",
            "-derivedDataPath \"$DERIVED_DATA_PATH\"",
            "is_owned_e2e_build_path",
            "MSP_PLAYGROUND_PRESSURE_BUILD_ROOT",
            "clean_e2e_build_path \"$BUILD_DIR\" \"build directory\"",
            "clean_e2e_build_path \"$DERIVED_DATA_PATH\" \"DerivedData path\"",
            "\"$ROOT_DIR/.build/msp-conformance\"",
            "MSP_PLAYGROUND_WORKSPACE_PROFILE",
            "--msp-workspace-profile=$MSP_PLAYGROUND_WORKSPACE_PROFILE",
            "INSTALLED_APP_BUNDLE=",
            "xcrun simctl get_app_container \"$DEVICE_ID\" \"$BUNDLE_ID\" app",
            "SIMCTL_LOCAL_TMP_ROOT=\"${MSP_SIMCTL_LOCAL_TMP_ROOT:-/private/tmp}\"",
            "MSP_SIMCTL_LOCAL_TMP_ROOT must be under /tmp or /private/tmp",
            "mktemp -d \"$SIMCTL_LOCAL_TMP_ROOT/msp-playground-simctl-logs.XXXXXX\"",
            "--stdout=\"$SIMCTL_STDOUT_LOG\"",
            "--stderr=\"$SIMCTL_STDERR_LOG\"",
            "cp \"$SIMCTL_STDOUT_LOG\" \"$STDOUT_LOG\"",
            "--msp-cpython-library-path=$INSTALLED_APP_BUNDLE/Frameworks/Python.framework/Python",
            "--msp-cpython-home=$INSTALLED_APP_BUNDLE/python"
        ] {
            XCTAssertTrue(shellDiagnostic.contains(required), "shell diagnostic runner missing \(required)")
        }
        XCTAssertFalse(shellDiagnostic.contains("SIMCTL_TMP_ALIAS"), "shell diagnostic runner must not route simctl logs through a symlink alias")
        XCTAssertFalse(shellDiagnostic.contains("ln -s \"$SIMCTL_TMP_REAL_ROOT\""), "shell diagnostic runner must not symlink simctl logs to an external TMPDIR")

        let realModelE2E = try String(
            contentsOf: e2eURL.appendingPathComponent("run-real-model-e2e.sh"),
            encoding: .utf8
        )
        for required in [
            "MSP_PLAYGROUND_E2E_BUILD_DIR",
            "BUILD_DIR=\"${MSP_PLAYGROUND_E2E_BUILD_DIR:-$OUT_DIR/build}\"",
            "MSP_PLAYGROUND_E2E_DERIVED_DATA_PATH",
            "STAMP=\"$(date +%Y%m%d-%H%M%S)\"",
            "DERIVED_DATA_PATH",
            "-derivedDataPath \"$DERIVED_DATA_PATH\"",
            "is_owned_e2e_build_path",
            "MSP_PLAYGROUND_PRESSURE_BUILD_ROOT",
            "clean_e2e_build_path \"$BUILD_DIR\" \"build directory\"",
            "clean_e2e_build_path \"$DERIVED_DATA_PATH\" \"DerivedData path\"",
            "\"$ROOT_DIR/.build/msp-conformance\"",
            "MSP_PLAYGROUND_WORKSPACE_PROFILE",
            "--msp-workspace-profile=$MSP_PLAYGROUND_WORKSPACE_PROFILE",
            "INSTALLED_APP_BUNDLE=",
            "xcrun simctl get_app_container \"$DEVICE_ID\" \"$BUNDLE_ID\" app",
            "SIMCTL_LOCAL_TMP_ROOT=\"${MSP_SIMCTL_LOCAL_TMP_ROOT:-/private/tmp}\"",
            "MSP_SIMCTL_LOCAL_TMP_ROOT must be under /tmp or /private/tmp",
            "mktemp -d \"$SIMCTL_LOCAL_TMP_ROOT/msp-playground-simctl-logs.XXXXXX\"",
            "--stdout=\"$SIMCTL_STDOUT_LOG\"",
            "--stderr=\"$SIMCTL_STDERR_LOG\"",
            "SIMCTL_SCREENSHOT=\"$SIMCTL_LOG_DIR/screenshot.png\"",
            "xcrun simctl io \"$DEVICE_ID\" screenshot \"$SIMCTL_SCREENSHOT\"",
            "cp \"$SIMCTL_STDOUT_LOG\" \"$STDOUT_LOG\"",
            "--msp-cpython-library-path=$INSTALLED_APP_BUNDLE/Frameworks/Python.framework/Python",
            "--msp-cpython-home=$INSTALLED_APP_BUNDLE/python"
        ] {
            XCTAssertTrue(realModelE2E.contains(required), "real-model E2E runner missing \(required)")
        }
        XCTAssertFalse(realModelE2E.contains("SIMCTL_TMP_ALIAS"), "real-model E2E runner must not route simctl logs through a symlink alias")
        XCTAssertFalse(realModelE2E.contains("ln -s \"$SIMCTL_TMP_REAL_ROOT\""), "real-model E2E runner must not symlink simctl logs to an external TMPDIR")
    }

    func testPhotoSorterE2EScriptUsesIsolatedBuildAndLogs() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let e2eURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("PhotoSorter")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")

        let realModelE2E = try String(
            contentsOf: e2eURL.appendingPathComponent("run-real-model-e2e.sh"),
            encoding: .utf8
        )
        for required in [
            "MSP_PHOTOSORTER_E2E_BUILD_DIR",
            "BUILD_DIR=\"${MSP_PHOTOSORTER_E2E_BUILD_DIR:-${MSP_PLAYGROUND_E2E_BUILD_DIR:-$OUT_DIR/build}}\"",
            "MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH",
            "STAMP=\"$(date +%Y%m%d-%H%M%S)\"",
            "DERIVED_DATA_PATH=\"${MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH:-${MSP_PLAYGROUND_E2E_DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}}\"",
            "-derivedDataPath \"$DERIVED_DATA_PATH\"",
            "is_owned_e2e_build_path",
            "MSP_PHOTOSORTER_PRESSURE_BUILD_ROOT",
            "clean_e2e_build_path \"$BUILD_DIR\" \"build directory\"",
            "clean_e2e_build_path \"$DERIVED_DATA_PATH\" \"DerivedData path\"",
            "\"$ROOT_DIR/.build/msp-conformance\"",
            "build >\"$OUT_DIR/xcodebuild.log\"",
            "SIMCTL_LOCAL_TMP_ROOT=\"${MSP_SIMCTL_LOCAL_TMP_ROOT:-/private/tmp}\"",
            "MSP_SIMCTL_LOCAL_TMP_ROOT must be under /tmp or /private/tmp",
            "mktemp -d \"$SIMCTL_LOCAL_TMP_ROOT/photosorter-simctl-logs.XXXXXX\"",
            "--stdout=\"$SIMCTL_STDOUT_LOG\"",
            "--stderr=\"$SIMCTL_STDERR_LOG\"",
            "SIMCTL_SCREENSHOT=\"$SIMCTL_LOG_DIR/screenshot.png\"",
            "xcrun simctl io \"$DEVICE_ID\" screenshot \"$SIMCTL_SCREENSHOT\"",
            "cp \"$SIMCTL_STDOUT_LOG\" \"$STDOUT_LOG\"",
            "launch_app()",
            "simctl launch failed after retry"
        ] {
            XCTAssertTrue(realModelE2E.contains(required), "PhotoSorter real-model E2E runner missing \(required)")
        }
        XCTAssertFalse(realModelE2E.contains("SIMCTL_TMP_ALIAS"), "PhotoSorter real-model E2E runner must not route simctl logs through a symlink alias")
        XCTAssertFalse(realModelE2E.contains("ln -s \"$SIMCTL_TMP_REAL_ROOT\""), "PhotoSorter real-model E2E runner must not symlink simctl logs to an external TMPDIR")

        let pressureRunner = try String(
            contentsOf: e2eURL.appendingPathComponent("run-real-model-pressure.sh"),
            encoding: .utf8
        )
        for required in [
            "real-model-ui-pressure.lock",
            "MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD",
            "refusing to run concurrently"
        ] {
            XCTAssertTrue(pressureRunner.contains(required), "PhotoSorter pressure runner missing \(required)")
        }

        let photoSorterEmbedCPython = try String(
            contentsOf: rootURL
                .appendingPathComponent("Examples")
                .appendingPathComponent("iOS")
                .appendingPathComponent("PhotoSorter")
                .appendingPathComponent("Tools")
                .appendingPathComponent("Python")
                .appendingPathComponent("embed-cpython-runtime.sh"),
            encoding: .utf8
        )
        for required in [
            "MSP_EXAMPLE_CPYTHON_DISPLAY_NAME=\"PhotoSorter\"",
            "MSP_PHOTOSORTER_PYTHON_XCFRAMEWORK_PATH",
            "MSP_PHOTOSORTER_REQUIRE_CPYTHON",
            "exec bash \"$script_dir/../../../Shared/Python/embed-cpython-runtime.sh\""
        ] {
            XCTAssertTrue(photoSorterEmbedCPython.contains(required), "PhotoSorter CPython wrapper missing \(required)")
        }

        let sharedEmbedCPython = try String(
            contentsOf: rootURL
                .appendingPathComponent("Examples")
                .appendingPathComponent("iOS")
                .appendingPathComponent("Shared")
                .appendingPathComponent("Python")
                .appendingPathComponent("embed-cpython-runtime.sh"),
            encoding: .utf8
        )
        for required in [
            "temp_root=\"${TMPDIR:-/tmp}\"",
            "mktemp -d \"$temp_root/msp-cpython.XXXXXX\""
        ] {
            XCTAssertTrue(sharedEmbedCPython.contains(required), "shared CPython embed script missing \(required)")
        }
    }
}
