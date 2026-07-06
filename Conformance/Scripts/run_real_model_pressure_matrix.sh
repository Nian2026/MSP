#!/usr/bin/env bash
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
REQUESTED_OUT_ROOT="${MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR:-}"
if [[ "${MSP_FINAL_EXEC_SESSION_GATE_ACTIVE:-0}" == "1" && -z "$REQUESTED_OUT_ROOT" ]]; then
  echo "MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR is required when the matrix is launched from the final release gate" >&2
  exit 2
fi
OUT_ROOT="${REQUESTED_OUT_ROOT:-$ROOT_DIR/.codex-tmp/real-model-pressure-matrix/$STAMP}"

absolute_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve())
PY
}

OUT_ROOT="$(absolute_path "$OUT_ROOT")"
PLAYGROUND_RUNNER="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-real-model-pressure.sh"
PHOTOSORTER_RUNNER="$ROOT_DIR/Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-pressure.sh"
MATRIX_VERIFIER="$SCRIPT_DIR/verify_real_model_pressure_matrix.py"
REQUIRED_MODEL="gpt-5.5"
REQUIRED_SUITES=(host-backed exec-session mixed-backend photosorter-virtual photosorter-exec-session)
REQUIRED_SUITES_CSV="$(IFS=,; echo "${REQUIRED_SUITES[*]}")"
SUITES_RAW="${MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES:-$REQUIRED_SUITES_CSV}"
SUITES=()
FAIL_FAST="${MSP_REAL_MODEL_PRESSURE_MATRIX_FAIL_FAST:-0}"
LOCK_DIRS=("")
MATRIX_TMPDIR_ALIAS=""

usage() {
  cat <<USAGE
Usage: MSP_PLAYGROUND_MODEL_BASE_URL=... MSP_PLAYGROUND_MODEL_API_KEY=... MSP_PLAYGROUND_MODEL=$REQUIRED_MODEL \\
  $0

Runs the real-model pressure matrix for MSP's long-term workspace SDK profile:
host-backed MSPPlaygroundApp, Codex-style exec-session MSPPlaygroundApp,
mixed-backend MSPPlaygroundApp, virtual-backed PhotoSorter, and Codex-style
exec-session PhotoSorter. The matrix fails
unless every suite report says the model could not distinguish the workspace
from regular Linux and no model-visible output leaked host, sandbox, broker,
materialized, launcher, or runtime paths.

Environment:
  MSP_PLAYGROUND_MODEL_BASE_URL             required provider base URL
  MSP_PLAYGROUND_MODEL_API_KEY              required provider API key
  MSP_PLAYGROUND_MODEL                      must equal $REQUIRED_MODEL
  MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH    preferred CPython packaging input
  MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH       alternate app-visible CPython library path
                                             if both CPython vars are unset, the matrix uses
                                             .build/msp-cpython-ios-cache when available
  MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR    output root, default .codex-tmp/real-model-pressure-matrix/<stamp>
  MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES     comma/space list; must include every
                                             required suite, default $REQUIRED_SUITES_CSV
  MSP_REAL_MODEL_PRESSURE_MATRIX_FAIL_FAST=1 stop after the first failed suite
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env: $name" >&2
    exit 2
  fi
}

reject_true_env() {
  local name="$1"
  if [[ "${!name:-0}" == "1" ]]; then
    echo "$name=1 is not allowed in the real-model pressure matrix" >&2
    exit 2
  fi
}

reject_zero_env() {
  local name="$1"
  if [[ "${!name:-1}" == "0" ]]; then
    echo "$name=0 is not allowed in the real-model pressure matrix" >&2
    exit 2
  fi
}

reject_nonempty_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    echo "$name is not allowed in the real-model pressure matrix" >&2
    exit 2
  fi
}

contains_suite() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

validate_requested_suites() {
  local parsed_suites=()
  local normalized_suites=()
  local normalized_count=0
  local suite
  IFS=$' ,\n\t' read -r -a parsed_suites <<<"$SUITES_RAW"
  for suite in "${parsed_suites[@]}"; do
    [[ -z "$suite" ]] && continue
    if ! contains_suite "$suite" "${REQUIRED_SUITES[@]}"; then
      echo "unknown pressure suite: $suite" >&2
      exit 2
    fi
    if (( normalized_count > 0 )) && contains_suite "$suite" "${normalized_suites[@]}"; then
      echo "duplicate pressure suite in MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES: $suite" >&2
      exit 2
    fi
    normalized_suites+=("$suite")
    normalized_count=$((normalized_count + 1))
  done
  if (( normalized_count == 0 )); then
    echo "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES did not contain any suites" >&2
    exit 2
  fi

  local missing_suites=()
  local missing_count=0
  for suite in "${REQUIRED_SUITES[@]}"; do
    if ! contains_suite "$suite" "${normalized_suites[@]}"; then
      missing_suites+=("$suite")
      missing_count=$((missing_count + 1))
    fi
  done
  if (( missing_count > 0 )); then
    echo "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES must include every required suite; missing: ${missing_suites[*]}" >&2
    exit 2
  fi

  SUITES=("${REQUIRED_SUITES[@]}")
}

release_locks() {
  local lock_dir
  for lock_dir in "${LOCK_DIRS[@]}"; do
    [[ -n "$lock_dir" ]] && rm -rf "$lock_dir"
  done
  if [[ -n "${MATRIX_TMPDIR_ALIAS:-}" ]]; then
    rm -f "$MATRIX_TMPDIR_ALIAS"
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
    printf 'out_dir=%s\n' "$OUT_ROOT" >"$lock_dir/context"
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
  printf 'out_dir=%s\n' "$OUT_ROOT" >"$lock_dir/context"
  LOCK_DIRS+=("$lock_dir")
  echo "$label lock: $lock_dir"
}

resolve_cpython_asset_if_available() {
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
  fi
}

require_env MSP_PLAYGROUND_MODEL_BASE_URL
require_env MSP_PLAYGROUND_MODEL_API_KEY
require_env MSP_PLAYGROUND_MODEL
if [[ "$MSP_PLAYGROUND_MODEL" != "$REQUIRED_MODEL" ]]; then
  echo "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the real-model pressure matrix; got $MSP_PLAYGROUND_MODEL" >&2
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
validate_requested_suites
acquire_exclusive_lock \
  "$ROOT_DIR/.build/msp-conformance/locks/real-model-pressure-matrix.lock" \
  "real-model pressure matrix"
acquire_exclusive_lock \
  "$ROOT_DIR/.build/msp-conformance/locks/real-model-ui-pressure.lock" \
  "real-model UI pressure"
export MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD=1
resolve_cpython_asset_if_available

for required_file in "$PLAYGROUND_RUNNER" "$PHOTOSORTER_RUNNER" "$MATRIX_VERIFIER"; do
  if [[ ! -f "$required_file" ]]; then
    echo "required pressure asset missing: $required_file" >&2
    exit 2
  fi
done

mkdir -p "$OUT_ROOT"
MATRIX_TMPDIR="${MSP_REAL_MODEL_PRESSURE_MATRIX_TMPDIR:-$OUT_ROOT/tmp}"
MATRIX_TMPDIR="$(absolute_path "$MATRIX_TMPDIR")"
mkdir -p "$MATRIX_TMPDIR"
if [[ "$MATRIX_TMPDIR" =~ [[:space:]] ]]; then
  MATRIX_TMPDIR_ALIAS="/tmp/msp-real-model-matrix-tmp-$STAMP"
  rm -f "$MATRIX_TMPDIR_ALIAS"
  ln -s "$MATRIX_TMPDIR" "$MATRIX_TMPDIR_ALIAS"
  export TMPDIR="$MATRIX_TMPDIR_ALIAS/"
else
  export TMPDIR="$MATRIX_TMPDIR/"
fi

run_suite() {
  local suite="$1"
  local suite_dir="$OUT_ROOT/$suite"
  local runner_log="$suite_dir/runner.log"
  local host_build_root="${MSP_REAL_MODEL_PRESSURE_MATRIX_HOST_BUILD_ROOT:-$OUT_ROOT/builds/playground}"
  local playground_build_root="${MSP_REAL_MODEL_PRESSURE_MATRIX_PLAYGROUND_BUILD_ROOT:-$host_build_root/playground}"
  local playground_app_build_dir="$playground_build_root/app/build"
  local playground_app_derived_data_path="$playground_build_root/app/DerivedData"
  local playground_app_bundle="$playground_app_build_dir/Debug-iphonesimulator/MSPPlaygroundApp.app"
  local photosorter_build_root="${MSP_REAL_MODEL_PRESSURE_MATRIX_PHOTOSORTER_BUILD_ROOT:-$OUT_ROOT/builds/photosorter}"
  mkdir -p "$suite_dir"
  echo "== running pressure suite: $suite =="
  case "$suite" in
    host-backed)
      (
        unset MSP_PLAYGROUND_WORKSPACE_PROFILE
        MSP_PLAYGROUND_PRESSURE_OUT_DIR="$suite_dir" \
        MSP_PLAYGROUND_PRESSURE_BUILD_ROOT="$playground_build_root" \
        MSP_PLAYGROUND_SHELL_DIAGNOSTIC_BUILD_DIR="$playground_app_build_dir" \
        MSP_PLAYGROUND_SHELL_DIAGNOSTIC_DERIVED_DATA_PATH="$playground_app_derived_data_path" \
        MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=1 \
        MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=1 \
        MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=1 \
        MSP_PLAYGROUND_PRESSURE_RESET_APP=1 \
        MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/host-backed-linux-parity-prompts.json" \
          "$PLAYGROUND_RUNNER"
      ) >"$runner_log" 2>&1
      ;;
    exec-session)
      local exec_session_skip_build=0
      if [[ -d "$playground_app_bundle" ]]; then
        exec_session_skip_build=1
      fi
      (
        unset MSP_PLAYGROUND_WORKSPACE_PROFILE
        MSP_PLAYGROUND_PRESSURE_OUT_DIR="$suite_dir" \
        MSP_PLAYGROUND_PRESSURE_BUILD_ROOT="$playground_build_root" \
        MSP_PLAYGROUND_SHELL_DIAGNOSTIC_BUILD_DIR="$playground_app_build_dir" \
        MSP_PLAYGROUND_SHELL_DIAGNOSTIC_DERIVED_DATA_PATH="$playground_app_derived_data_path" \
        MSP_PLAYGROUND_SHELL_DIAGNOSTIC_SKIP_BUILD="$exec_session_skip_build" \
        MSP_PLAYGROUND_E2E_SKIP_BUILD="$exec_session_skip_build" \
        MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=1 \
        MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=1 \
        MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=1 \
        MSP_PLAYGROUND_PRESSURE_RESET_APP=1 \
        MSP_PLAYGROUND_PRESSURE_REQUIRE_EXEC_SESSION_CONTRACT=1 \
        MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/exec-session-parity-prompts.json" \
          "$PLAYGROUND_RUNNER"
      ) >"$runner_log" 2>&1
      ;;
    mixed-backend)
      local mixed_skip_build=0
      if [[ -d "$playground_app_bundle" ]]; then
        mixed_skip_build=1
      fi
      MSP_PLAYGROUND_PRESSURE_OUT_DIR="$suite_dir" \
      MSP_PLAYGROUND_WORKSPACE_PROFILE=mixed-backend \
      MSP_PLAYGROUND_PRESSURE_BUILD_ROOT="$playground_build_root" \
      MSP_PLAYGROUND_SHELL_DIAGNOSTIC_BUILD_DIR="$playground_app_build_dir" \
      MSP_PLAYGROUND_SHELL_DIAGNOSTIC_DERIVED_DATA_PATH="$playground_app_derived_data_path" \
      MSP_PLAYGROUND_SHELL_DIAGNOSTIC_SKIP_BUILD="$mixed_skip_build" \
      MSP_PLAYGROUND_E2E_SKIP_BUILD="$mixed_skip_build" \
      MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=1 \
      MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=1 \
      MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=1 \
      MSP_PLAYGROUND_PRESSURE_RESET_APP=1 \
      MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/mixed-backend-linux-parity-prompts.json" \
        "$PLAYGROUND_RUNNER" >"$runner_log" 2>&1
      ;;
    photosorter-virtual)
      (
        unset MSP_PLAYGROUND_WORKSPACE_PROFILE
        MSP_PHOTOSORTER_PRESSURE_OUT_DIR="$suite_dir" \
        MSP_PHOTOSORTER_PRESSURE_BUILD_ROOT="$photosorter_build_root/$suite" \
        MSP_PHOTOSORTER_E2E_BUILD_DIR="$photosorter_build_root/$suite/e2e/build" \
        MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH="$photosorter_build_root/$suite/e2e/DerivedData" \
        MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=1 \
        MSP_PHOTOSORTER_PRESSURE_RESET_APP=1 \
        MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE="$ROOT_DIR/Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-virtual-workspace-prompts.json" \
          "$PHOTOSORTER_RUNNER"
      ) >"$runner_log" 2>&1
      ;;
    photosorter-exec-session)
      (
        unset MSP_PLAYGROUND_WORKSPACE_PROFILE
        MSP_PHOTOSORTER_PRESSURE_OUT_DIR="$suite_dir" \
        MSP_PHOTOSORTER_PRESSURE_BUILD_ROOT="$photosorter_build_root/$suite" \
        MSP_PHOTOSORTER_E2E_BUILD_DIR="$photosorter_build_root/$suite/e2e/build" \
        MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH="$photosorter_build_root/$suite/e2e/DerivedData" \
        MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=1 \
        MSP_PHOTOSORTER_PRESSURE_RESET_APP=1 \
        MSP_PHOTOSORTER_PRESSURE_REQUIRE_EXEC_SESSION_CONTRACT=1 \
        MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE="$ROOT_DIR/Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-exec-session-parity-prompts.json" \
          "$PHOTOSORTER_RUNNER"
      ) >"$runner_log" 2>&1
      ;;
    *)
      echo "unknown pressure suite: $suite" >&2
      return 2
      ;;
  esac
}

declare -a verifier_args=(
  --root "$OUT_ROOT"
  --report "$OUT_ROOT/pressure-matrix-report.json"
  --required-model "$REQUIRED_MODEL"
  --model "$MSP_PLAYGROUND_MODEL"
)
overall_status=0
for suite in "${SUITES[@]}"; do
  [[ -z "$suite" ]] && continue
  verifier_args+=(--suite "$suite=$OUT_ROOT/$suite/pressure-report.json")
  run_suite "$suite"
  status=$?
  if (( status != 0 )); then
    overall_status=1
    echo "suite failed: $suite (exit $status)" >&2
    echo "runner log: $OUT_ROOT/$suite/runner.log" >&2
    if [[ "$FAIL_FAST" == "1" ]]; then
      break
    fi
  fi
done

"$MATRIX_VERIFIER" "${verifier_args[@]}"
verify_status=$?
if (( verify_status != 0 )); then
  overall_status=1
fi

echo "matrix_out_dir=$OUT_ROOT"
echo "matrix_report=$OUT_ROOT/pressure-matrix-report.json"
exit "$overall_status"
