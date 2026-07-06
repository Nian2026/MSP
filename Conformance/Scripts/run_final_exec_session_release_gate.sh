#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_FINAL_EXEC_SESSION_GATE_OUT_DIR:-$ROOT_DIR/.build/msp-conformance/final-exec-session-gate/$STAMP}"

absolute_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve())
PY
}

OUT_DIR="$(absolute_path "$OUT_DIR")"
REPORT="$OUT_DIR/final-exec-session-gate-report.json"
SWIFTPM_SCRATCH_ROOT="$OUT_DIR/swiftpm-scratch"
REQUIRED_MODEL="gpt-5.5"
LOCK_DIRS=("")
FINAL_GATE_TMPDIR_ALIAS=""
DEBIAN12_NONINTERACTIVE_ORACLE_SOURCE_REPORT="$ROOT_DIR/.build/msp-conformance/debian12-noninteractive-report.json"
DEBIAN12_LINUX_PTY_ORACLE_SOURCE_REPORT="$ROOT_DIR/.build/msp-conformance/debian12-pty-linux-report.json"
CORE100_NONINTERACTIVE_ORACLE_SOURCE_REPORT="$ROOT_DIR/.build/msp-conformance/core100-noninteractive-report.json"
DEBIAN12_NONINTERACTIVE_ORACLE_REPORT="$OUT_DIR/debian12-noninteractive-oracle-report.json"
LIVE_NONINTERACTIVE_LINUX_VPS_ORACLE_REPORT="$OUT_DIR/live-noninteractive-linux-vps-oracle-report.json"
DEBIAN12_LINUX_PTY_ORACLE_REPORT="$OUT_DIR/debian12-linux-pty-oracle-report.json"
CORE100_NONINTERACTIVE_ORACLE_REPORT="$OUT_DIR/core100-noninteractive-oracle-report.json"

usage() {
  cat <<USAGE
Usage:
  MSP_PLAYGROUND_MODEL_BASE_URL=... \\
  MSP_PLAYGROUND_MODEL_API_KEY=... \\
  MSP_PLAYGROUND_MODEL=gpt-5.5 \\
    $0

Runs the Codex-equivalent MSP exec-session release gate. This is not a
development smoke test: it requires the Linux/Debian PTY oracle and real iOS
Simulator UI pressure runs against the real required model. It is also not the
overall MSP open-source release gate; the report records the broader final gate
classes that still have to be proven separately.

Required environment:
  MSP_PLAYGROUND_MODEL_BASE_URL       real Responses-compatible provider URL
  MSP_PLAYGROUND_MODEL_API_KEY        real provider API key
  MSP_PLAYGROUND_MODEL                must equal $REQUIRED_MODEL

Optional environment:
  MSP_FINAL_EXEC_SESSION_GATE_OUT_DIR output root
  MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH / MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH
                                      required by the pressure runners
                                      if unset, the gate will use a cached
                                      .build/msp-cpython-ios-cache Python.xcframework
                                      produced by cache_beeware_cpython_apple_support.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "missing required release-gate asset: $path" >&2
    exit 2
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env: $name" >&2
    exit 2
  fi
}

release_locks() {
  local lock_dir
  for lock_dir in "${LOCK_DIRS[@]}"; do
    [[ -n "$lock_dir" ]] && rm -rf "$lock_dir"
  done
  if [[ -n "${FINAL_GATE_TMPDIR_ALIAS:-}" ]]; then
    rm -f "$FINAL_GATE_TMPDIR_ALIAS"
  fi
  return 0
}

trap release_locks EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_exclusive_lock() {
  local lock_dir="$1"
  local label="$2"
  local lock_parent
  lock_parent="$(dirname "$lock_dir")"
  mkdir -p "$lock_parent"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_dir/pid"
    printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
    LOCK_DIRS+=("$lock_dir")
    echo "$label lock: $lock_dir"
    return
  fi

  local existing_pid=""
  if [[ -f "$lock_dir/pid" ]]; then
    existing_pid="$(head -n 1 "$lock_dir/pid" 2>/dev/null || true)"
  fi
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "$label is already running under pid $existing_pid; refusing to run concurrently" >&2
    if [[ -f "$lock_dir/context" ]]; then
      cat "$lock_dir/context" >&2
    fi
    exit 2
  fi

  echo "removing stale $label lock: $lock_dir" >&2
  rm -rf "$lock_dir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "failed to acquire $label lock: $lock_dir" >&2
    exit 2
  fi
  printf '%s\n' "$$" >"$lock_dir/pid"
  printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
  LOCK_DIRS+=("$lock_dir")
  echo "$label lock: $lock_dir"
}

reject_true_env() {
  local name="$1"
  if [[ "${!name:-0}" == "1" ]]; then
    echo "$name=1 is not allowed in the final release gate" >&2
    exit 2
  fi
}

reject_zero_env() {
  local name="$1"
  if [[ "${!name:-1}" == "0" ]]; then
    echo "$name=0 is not allowed in the final release gate" >&2
    exit 2
  fi
}

reject_nonempty_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    echo "$name is not allowed in the final release gate" >&2
    exit 2
  fi
}

resolve_required_cpython_asset() {
  if [[ -n "${MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH:-}" ]]; then
    if [[ ! -d "$MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH" ]]; then
      echo "MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH does not exist: $MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH" >&2
      exit 2
    fi
    return
  fi

  if [[ -n "${MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH:-}" ]]; then
    if [[ ! -f "$MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" ]]; then
      echo "MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH does not exist: $MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" >&2
      exit 2
    fi
    return
  fi

  shopt -s nullglob
  local cached_xcframeworks=("$ROOT_DIR"/.build/msp-cpython-ios-cache/Python-*-iOS-support.*/Python.xcframework)
  shopt -u nullglob
  if (( ${#cached_xcframeworks[@]} > 0 )); then
    export MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH="${cached_xcframeworks[0]}"
    echo "using cached MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH=$MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH"
    return
  fi

  echo "final release gate requires CPython for real-model Python pressure" >&2
  echo "set MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH or MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" >&2
  echo "or run Conformance/Scripts/cache_beeware_cpython_apple_support.sh to populate .build/msp-cpython-ios-cache" >&2
  exit 2
}

resolve_required_macos_cpython_asset() {
  if [[ -n "${MSP_CPYTHON_LIBRARY_PATH:-}" ]]; then
    if [[ ! -f "$MSP_CPYTHON_LIBRARY_PATH" ]]; then
      echo "MSP_CPYTHON_LIBRARY_PATH does not exist: $MSP_CPYTHON_LIBRARY_PATH" >&2
      exit 2
    fi
    if [[ -n "${MSP_CPYTHON_HOME:-}" && ! -d "$MSP_CPYTHON_HOME" ]]; then
      echo "MSP_CPYTHON_HOME does not exist: $MSP_CPYTHON_HOME" >&2
      exit 2
    fi
    return
  fi

  local cached_paths
  if cached_paths="$(
    python3 - "$ROOT_DIR/.build/msp-cpython-macos-cache" <<'PY'
from pathlib import Path
import sys

cache = Path(sys.argv[1])
frameworks = sorted(cache.glob("Python-*-macOS-support.*/Python.xcframework/**/Python.framework"))
for framework in frameworks:
    library = framework / "Python"
    homes = sorted(framework.glob("Versions/*/lib/python*"))
    if library.is_file() and homes:
        home = homes[0].parents[1]
        print(str(library))
        print(str(home))
        raise SystemExit(0)
raise SystemExit(1)
PY
  )"; then
    export MSP_CPYTHON_LIBRARY_PATH="$(printf '%s\n' "$cached_paths" | sed -n '1p')"
    export MSP_CPYTHON_HOME="$(printf '%s\n' "$cached_paths" | sed -n '2p')"
    echo "using cached MSP_CPYTHON_LIBRARY_PATH=$MSP_CPYTHON_LIBRARY_PATH"
    echo "using cached MSP_CPYTHON_HOME=$MSP_CPYTHON_HOME"
    return
  fi

  echo "final release gate requires macOS CPython for dynamic embedded CPython Swift tests" >&2
  echo "set MSP_CPYTHON_LIBRARY_PATH/MSP_CPYTHON_HOME" >&2
  echo "or run MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=macOS Conformance/Scripts/cache_beeware_cpython_apple_support.sh" >&2
  exit 2
}

run_step() {
  local name="$1"
  shift
  local log="$OUT_DIR/$name.log"
  echo "== final gate step: $name =="
  (
    cd "$ROOT_DIR"
    printf 'command:'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  ) >"$log" 2>&1
  echo "$name log: $log"
}

swiftpm_scratch_path() {
  local step="$1"
  printf '%s/%s\n' "$SWIFTPM_SCRATCH_ROOT" "$step"
}

assert_local_hygiene_metadata_clean() {
  local findings=()
  local path
  while IFS= read -r -d '' path; do
    findings+=("${path#$ROOT_DIR/}")
  done < <(
    find "$ROOT_DIR" \
      \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.build" -o -path "$ROOT_DIR/.swiftpm" \) -prune \
      -o \( -name .DS_Store -o -name __pycache__ -o -name '*.pyc' \) -print0
  )

  local vendored_build="$ROOT_DIR/Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Artifacts/Build"
  if [[ -e "$vendored_build" ]]; then
    findings+=("${vendored_build#$ROOT_DIR/}")
  fi

  if (( ${#findings[@]} > 0 )); then
    echo "source tree contains local hygiene metadata; final release gate refuses to clean the repository for you" >&2
    printf '  %s\n' "${findings[@]}" >&2
    exit 2
  fi
}

require_env MSP_PLAYGROUND_MODEL_BASE_URL
require_env MSP_PLAYGROUND_MODEL_API_KEY
require_env MSP_PLAYGROUND_MODEL
export MSP_FINAL_EXEC_SESSION_GATE_ACTIVE=1

if [[ "$MSP_PLAYGROUND_MODEL" != "$REQUIRED_MODEL" ]]; then
  echo "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the final release gate; got $MSP_PLAYGROUND_MODEL" >&2
  exit 2
fi

reject_true_env MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE
reject_true_env MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE
reject_zero_env MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON
reject_zero_env MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC
reject_zero_env MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE
reject_zero_env MSP_PLAYGROUND_PRESSURE_RESET_APP
reject_zero_env MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON
reject_zero_env MSP_PHOTOSORTER_PRESSURE_RESET_APP
reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_NONCE
reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT
reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT
reject_nonempty_env MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE
reject_nonempty_env MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE

acquire_exclusive_lock \
  "$ROOT_DIR/.build/msp-conformance/locks/final-exec-session-release-gate.lock" \
  "final release gate"

require_file "$SCRIPT_DIR/check_core100_closure.py"
require_file "$SCRIPT_DIR/check_python_oracle_coverage.py"
require_file "$SCRIPT_DIR/cache_beeware_cpython_apple_support.sh"
require_file "$SCRIPT_DIR/check_real_model_pressure_preflight.py"
require_file "$SCRIPT_DIR/run_debian12_oracle_conformance.sh"
require_file "$SCRIPT_DIR/run_core100_oracle_conformance.sh"
require_file "$SCRIPT_DIR/run_dynamic_embedded_cpython_swift_tests.sh"
require_file "$SCRIPT_DIR/run_exec_session_stress_gate.sh"
require_file "$SCRIPT_DIR/run_live_noninteractive_linux_vps_oracle.py"
require_file "$SCRIPT_DIR/run_debian12_pty_oracle_container.sh"
require_file "$SCRIPT_DIR/run_full_swift_test_suite.sh"
require_file "$SCRIPT_DIR/run_full_agentbridge_parity_matrix.sh"
require_file "$SCRIPT_DIR/check_open_source_hygiene.py"
require_file "$SCRIPT_DIR/check_open_source_example_boundary.py"
require_file "$SCRIPT_DIR/check_example_chat_renderer_vendor_hygiene.py"
require_file "$SCRIPT_DIR/run_open_source_release_dry_run.py"
require_file "$SCRIPT_DIR/verify_debian12_pty_oracle_report.py"
require_file "$SCRIPT_DIR/verify_live_noninteractive_linux_vps_oracle_report.py"
require_file "$SCRIPT_DIR/write_focused_test_suites_ledger.py"
require_file "$SCRIPT_DIR/run_real_model_pressure_matrix.sh"
require_file "$SCRIPT_DIR/verify_real_model_pressure_matrix.py"
require_file "$SCRIPT_DIR/verify_final_exec_session_release_gate_report.py"
require_file "$SCRIPT_DIR/verify_readex_boundary.py"

resolve_required_cpython_asset
resolve_required_macos_cpython_asset

mkdir -p "$OUT_DIR" "$SWIFTPM_SCRATCH_ROOT"
FINAL_GATE_TMPDIR="${MSP_FINAL_EXEC_SESSION_GATE_TMPDIR:-$OUT_DIR/tmp}"
FINAL_GATE_TMPDIR="$(absolute_path "$FINAL_GATE_TMPDIR")"
mkdir -p "$FINAL_GATE_TMPDIR"
if [[ "$FINAL_GATE_TMPDIR" =~ [[:space:]] ]]; then
  FINAL_GATE_TMPDIR_ALIAS="/tmp/msp-final-gate-tmp-$STAMP"
  rm -f "$FINAL_GATE_TMPDIR_ALIAS"
  ln -s "$FINAL_GATE_TMPDIR" "$FINAL_GATE_TMPDIR_ALIAS"
  export TMPDIR="$FINAL_GATE_TMPDIR_ALIAS/"
else
  export TMPDIR="$FINAL_GATE_TMPDIR/"
fi
export MSP_CONFORMANCE_TMPDIR="${TMPDIR%/}"

run_step real-model-pressure-preflight-hardening \
  python3 Conformance/Scripts/check_real_model_pressure_preflight.py \
    --report "$OUT_DIR/real-model-pressure-preflight-report.json"

run_step readex-boundary-check \
  python3 Conformance/Scripts/verify_readex_boundary.py \
    --root "$ROOT_DIR" \
    --summary-report "$OUT_DIR/readex-boundary-report.json"

run_step swift-build \
  swift build --scratch-path "$(swiftpm_scratch_path swift-build)" --target ModelShellProxy

run_step exec-command-bridge-tests \
  swift test --scratch-path "$(swiftpm_scratch_path exec-command-bridge-tests)" --filter MSPExecCommandBridgeTests

run_step pipe-session-contract-tests \
  swift test --scratch-path "$(swiftpm_scratch_path pipe-session-contract-tests)" --filter ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession

run_step pty-session-contract-tests \
  swift test --scratch-path "$(swiftpm_scratch_path pty-session-contract-tests)" --filter ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY

run_step pty-session-interactive-tests \
  swift test --scratch-path "$(swiftpm_scratch_path pty-session-interactive-tests)" --filter ModelShellProxyExecCommandPipelineTests/testExecCommandBridgeYieldsPTYSessionAndWritesInteractiveStdin

run_step exec-session-stress-gate \
  env MSP_EXEC_SESSION_STRESS_GATE_OUT_DIR="$OUT_DIR/exec-session-stress" \
    MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT="$OUT_DIR/exec-session-stress/scratch" \
    bash Conformance/Scripts/run_exec_session_stress_gate.sh

run_step yielded-session-poll-tests \
  swift test --scratch-path "$(swiftpm_scratch_path yielded-session-poll-tests)" --filter MSPAgentConversationExecSessionRequestTests/testConversationCanPollYieldedExecSessionWithWriteStdinTool

# Coverage: Python VFS tempfile, dir_fd, pathlib, and escape-guard semantics stay virtual.
run_step python-vfs-path-semantics-tests \
  swift test --scratch-path "$(swiftpm_scratch_path python-vfs-path-semantics-tests)" --filter 'MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual|MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual|MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes'

# Coverage: Python subprocess policy routes through MSP command runner.
# Coverage: Python subprocess Popen sessions preserve returned stdout/stderr for non-streaming runners.
# Coverage: Python subprocess Popen sessions merge returned stderr into stdout when requested.
# Coverage: Python subprocess Popen stdout/stderr pipes are iterable file-like objects across streaming, bytes, memory, and deferred nested-Python paths.
# Coverage: Python subprocess Popen pipe objects expose CPython-compatible file-like metadata, readable/writable/seekable/isatty semantics, and context-manager close semantics.
# Coverage: Python subprocess Popen communicate caches completed stdout/stderr results across repeated calls, wait-then-communicate, manual-read-before-communicate, and nested-Python paths.
# Coverage: Python subprocess Popen exposes CPython-compatible pid, repr, and send_signal lifecycle semantics without leaking MSP internal class names.
# Coverage: Python subprocess.run and Popen expose CPython-compatible text-mode behavior and reject conflicting text/universal_newlines arguments.
# Coverage: Python subprocess.run and Popen stdout/stderr writable file targets write through the MSP virtual filesystem.
# Coverage: Python subprocess.run and Popen reject invalid stream/stdin targets before child execution with CPython-compatible diagnostics.
# Coverage: Python subprocess TimeoutExpired exceptions preserve the caller command in cmd without leaking MSP session ids.
# Coverage: Python subprocess TimeoutExpired exceptions preserve CPython-compatible partial stdout/stderr bytes for run and communicate timeouts.
# Coverage: Nested Python subprocess traceback paths stay virtual; nested Python script subprocesses preserve virtual cwd, argv, sys.path[0], and sibling-file access; host-process subprocess shell matrix covers complex syntax, long command lines, os.popen, and os.system.
run_step python-subprocess-policy-tests \
  swift test --scratch-path "$(swiftpm_scratch_path python-subprocess-policy-tests)" --filter 'MSPPythonHostProcessSubprocessTests/testHostProcessPythonSubprocessHonorsCommandPackExclusions|MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual|MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonSubprocessHandlesComplexSyntaxAndLongCommands|MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonOsPopenAndSystemUseControlledShellWithoutPathLeaks|MSPPythonSubprocessBrokerTests/testRunDelegatesToBaseCommandLineRunnerWithVirtualPolicyContext|MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt|MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream|MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream'

# Coverage: Python temporary script entrypoints, __file__, sys.argv[0], traceback paths, encoded file URLs, and split streaming output paths stay virtual.
run_step python-script-traceback-path-tests \
  swift test --scratch-path "$(swiftpm_scratch_path python-script-traceback-path-tests)" --filter 'MSPPythonHostProcessTracebackTests/testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath|MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs|MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete'

# Coverage: host-process external runner maps virtual absolute path arguments to host paths.
# Coverage: host-process external runner maps virtual paths embedded in option values.
# Coverage: host-process external runner maps virtual paths carried in environment values to host paths.
# Coverage: host-process external runner maps virtual paths carried in environment path lists to host paths.
# Coverage: host-process external runner maps virtual file URLs to host file URLs.
# Coverage: host-process external runner launch failures keep paths virtual.
# Coverage: host-process external runner launch failures do not leak host-only executable paths.
# Coverage: host-process external runner output does not leak host-only executable paths or encoded host-only file URLs, and does not duplicate model-visible PATH entries.
# Coverage: host-process external runner version output paths stay virtual.
# Coverage: host-process external runner environment and stdout/stderr paths stay virtual.
run_step external-runner-path-virtualization-tests \
  swift test --scratch-path "$(swiftpm_scratch_path external-runner-path-virtualization-tests)" --filter 'MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs|MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual|MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths|MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput|MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths'

run_step profile-asset-tests \
  swift test --scratch-path "$(swiftpm_scratch_path profile-asset-tests)" --filter ModelShellProxyProfileConformanceTests/testModelWorkspaceExecutionSDKProfileReferencesLiveOracleAssets

# Coverage: mixed workspace host/virtual consistency plus Python subprocess remote/lazy range-read seed.
run_step mixed-workspace-lazy-remote-tests \
  swift test --scratch-path "$(swiftpm_scratch_path mixed-workspace-lazy-remote-tests)" --filter 'ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends|ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead'

run_step workspace-ui-snapshot-consistency-tests \
  swift test --package-path Examples/iOS/MSPPlaygroundApp --scratch-path "$(swiftpm_scratch_path workspace-ui-snapshot-consistency-tests)" --filter MSPPlaygroundWorkspaceProfileTests

run_step photosorter-overlay-view-consistency-tests \
  swift test --package-path Examples/iOS/PhotoSorter --scratch-path "$(swiftpm_scratch_path photosorter-overlay-view-consistency-tests)" --filter PhotoLibraryWorkspaceFileSystemPathTests/testPhotoLibraryWorkspaceOverlayKeepsTreeLookupReadPreviewAndRestoreConsistent

# Coverage: PhotoSorter UI preview cache invalidates when the workspace view version changes.
run_step photosorter-ui-preview-cache-consistency-tests \
  swift test --package-path Examples/iOS/PhotoSorter --scratch-path "$(swiftpm_scratch_path photosorter-ui-preview-cache-consistency-tests)" --filter MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges

# Coverage: PhotoSorter UI thumbnail cache keys include the workspace view version.
run_step photosorter-ui-thumbnail-cache-consistency-tests \
  swift test --package-path Examples/iOS/PhotoSorter --scratch-path "$(swiftpm_scratch_path photosorter-ui-thumbnail-cache-consistency-tests)" --filter MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion

assert_local_hygiene_metadata_clean
run_step open-source-release-dry-run \
  python3 Conformance/Scripts/run_open_source_release_dry_run.py \
    --out-dir "$OUT_DIR/open-source-release-dry-run" \
    --report "$OUT_DIR/open-source-release-dry-run/open-source-release-dry-run-report.json"

run_step dynamic-embedded-cpython-swift-tests \
  env MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_OUT_DIR="$OUT_DIR/dynamic-embedded-cpython-swift-tests" \
    MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_SCRATCH_ROOT="$OUT_DIR/dynamic-embedded-cpython-swift-tests/scratch" \
    bash Conformance/Scripts/run_dynamic_embedded_cpython_swift_tests.sh

run_step focused-test-suites-ledger \
  python3 Conformance/Scripts/write_focused_test_suites_ledger.py \
    --root "$ROOT_DIR" \
    --out-dir "$OUT_DIR" \
    --report "$OUT_DIR/focused-test-suites-ledger/focused-test-suites-ledger-report.json"

run_step full-swift-test-suite \
  env MSP_FULL_SWIFT_TEST_SUITE_OUT_DIR="$OUT_DIR/full-swift-test-suite" \
    MSP_FULL_SWIFT_TEST_SUITE_SCRATCH_ROOT="$OUT_DIR/full-swift-test-suite/scratch" \
    bash Conformance/Scripts/run_full_swift_test_suite.sh

run_step full-agentbridge-parity-matrix \
  env MSP_FULL_AGENTBRIDGE_PARITY_MATRIX_OUT_DIR="$OUT_DIR/full-agentbridge-parity-matrix" \
    MSP_FULL_AGENTBRIDGE_PARITY_MATRIX_SCRATCH_ROOT="$OUT_DIR/full-agentbridge-parity-matrix/scratch" \
    bash Conformance/Scripts/run_full_agentbridge_parity_matrix.sh

run_step core100-closure \
  python3 Conformance/Scripts/check_core100_closure.py

rm -f "$CORE100_NONINTERACTIVE_ORACLE_SOURCE_REPORT"
run_step core100-noninteractive-oracle \
  env MSP_CORE100_ORACLE_SCRATCH_ROOT="$(swiftpm_scratch_path core100-noninteractive-oracle)" \
    Conformance/Scripts/run_core100_oracle_conformance.sh
cp "$CORE100_NONINTERACTIVE_ORACLE_SOURCE_REPORT" "$CORE100_NONINTERACTIVE_ORACLE_REPORT"

run_step python-oracle-coverage-accounting \
  python3 Conformance/Scripts/check_python_oracle_coverage.py

rm -f "$DEBIAN12_NONINTERACTIVE_ORACLE_SOURCE_REPORT"
run_step debian12-noninteractive-oracle \
  env MSP_DEBIAN12_ORACLE_SCRATCH_ROOT="$(swiftpm_scratch_path debian12-noninteractive-oracle)" \
    Conformance/Scripts/run_debian12_oracle_conformance.sh
cp "$DEBIAN12_NONINTERACTIVE_ORACLE_SOURCE_REPORT" "$DEBIAN12_NONINTERACTIVE_ORACLE_REPORT"

run_step live-noninteractive-linux-vps-oracle \
  python3 Conformance/Scripts/run_live_noninteractive_linux_vps_oracle.py \
    --report "$LIVE_NONINTERACTIVE_LINUX_VPS_ORACLE_REPORT"

rm -f "$DEBIAN12_LINUX_PTY_ORACLE_SOURCE_REPORT"
run_step debian12-linux-pty-oracle \
  env MSP_RUN_DEBIAN12_PTY_ORACLE=1 \
    MSP_DEBIAN12_PTY_ORACLE_BACKEND=linux-external \
    MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX=1 \
    swift test --scratch-path "$(swiftpm_scratch_path debian12-linux-pty-oracle)" --filter ModelShellProxyDebian12PTYOracleConformanceTests/testMSPV1Debian12PTYOracleConformanceRunner
cp "$DEBIAN12_LINUX_PTY_ORACLE_SOURCE_REPORT" "$DEBIAN12_LINUX_PTY_ORACLE_REPORT"

run_step debian12-linux-pty-report-verify \
  python3 Conformance/Scripts/verify_debian12_pty_oracle_report.py \
    --report "$DEBIAN12_LINUX_PTY_ORACLE_REPORT" \
    --require-zero-failures \
    --require-linux-runner \
    --require-all-fixture-cases \
    --require-python-pty-cases \
    --expected-case-count 157

run_step real-model-simulator-pressure-matrix \
  env MSP_PLAYGROUND_MODEL="$REQUIRED_MODEL" \
    MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR="$OUT_DIR/real-model-pressure-matrix" \
    MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES=host-backed,exec-session,mixed-backend,photosorter-virtual,photosorter-exec-session \
    MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=1 \
    MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=1 \
    MSP_PLAYGROUND_RUN_LIFECYCLE_DIAGNOSTIC=1 \
    MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=1 \
    MSP_PLAYGROUND_PRESSURE_RESET_APP=1 \
    MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=1 \
    MSP_PHOTOSORTER_PRESSURE_RESET_APP=1 \
    MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=0 \
    MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=0 \
    bash Conformance/Scripts/run_real_model_pressure_matrix.sh

python3 - "$REPORT" "$OUT_DIR" "$REQUIRED_MODEL" "$MSP_PLAYGROUND_MODEL" "$ROOT_DIR" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
out_dir = Path(sys.argv[2]).resolve()
required_model = sys.argv[3]
model = sys.argv[4]
root_dir = Path(sys.argv[5]).resolve()
sys.path.insert(0, str(root_dir / "Conformance" / "Scripts"))

from final_gate_verifier_support.evidence_oracles import (  # noqa: E402
    LINUX_CHARACTER_ORACLE_REPORT_KEYS,
    linux_character_oracle_alignment_summary,
    verify_linux_character_oracle_alignment,
)

steps = [
    "real-model-pressure-preflight-hardening",
    "readex-boundary-check",
    "swift-build",
    "exec-command-bridge-tests",
    "pipe-session-contract-tests",
    "pty-session-contract-tests",
    "pty-session-interactive-tests",
    "exec-session-stress-gate",
    "yielded-session-poll-tests",
    "python-vfs-path-semantics-tests",
    "python-subprocess-policy-tests",
    "python-script-traceback-path-tests",
    "external-runner-path-virtualization-tests",
    "profile-asset-tests",
    "mixed-workspace-lazy-remote-tests",
    "workspace-ui-snapshot-consistency-tests",
    "photosorter-overlay-view-consistency-tests",
    "photosorter-ui-preview-cache-consistency-tests",
    "photosorter-ui-thumbnail-cache-consistency-tests",
    "open-source-release-dry-run",
    "dynamic-embedded-cpython-swift-tests",
    "focused-test-suites-ledger",
    "full-swift-test-suite",
    "full-agentbridge-parity-matrix",
    "core100-closure",
    "core100-noninteractive-oracle",
    "python-oracle-coverage-accounting",
    "debian12-noninteractive-oracle",
    "live-noninteractive-linux-vps-oracle",
    "debian12-linux-pty-oracle",
    "debian12-linux-pty-report-verify",
    "real-model-simulator-pressure-matrix",
]
required_pressure_suites = [
    "host-backed",
    "exec-session",
    "mixed-backend",
    "photosorter-virtual",
    "photosorter-exec-session",
]
step_logs = {
    step: str(out_dir / f"{step}.log")
    for step in steps
}
pressure_suite_reports = {
    suite: str(out_dir / "real-model-pressure-matrix" / suite / "pressure-report.json")
    for suite in required_pressure_suites
}
evidence_artifacts = {
    "real_model_pressure_preflight_report": str(out_dir / "real-model-pressure-preflight-report.json"),
    "readex_boundary_report": str(out_dir / "readex-boundary-report.json"),
    "exec_session_stress_report": str(out_dir / "exec-session-stress" / "exec-session-stress-report.json"),
    "open_source_release_dry_run_report": str(out_dir / "open-source-release-dry-run" / "open-source-release-dry-run-report.json"),
    "dynamic_embedded_cpython_swift_tests_report": str(out_dir / "dynamic-embedded-cpython-swift-tests" / "dynamic-embedded-cpython-swift-tests-report.json"),
    "focused_test_suites_ledger_report": str(out_dir / "focused-test-suites-ledger" / "focused-test-suites-ledger-report.json"),
    "full_swift_test_suite_report": str(out_dir / "full-swift-test-suite" / "full-swift-test-suite-report.json"),
    "full_agentbridge_parity_matrix_report": str(out_dir / "full-agentbridge-parity-matrix" / "full-agentbridge-parity-matrix-report.json"),
    "core100_noninteractive_oracle_report": str(out_dir / "core100-noninteractive-oracle-report.json"),
    "debian12_noninteractive_oracle_report": str(out_dir / "debian12-noninteractive-oracle-report.json"),
    "live_noninteractive_linux_vps_oracle_report": str(out_dir / "live-noninteractive-linux-vps-oracle-report.json"),
    "debian12_linux_pty_oracle_report": str(out_dir / "debian12-linux-pty-oracle-report.json"),
    "real_model_pressure_matrix_report": str(out_dir / "real-model-pressure-matrix" / "pressure-matrix-report.json"),
    "real_model_pressure_suite_reports": pressure_suite_reports,
}
required_artifact_paths = [
    evidence_artifacts["real_model_pressure_preflight_report"],
    evidence_artifacts["readex_boundary_report"],
    evidence_artifacts["exec_session_stress_report"],
    evidence_artifacts["open_source_release_dry_run_report"],
    evidence_artifacts["dynamic_embedded_cpython_swift_tests_report"],
    evidence_artifacts["focused_test_suites_ledger_report"],
    evidence_artifacts["full_swift_test_suite_report"],
    evidence_artifacts["full_agentbridge_parity_matrix_report"],
    evidence_artifacts["core100_noninteractive_oracle_report"],
    evidence_artifacts["debian12_noninteractive_oracle_report"],
    evidence_artifacts["live_noninteractive_linux_vps_oracle_report"],
    evidence_artifacts["debian12_linux_pty_oracle_report"],
    evidence_artifacts["real_model_pressure_matrix_report"],
    *pressure_suite_reports.values(),
    *step_logs.values(),
]
missing = [
    artifact_path
    for artifact_path in required_artifact_paths
    if not Path(artifact_path).exists()
]
if missing:
    raise SystemExit(
        "final gate passed but required evidence artifacts are missing: "
        + ", ".join(missing)
    )

linux_character_oracle_reports = {}
for key in LINUX_CHARACTER_ORACLE_REPORT_KEYS:
    artifact_path = evidence_artifacts[key]
    linux_character_oracle_reports[key] = json.loads(Path(artifact_path).read_text(encoding="utf-8"))
linux_character_oracle_alignment = linux_character_oracle_alignment_summary(linux_character_oracle_reports)
alignment_failures = []
verify_linux_character_oracle_alignment(linux_character_oracle_alignment, alignment_failures)
if alignment_failures:
    raise SystemExit(
        "final gate refused to write passed report because Linux character oracle alignment is not clean: "
        + "; ".join(alignment_failures)
    )

report = {
    "passed": True,
    "gate": "msp-final-exec-session-release-gate",
    "completion_scope": "exec-session-release-gate",
    "not_final_msp_open_source_release_gate": True,
    "missing_final_gate_classes": [
        "remote-backed-workspace-conformance",
        "lazy-materialized-workspace-conformance",
        "full-ui-preview-thumbnail-cache-e2e-conformance",
        "readex-migration-compatibility-conformance",
    ],
    "required_model": required_model,
    "model": model,
    "model_matches_required": model == required_model,
    "model_failures": [] if model == required_model else [
        f"final gate model is not {required_model}: {model}"
    ],
    "repository_root": str(root_dir),
    "out_dir": str(out_dir),
    "steps": steps,
    "step_logs": step_logs,
    "required_pressure_suites": required_pressure_suites,
    "linux_character_oracle_alignment": linux_character_oracle_alignment,
    "evidence_artifacts": evidence_artifacts,
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

FINAL_REPORT_VERIFY_LOG="$OUT_DIR/final-exec-session-gate-report-verify.log"
python3 Conformance/Scripts/verify_final_exec_session_release_gate_report.py \
  --report "$REPORT" \
  --summary-report "$OUT_DIR/final-exec-session-gate-report-verification.json" \
  >"$FINAL_REPORT_VERIFY_LOG" 2>&1
echo "final gate report verification log: $FINAL_REPORT_VERIFY_LOG"

echo "MSP exec-session release gate passed"
echo "report=$REPORT"
