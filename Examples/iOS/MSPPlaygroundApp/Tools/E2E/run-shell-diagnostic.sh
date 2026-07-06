#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp"
PROJECT="$APP_DIR/Project/MSPPlaygroundApp.xcodeproj"
BUNDLE_ID="${MSP_PLAYGROUND_SHELL_DIAGNOSTIC_BUNDLE_ID:-${MSP_EXAMPLE_BUNDLE_ID_PREFIX:-com.modelshellprotocol.examples}.playground}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_PLAYGROUND_SHELL_DIAGNOSTIC_OUT_DIR:-/tmp/msp-playground-shell-diagnostic}"
BUILD_DIR="${MSP_PLAYGROUND_SHELL_DIAGNOSTIC_BUILD_DIR:-$OUT_DIR/build}"
DERIVED_DATA_PATH="${MSP_PLAYGROUND_SHELL_DIAGNOSTIC_DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"

absolute_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve())
PY
}

OUT_DIR="$(absolute_path "$OUT_DIR")"
BUILD_DIR="$(absolute_path "$BUILD_DIR")"
DERIVED_DATA_PATH="$(absolute_path "$DERIVED_DATA_PATH")"
APP_BUNDLE="$BUILD_DIR/Debug-iphonesimulator/MSPPlaygroundApp.app"
ENABLE_PYTHON="${MSP_PLAYGROUND_ENABLE_PYTHON:-1}"
PYTHON_XCFRAMEWORK_PATH="${MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH:-}"
SKIP_BUILD="${MSP_PLAYGROUND_SHELL_DIAGNOSTIC_SKIP_BUILD:-0}"
RUN_PYTHON_ORACLE="${MSP_PLAYGROUND_RUN_PYTHON_ORACLE:-}"
RUN_LIFECYCLE_DIAGNOSTIC="${MSP_PLAYGROUND_RUN_LIFECYCLE_DIAGNOSTIC:-1}"
ORACLE_FIXTURE_SRC="$ROOT_DIR/Conformance/ReferenceOutputs/MSPV1Debian12Oracle/noninteractive-cases.json"

resolve_python_runtime_if_enabled() {
  [[ "$ENABLE_PYTHON" == "1" ]] || return 0

  if [[ -n "$PYTHON_XCFRAMEWORK_PATH" ]]; then
    if [[ ! -d "$PYTHON_XCFRAMEWORK_PATH" ]]; then
      echo "MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH does not exist: $PYTHON_XCFRAMEWORK_PATH" >&2
      exit 2
    fi
    return 0
  fi

  if [[ -n "${MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH:-}" ]]; then
    if [[ ! -f "$MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" ]]; then
      echo "MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH does not exist: $MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" >&2
      exit 2
    fi
    return 0
  fi

  shopt -s nullglob
  local cached_xcframeworks=("$ROOT_DIR"/.build/msp-cpython-ios-cache/Python-*-iOS-support.*/Python.xcframework)
  shopt -u nullglob
  if (( ${#cached_xcframeworks[@]} > 0 )); then
    PYTHON_XCFRAMEWORK_PATH="${cached_xcframeworks[0]}"
    echo "using cached MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH=$PYTHON_XCFRAMEWORK_PATH"
    return 0
  fi

  echo "MSPPlaygroundApp shell diagnostic enables Python by default, but no CPython runtime is configured." >&2
  echo "set MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH or MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" >&2
  echo "or run MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=iOS Conformance/Scripts/cache_beeware_cpython_apple_support.sh" >&2
  echo "set MSP_PLAYGROUND_ENABLE_PYTHON=0 only for non-Python diagnostics" >&2
  exit 2
}

resolve_python_runtime_if_enabled
if [[ -z "$RUN_PYTHON_ORACLE" ]]; then
  if [[ -n "$PYTHON_XCFRAMEWORK_PATH" || -n "${MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH:-}" ]]; then
    RUN_PYTHON_ORACLE=1
  else
    RUN_PYTHON_ORACLE=0
  fi
fi

mkdir -p "$OUT_DIR"
SIMCTL_COMMAND_TIMEOUT_SECONDS="${MSP_PLAYGROUND_SIMCTL_COMMAND_TIMEOUT_SECONDS:-45}"
SIMCTL_INSTALL_TIMEOUT_SECONDS="${MSP_PLAYGROUND_SIMCTL_INSTALL_TIMEOUT_SECONDS:-180}"
SIMCTL_COMMAND_LOG="$OUT_DIR/simctl-commands.log"
: >"$SIMCTL_COMMAND_LOG"

run_simctl_command_with_timeout() {
  local label="$1"
  local timeout="$2"
  local pid=""
  local status=0
  local start="$SECONDS"
  shift 2

  "$@" &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start >= timeout )); then
      echo "$label timed out after ${timeout}s" >>"$SIMCTL_COMMAND_LOG"
      pkill -TERM -P "$pid" >/dev/null 2>&1 || true
      kill -TERM "$pid" >/dev/null 2>&1 || true
      sleep 1
      pkill -KILL -P "$pid" >/dev/null 2>&1 || true
      kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
  done

  set +e
  wait "$pid"
  status="$?"
  set -e
  return "$status"
}

verify_simulator_pty_backend() {
  local app_bundle="$1"
  local fallback_hits=""
  fallback_hits="$(find "$app_bundle" -type f ! -path '*/RuntimeResources/*' -size +1k -print0 \
    | xargs -0 grep -a -l 'exec_command tty=true requires a native PTY backend' 2>/dev/null || true)"
  if [[ -n "$fallback_hits" ]]; then
    echo "app bundle still contains the non-Simulator PTY fallback:" >&2
    echo "$fallback_hits" >&2
    exit 1
  fi

  local has_pty_symbol=0
  while IFS= read -r -d '' candidate; do
    if nm -gU "$candidate" 2>/dev/null | awk '/_msp_spawn_pty_process/ { found = 1 } END { exit found ? 0 : 1 }'; then
      has_pty_symbol=1
      break
    fi
  done < <(find "$app_bundle" -type f \( -perm -111 -o -name '*.dylib' \) -print0)
  if [[ "$has_pty_symbol" != "1" ]]; then
    echo "app bundle does not contain the Simulator PTY backend symbol _msp_spawn_pty_process" >&2
    exit 1
  fi
}

is_owned_e2e_build_path() {
  local path="$1"
  local root
  for root in \
    "$OUT_DIR" \
    "$ROOT_DIR/.codex-tmp" \
    "$ROOT_DIR/.build/msp-conformance" \
    "${MSP_PLAYGROUND_PRESSURE_BUILD_ROOT:-}"
  do
    root="${root%/}"
    [[ -z "$root" || "$root" == "/" ]] && continue
    if [[ "$path" == "$root/"* ]]; then
      return 0
    fi
  done
  [[ "$path" == /tmp/msp-playground-* ]]
}

clean_e2e_build_path() {
  local path="$1"
  local label="$2"
  if [[ -z "$path" || "$path" == "/" || "$path" == "$OUT_DIR" ]]; then
    echo "refusing to clean unsafe $label: $path" >&2
    exit 2
  fi
  if is_owned_e2e_build_path "$path"; then
    rm -rf "$path"
    return
  fi
  echo "refusing to clean $label outside E2E-owned roots: $path" >&2
  exit 2
}

case "$SKIP_BUILD" in
  0|1) ;;
  *)
    echo "invalid MSP_PLAYGROUND_SHELL_DIAGNOSTIC_SKIP_BUILD; expected 0 or 1" >&2
    exit 2
    ;;
esac

case "$RUN_LIFECYCLE_DIAGNOSTIC" in
  0|1) ;;
  *)
    echo "invalid MSP_PLAYGROUND_RUN_LIFECYCLE_DIAGNOSTIC; expected 0 or 1" >&2
    exit 2
    ;;
esac

if [[ "$SKIP_BUILD" != "1" ]]; then
  clean_e2e_build_path "$BUILD_DIR" "build directory"
  clean_e2e_build_path "$DERIVED_DATA_PATH" "DerivedData path"
  mkdir -p "$OUT_DIR"
fi

DEVICE_ID="${MSP_PLAYGROUND_E2E_DEVICE_ID:-}"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/Booted/ { print $2; exit }')"
fi
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Shutdown/ { print $2; exit }')"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "no available iOS simulator found" >&2
    exit 2
  fi
  run_simctl_command_with_timeout "boot simulator" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl boot "$DEVICE_ID" >/dev/null
fi

if [[ "$SKIP_BUILD" == "1" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "MSP_PLAYGROUND_SHELL_DIAGNOSTIC_SKIP_BUILD=1 but app bundle does not exist: $APP_BUNDLE" >&2
    exit 2
  fi
else
  xcodebuild \
    -project "$PROJECT" \
    -scheme MSPPlaygroundApp \
    -sdk iphonesimulator \
    -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Debug-iphonesimulator" \
    build >"$OUT_DIR/xcodebuild.log"
fi

if [[ "$SKIP_BUILD" != "1" && -n "$PYTHON_XCFRAMEWORK_PATH" ]]; then
  embedded_python_env="$("$SCRIPT_DIR/embed-cpython-xcframework.sh" "$APP_BUNDLE" "$PYTHON_XCFRAMEWORK_PATH" "$OUT_DIR")"
  eval "$embedded_python_env"
fi

verify_simulator_pty_backend "$APP_BUNDLE"

run_simctl_command_with_timeout "terminate existing app" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
run_simctl_command_with_timeout "install app" "$SIMCTL_INSTALL_TIMEOUT_SECONDS" xcrun simctl install "$DEVICE_ID" "$APP_BUNDLE"

APP_DATA="$(run_simctl_command_with_timeout "read app data container" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"
INSTALLED_APP_BUNDLE="$(run_simctl_command_with_timeout "read installed app bundle" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" app)"
EVENT_LOG="$APP_DATA/Documents/msp-playground-e2e-events.jsonl"
rm -f "$EVENT_LOG"
ORACLE_FIXTURE_DST=""
if [[ "$RUN_PYTHON_ORACLE" == "1" ]]; then
  if [[ ! -f "$ORACLE_FIXTURE_SRC" ]]; then
    echo "oracle fixture not found: $ORACLE_FIXTURE_SRC" >&2
    exit 2
  fi
  ORACLE_DIR="$APP_DATA/Documents/MSPPlaygroundApp/E2E/Oracle"
  rm -rf "$ORACLE_DIR"
  mkdir -p "$ORACLE_DIR"
  ORACLE_FIXTURE_DST="$ORACLE_DIR/noninteractive-cases.json"
  cp "$ORACLE_FIXTURE_SRC" "$ORACLE_FIXTURE_DST"
fi

STDOUT_LOG="$OUT_DIR/app.stdout.log"
STDERR_LOG="$OUT_DIR/app.stderr.log"
rm -f "$STDOUT_LOG" "$STDERR_LOG"
SIMCTL_LOCAL_TMP_ROOT="${MSP_SIMCTL_LOCAL_TMP_ROOT:-/private/tmp}"
SIMCTL_LOCAL_TMP_ROOT="${SIMCTL_LOCAL_TMP_ROOT%/}"
[[ -z "$SIMCTL_LOCAL_TMP_ROOT" ]] && SIMCTL_LOCAL_TMP_ROOT="/private/tmp"
case "$SIMCTL_LOCAL_TMP_ROOT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*) ;;
  *)
    echo "MSP_SIMCTL_LOCAL_TMP_ROOT must be under /tmp or /private/tmp: $SIMCTL_LOCAL_TMP_ROOT" >&2
    exit 2
    ;;
esac
mkdir -p "$SIMCTL_LOCAL_TMP_ROOT"
SIMCTL_LOG_DIR="$(mktemp -d "$SIMCTL_LOCAL_TMP_ROOT/msp-playground-simctl-logs.XXXXXX")"
SIMCTL_STDOUT_LOG="$SIMCTL_LOG_DIR/app.stdout.log"
SIMCTL_STDERR_LOG="$SIMCTL_LOG_DIR/app.stderr.log"
copy_simctl_logs() {
  if [[ -f "$SIMCTL_STDOUT_LOG" ]]; then
    cp "$SIMCTL_STDOUT_LOG" "$STDOUT_LOG"
  fi
  if [[ -f "$SIMCTL_STDERR_LOG" ]]; then
    cp "$SIMCTL_STDERR_LOG" "$STDERR_LOG"
  fi
  rm -rf "$SIMCTL_LOG_DIR"
}
trap copy_simctl_logs EXIT

launch_args=(
  --msp-e2e-log-events
  --msp-shell-diagnostic
  --msp-hide-model-settings
)
if [[ "$RUN_LIFECYCLE_DIAGNOSTIC" == "1" ]]; then
  launch_args+=(--msp-shell-lifecycle-diagnostic)
fi
if [[ "$ENABLE_PYTHON" == "1" ]]; then
  launch_args+=(--msp-enable-python)
fi
if [[ -n "$PYTHON_XCFRAMEWORK_PATH" ]]; then
  launch_args+=("--msp-cpython-library-path=$INSTALLED_APP_BUNDLE/Frameworks/Python.framework/Python")
  launch_args+=("--msp-cpython-home=$INSTALLED_APP_BUNDLE/python")
elif [[ -n "${MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH:-}" ]]; then
  launch_args+=("--msp-cpython-library-path=$MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH")
fi
if [[ -z "$PYTHON_XCFRAMEWORK_PATH" && -n "${MSP_PLAYGROUND_CPYTHON_HOME:-}" ]]; then
  launch_args+=("--msp-cpython-home=$MSP_PLAYGROUND_CPYTHON_HOME")
fi
if [[ "$RUN_PYTHON_ORACLE" == "1" ]]; then
  launch_args+=("--msp-shell-oracle-path=$ORACLE_FIXTURE_DST")
fi
if [[ -n "${MSP_PLAYGROUND_WORKSPACE_PROFILE:-}" ]]; then
  launch_args+=("--msp-workspace-profile=$MSP_PLAYGROUND_WORKSPACE_PROFILE")
fi

LAUNCH_LOG="$OUT_DIR/launch.log"
: >"$LAUNCH_LOG"
SIMCTL_LAUNCH_TIMEOUT_SECONDS="${MSP_PLAYGROUND_SIMCTL_LAUNCH_TIMEOUT_SECONDS:-30}"

launch_has_started() {
  if [[ -f "$EVENT_LOG" ]]; then
    return 0
  fi
  grep -Eq "^${BUNDLE_ID}: [0-9]+$" "$LAUNCH_LOG" 2>/dev/null
}

run_launch_with_timeout() {
  local label="$1"
  local allow_started_probe="$2"
  local pid=""
  local status=0
  local start="$SECONDS"
  shift 2

  "$@" &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$allow_started_probe" == "1" ]] && launch_has_started; then
      pkill -TERM -P "$pid" >/dev/null 2>&1 || true
      kill -TERM "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    if (( SECONDS - start >= SIMCTL_LAUNCH_TIMEOUT_SECONDS )); then
      echo "$label simctl launch timed out after ${SIMCTL_LAUNCH_TIMEOUT_SECONDS}s" >>"$LAUNCH_LOG"
      pkill -TERM -P "$pid" >/dev/null 2>&1 || true
      kill -TERM "$pid" >/dev/null 2>&1 || true
      sleep 1
      pkill -KILL -P "$pid" >/dev/null 2>&1 || true
      kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
  done

  set +e
  wait "$pid"
  status="$?"
  set -e
  if [[ "$status" != "0" && "$allow_started_probe" == "1" ]] && launch_has_started; then
    return 0
  fi
  return "$status"
}

launch_shell_diagnostic_app() {
  SIMCTL_CHILD_MSP_PLAYGROUND_WORKSPACE_PROFILE="${MSP_PLAYGROUND_WORKSPACE_PROFILE:-}" \
  xcrun simctl launch \
    --terminate-running-process \
    --stdout="$SIMCTL_STDOUT_LOG" \
    --stderr="$SIMCTL_STDERR_LOG" \
    "$DEVICE_ID" \
    "$BUNDLE_ID" \
    "${launch_args[@]}" >>"$LAUNCH_LOG" 2>&1
}

lifecycle_launch_app() {
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" >>"$LAUNCH_LOG" 2>&1
}

if ! run_launch_with_timeout "initial" 1 launch_shell_diagnostic_app; then
  {
    echo "initial simctl launch failed; retrying after terminate"
    echo "installed_app_bundle=$INSTALLED_APP_BUNDLE"
  } >>"$LAUNCH_LOG"
  run_simctl_command_with_timeout "terminate before launch retry" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 2
  if ! run_launch_with_timeout "retry" 1 launch_shell_diagnostic_app; then
    echo "simctl launch failed after retry; launch log: $LAUNCH_LOG" >&2
    cat "$LAUNCH_LOG" >&2
    exit 1
  fi
fi

if [[ "$RUN_LIFECYCLE_DIAGNOSTIC" == "1" ]]; then
  deadline=$((SECONDS + ${MSP_PLAYGROUND_SHELL_LIFECYCLE_TIMEOUT_SECONDS:-30}))
  while (( SECONDS < deadline )); do
    if [[ -f "$EVENT_LOG" ]] && grep -q '"event":"shell_diagnostic_lifecycle_waiting_for_background"' "$EVENT_LOG"; then
      break
    fi
    sleep 1
  done
  if [[ ! -f "$EVENT_LOG" ]] || ! grep -q '"event":"shell_diagnostic_lifecycle_waiting_for_background"' "$EVENT_LOG"; then
    echo "app did not reach lifecycle diagnostic background wait state" >&2
    exit 1
  fi
  run_simctl_command_with_timeout "open lifecycle background URL" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl openurl "$DEVICE_ID" "https://example.invalid/msp-playground-lifecycle-background" >/dev/null
  sleep 1
  if ! run_launch_with_timeout "lifecycle" 0 lifecycle_launch_app; then
    echo "lifecycle simctl relaunch failed; retrying" >>"$LAUNCH_LOG"
    sleep 2
    if ! run_launch_with_timeout "lifecycle retry" 0 lifecycle_launch_app; then
      echo "lifecycle simctl relaunch failed after retry; launch log: $LAUNCH_LOG" >&2
      cat "$LAUNCH_LOG" >&2
      exit 1
    fi
  fi
fi

deadline=$((SECONDS + ${MSP_PLAYGROUND_SHELL_DIAGNOSTIC_TIMEOUT_SECONDS:-30}))
while (( SECONDS < deadline )); do
  if [[ -f "$EVENT_LOG" ]] && grep -q '"event":"shell_diagnostic_finished"' "$EVENT_LOG"; then
    if [[ "$RUN_PYTHON_ORACLE" != "1" ]] || grep -q '"event":"shell_oracle_finished"' "$EVENT_LOG"; then
      break
    fi
  fi
  sleep 1
done

if [[ "$RUN_PYTHON_ORACLE" == "1" ]]; then
  deadline=$((SECONDS + ${MSP_PLAYGROUND_SHELL_ORACLE_TIMEOUT_SECONDS:-120}))
  while (( SECONDS < deadline )); do
    if [[ -f "$EVENT_LOG" ]] && grep -q '"event":"shell_oracle_finished"' "$EVENT_LOG"; then
      break
    fi
    sleep 1
  done
fi

if [[ ! -f "$EVENT_LOG" ]]; then
  echo "event log was not created: $EVENT_LOG" >&2
  exit 1
fi

cp "$EVENT_LOG" "$OUT_DIR/events.jsonl"

python3 - "$EVENT_LOG" "$ENABLE_PYTHON" "${MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH:-$PYTHON_XCFRAMEWORK_PATH}" "$RUN_PYTHON_ORACLE" "$ORACLE_FIXTURE_SRC" "$RUN_LIFECYCLE_DIAGNOSTIC" <<'PY'
import json
import sys

event_log, enable_python, cpython_library_path, run_python_oracle, oracle_fixture, run_lifecycle = sys.argv[1:7]
events = []
with open(event_log, "r", encoding="utf-8") as handle:
    for line in handle:
        events.append(json.loads(line))

commands = [
    event["fields"]
    for event in events
    if event.get("event") == "shell_diagnostic_command"
]

def command_fields(command):
    for fields in commands:
        if fields.get("command") == command:
            return fields
    raise SystemExit(f"missing diagnostic command: {command}")

posix = command_fields("printf 'ios-shell-ok\\n'")
if posix.get("exit_code") != "0" or posix.get("stdout") != "ios-shell-ok\n" or posix.get("stderr") != "":
    raise SystemExit(f"POSIX shell diagnostic failed: {posix!r}")

exec_sessions = [
    event["fields"]
    for event in events
    if event.get("event") == "shell_diagnostic_exec_session"
]
pty_smoke = next(
    (fields for fields in exec_sessions if fields.get("name") == "pty_smoke"),
    None,
)
if pty_smoke is None:
    raise SystemExit("missing shell_diagnostic_exec_session pty_smoke event")
pty_stdout = pty_smoke.get("stdout", "").replace("\r\n", "\n")
pty_stderr = pty_smoke.get("stderr", "")
if (
    pty_smoke.get("exit_code") != "0"
    or "ios-pty-ok\n" not in pty_stdout
    or pty_stderr
    or pty_smoke.get("final_running_session_id")
):
    raise SystemExit(f"PTY exec session diagnostic failed: {pty_smoke!r}")

if run_lifecycle == "1":
    phases = [
        event["fields"].get("phase", "")
        for event in events
        if event.get("event") == "scene_phase"
    ]
    if "background" not in phases:
        raise SystemExit(f"missing Simulator app background scene phase: {phases!r}")
    lifecycle = next(
        (fields for fields in exec_sessions if fields.get("name") == "app_lifecycle_session"),
        None,
    )
    if lifecycle is None:
        raise SystemExit("missing shell_diagnostic_exec_session app_lifecycle_session event")
    lifecycle_stdout = lifecycle.get("stdout", "").replace("\r\n", "\n")
    lifecycle_stderr = lifecycle.get("stderr", "")
    foreground_phase = lifecycle.get("foreground_scene_phase", "")
    if (
        lifecycle.get("exit_code") != "0"
        or "lifecycle-session-start\n" not in lifecycle_stdout
        or "lifecycle-session-end\n" not in lifecycle_stdout
        or lifecycle_stderr
        or lifecycle.get("final_running_session_id")
        or lifecycle.get("background_observed") != "true"
        or lifecycle.get("foreground_observed") != "true"
        or foreground_phase not in ("active", "inactive")
    ):
        raise SystemExit(f"app lifecycle exec session diagnostic failed: {lifecycle!r}")

python = command_fields("python3 -c 'print(42)'")
if enable_python != "1":
    if python.get("exit_code") != "127" or "command not found" not in python.get("stderr", ""):
        raise SystemExit(f"expected disabled Python command-not-found surface: {python!r}")
elif not cpython_library_path:
    if python.get("exit_code") != "126" or "CPython library is not configured" not in python.get("stderr", ""):
        raise SystemExit(f"expected configured-missing CPython surface: {python!r}")
else:
    if python.get("exit_code") != "0" or python.get("stdout") != "42\n" or python.get("stderr") != "":
        raise SystemExit(f"embedded CPython smoke failed: {python!r}")

if run_python_oracle == "1":
    with open(oracle_fixture, "r", encoding="utf-8") as handle:
        fixture = json.load(handle)
    expected_case_count = sum(
        1
        for case in fixture.get("cases", [])
        if "python3" in case.get("commands", [])
        and "node" not in case.get("commands", [])
    )
    finished = [
        event["fields"]
        for event in events
        if event.get("event") == "shell_oracle_finished"
    ]
    if not finished:
        raise SystemExit("missing shell_oracle_finished event")
    oracle = finished[-1]
    if oracle.get("selected_case_count") != str(expected_case_count):
        raise SystemExit(f"expected {expected_case_count} Python oracle cases: {oracle!r}")
    if oracle.get("passed_case_count") != str(expected_case_count) or oracle.get("failed_case_count") != "0":
        failures = [
            event["fields"]
            for event in events
            if event.get("event") == "shell_oracle_case"
            and event.get("fields", {}).get("passed") != "true"
        ]
        raise SystemExit(f"embedded CPython oracle failed: {oracle!r}; failures={failures!r}")
PY

echo "MSPPlaygroundApp shell diagnostic passed"
echo "event log: $OUT_DIR/events.jsonl"
