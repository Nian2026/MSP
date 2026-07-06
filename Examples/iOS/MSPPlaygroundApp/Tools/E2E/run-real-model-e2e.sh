#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
APP_DIR="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp"
PROJECT="$APP_DIR/Project/MSPPlaygroundApp.xcodeproj"
BUNDLE_ID="${MSP_PLAYGROUND_E2E_BUNDLE_ID:-${MSP_EXAMPLE_BUNDLE_ID_PREFIX:-com.modelshellprotocol.examples}.playground}"
OUT_DIR="${MSP_PLAYGROUND_E2E_OUT_DIR:-/tmp/msp-playground-e2e}"
BUILD_DIR="${MSP_PLAYGROUND_E2E_BUILD_DIR:-$OUT_DIR/build}"
DERIVED_DATA_PATH="${MSP_PLAYGROUND_E2E_DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}"

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
PROMPT="${MSP_PLAYGROUND_E2E_PROMPT:-帮我看看工作区}"
PROMPT_SEQUENCE_JSON="${MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON:-}"
EXPECT_TOOL="${MSP_PLAYGROUND_E2E_EXPECT_TOOL:-1}"
TIMEOUT_SECONDS="${MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS:-180}"
RESET_APP="${MSP_PLAYGROUND_E2E_RESET_APP:-0}"
ENABLE_PYTHON="${MSP_PLAYGROUND_E2E_ENABLE_PYTHON:-0}"
ENABLE_GIT="${MSP_PLAYGROUND_E2E_ENABLE_GIT:-0}"
PYTHON_XCFRAMEWORK_PATH="${MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH:-}"
SKIP_BUILD="${MSP_PLAYGROUND_E2E_SKIP_BUILD:-0}"
ALLOW_VISIBLE_EXEC_COMMAND="${MSP_PLAYGROUND_E2E_ALLOW_VISIBLE_EXEC_COMMAND:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"

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

  echo "MSPPlaygroundApp E2E enabled Python, but no CPython runtime is configured." >&2
  echo "set MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH or MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH" >&2
  echo "or run MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=iOS Conformance/Scripts/cache_beeware_cpython_apple_support.sh" >&2
  exit 2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env: $name" >&2
    exit 2
  fi
}

plist_value() {
  local plist="$1"
  local key="$2"
  if [[ -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
  fi
}

looks_like_url() {
  [[ "$1" == http://* || "$1" == https://* ]]
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
    echo "invalid MSP_PLAYGROUND_E2E_SKIP_BUILD; expected 0 or 1" >&2
    exit 2
    ;;
esac
resolve_python_runtime_if_enabled

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

if [[ -z "${MSP_PLAYGROUND_MODEL_BASE_URL:-}" || -z "${MSP_PLAYGROUND_MODEL_API_KEY:-}" || -z "${MSP_PLAYGROUND_MODEL:-}" ]]; then
  EXISTING_APP_DATA="$(run_simctl_command_with_timeout "read existing app data container" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data 2>/dev/null || true)"
  if [[ -n "$EXISTING_APP_DATA" ]]; then
    EXISTING_PREF="$EXISTING_APP_DATA/Library/Preferences/$BUNDLE_ID.plist"
    MSP_PLAYGROUND_MODEL_BASE_URL="${MSP_PLAYGROUND_MODEL_BASE_URL:-$(plist_value "$EXISTING_PREF" "msp.playground.model.baseURL")}"
    MSP_PLAYGROUND_MODEL_API_KEY="${MSP_PLAYGROUND_MODEL_API_KEY:-$(plist_value "$EXISTING_PREF" "msp.playground.model.apiKey")}"
    MSP_PLAYGROUND_MODEL="${MSP_PLAYGROUND_MODEL:-$(plist_value "$EXISTING_PREF" "msp.playground.model.model")}"
  fi
fi

require_env MSP_PLAYGROUND_MODEL_BASE_URL
require_env MSP_PLAYGROUND_MODEL
MSP_PLAYGROUND_MODEL_API_KEY="${MSP_PLAYGROUND_MODEL_API_KEY:-}"

if ! looks_like_url "$MSP_PLAYGROUND_MODEL_BASE_URL"; then
  echo "invalid MSP_PLAYGROUND_MODEL_BASE_URL; expected http(s) URL" >&2
  exit 2
fi

if [[ -n "$PROMPT_SEQUENCE_JSON" ]]; then
  EXPECTED_FINAL_ANSWERS="${MSP_PLAYGROUND_E2E_EXPECT_FINAL_ANSWERS:-$(python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' <<<"$PROMPT_SEQUENCE_JSON")}"
else
  EXPECTED_FINAL_ANSWERS="${MSP_PLAYGROUND_E2E_EXPECT_FINAL_ANSWERS:-1}"
fi

if [[ "$SKIP_BUILD" == "1" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "MSP_PLAYGROUND_E2E_SKIP_BUILD=1 but app bundle does not exist: $APP_BUNDLE" >&2
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

if [[ "$ENABLE_PYTHON" == "1" && -n "$PYTHON_XCFRAMEWORK_PATH" ]]; then
  if [[ "$SKIP_BUILD" != "1" ]]; then
    embedded_python_env="$("$SCRIPT_DIR/embed-cpython-xcframework.sh" "$APP_BUNDLE" "$PYTHON_XCFRAMEWORK_PATH" "$OUT_DIR")"
    eval "$embedded_python_env"
  elif [[ -f "$APP_BUNDLE/Frameworks/Python.framework/Python" && -d "$APP_BUNDLE/python" ]]; then
    MSP_PLAYGROUND_EMBEDDED_CPYTHON_LIBRARY_PATH="$APP_BUNDLE/Frameworks/Python.framework/Python"
    MSP_PLAYGROUND_EMBEDDED_CPYTHON_HOME="$APP_BUNDLE/python"
  else
    echo "MSP_PLAYGROUND_E2E_SKIP_BUILD=1 but embedded CPython was not found in app bundle: $APP_BUNDLE" >&2
    exit 2
  fi
fi

verify_simulator_pty_backend "$APP_BUNDLE"

run_simctl_command_with_timeout "terminate existing app" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$RESET_APP" == "1" ]]; then
  run_simctl_command_with_timeout "uninstall app" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
run_simctl_command_with_timeout "install app" "$SIMCTL_INSTALL_TIMEOUT_SECONDS" xcrun simctl install "$DEVICE_ID" "$APP_BUNDLE"

APP_DATA="$(run_simctl_command_with_timeout "read app data container" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"
INSTALLED_APP_BUNDLE="$(run_simctl_command_with_timeout "read installed app bundle" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" app)"
EVENT_LOG="$APP_DATA/Documents/msp-playground-e2e-events.jsonl"
rm -f "$EVENT_LOG"

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
SIMCTL_SCREENSHOT="$SIMCTL_LOG_DIR/screenshot.png"
copy_simctl_logs() {
  if [[ -n "${EVENT_LOG:-}" && -f "$EVENT_LOG" ]]; then
    cp "$EVENT_LOG" "$OUT_DIR/events.jsonl"
  fi
  if [[ -n "${SCREENSHOT:-}" && ! -f "$SIMCTL_SCREENSHOT" && -n "${DEVICE_ID:-}" ]]; then
    xcrun simctl io "$DEVICE_ID" screenshot "$SIMCTL_SCREENSHOT" >/dev/null 2>&1 || true
  fi
  if [[ -f "$SIMCTL_STDOUT_LOG" ]]; then
    cp "$SIMCTL_STDOUT_LOG" "$STDOUT_LOG"
  fi
  if [[ -f "$SIMCTL_STDERR_LOG" ]]; then
    cp "$SIMCTL_STDERR_LOG" "$STDERR_LOG"
  fi
  if [[ -n "${SCREENSHOT:-}" && -f "$SIMCTL_SCREENSHOT" ]]; then
    cp "$SIMCTL_SCREENSHOT" "$SCREENSHOT"
  fi
  rm -rf "$SIMCTL_LOG_DIR"
}
trap copy_simctl_logs EXIT

launch_args=(
  --msp-e2e-log-events
  --msp-probe-transcript-visible-text
  --msp-hide-model-settings
)
if [[ "$ENABLE_PYTHON" == "1" ]]; then
  launch_args+=(--msp-enable-python)
  if [[ -n "${MSP_PLAYGROUND_EMBEDDED_CPYTHON_LIBRARY_PATH:-}" ]]; then
    launch_args+=("--msp-cpython-library-path=$INSTALLED_APP_BUNDLE/Frameworks/Python.framework/Python")
    launch_args+=("--msp-cpython-home=$INSTALLED_APP_BUNDLE/python")
  elif [[ -n "${MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH:-}" ]]; then
    launch_args+=("--msp-cpython-library-path=$MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH")
    if [[ -n "${MSP_PLAYGROUND_CPYTHON_HOME:-}" ]]; then
      launch_args+=("--msp-cpython-home=$MSP_PLAYGROUND_CPYTHON_HOME")
    fi
  fi
fi
if [[ "$ENABLE_GIT" == "1" ]]; then
  launch_args+=(--msp-enable-git)
fi
if [[ -n "${MSP_PLAYGROUND_WORKSPACE_PROFILE:-}" ]]; then
  launch_args+=("--msp-workspace-profile=$MSP_PLAYGROUND_WORKSPACE_PROFILE")
fi
if [[ -z "$PROMPT_SEQUENCE_JSON" ]]; then
  launch_args+=("--msp-auto-submit=$PROMPT")
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
  local pid=""
  local status=0
  local start="$SECONDS"

  launch_app &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null; do
    if launch_has_started; then
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
  if [[ "$status" != "0" ]] && launch_has_started; then
    return 0
  fi
  return "$status"
}

launch_app() {
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_PROVIDER="${MSP_PLAYGROUND_MODEL_PROVIDER:-OpenAI-compatible}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_BASE_URL="$MSP_PLAYGROUND_MODEL_BASE_URL" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_API_KEY="$MSP_PLAYGROUND_MODEL_API_KEY" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL="$MSP_PLAYGROUND_MODEL" \
  SIMCTL_CHILD_MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON="$PROMPT_SEQUENCE_JSON" \
  SIMCTL_CHILD_MSP_PLAYGROUND_REASONING_EFFORT="${MSP_PLAYGROUND_REASONING_EFFORT:-medium}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_VERBOSITY="${MSP_PLAYGROUND_VERBOSITY:-medium}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_WORKSPACE_PROFILE="${MSP_PLAYGROUND_WORKSPACE_PROFILE:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_CODEX_ID_TOKEN="${MSP_PLAYGROUND_CODEX_ID_TOKEN:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_CODEX_ACCESS_TOKEN="${MSP_PLAYGROUND_CODEX_ACCESS_TOKEN:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_CODEX_REFRESH_TOKEN="${MSP_PLAYGROUND_CODEX_REFRESH_TOKEN:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_CODEX_ACCOUNT_ID="${MSP_PLAYGROUND_CODEX_ACCOUNT_ID:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_CODEX_EMAIL="${MSP_PLAYGROUND_CODEX_EMAIL:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_CODEX_PLAN_TYPE="${MSP_PLAYGROUND_CODEX_PLAN_TYPE:-}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_E2E_LOG_EVENTS=1 \
  SIMCTL_CHILD_MSP_PLAYGROUND_TRANSCRIPT_VISIBLE_TEXT_PROBE=1 \
  xcrun simctl launch \
    --terminate-running-process \
    --stdout="$SIMCTL_STDOUT_LOG" \
    --stderr="$SIMCTL_STDERR_LOG" \
    "$DEVICE_ID" \
    "$BUNDLE_ID" \
    "${launch_args[@]}" >>"$LAUNCH_LOG" 2>&1
}

if ! run_launch_with_timeout "initial"; then
  {
    echo "initial simctl launch failed; retrying after terminate"
    echo "installed_app_bundle=$INSTALLED_APP_BUNDLE"
  } >>"$LAUNCH_LOG"
  run_simctl_command_with_timeout "terminate before launch retry" "$SIMCTL_COMMAND_TIMEOUT_SECONDS" xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 2
  if ! run_launch_with_timeout "retry"; then
    echo "simctl launch failed after retry; launch log: $LAUNCH_LOG" >&2
    cat "$LAUNCH_LOG" >&2
    exit 1
  fi
fi

SCREENSHOT="$OUT_DIR/screenshot.png"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if [[ -f "$EVENT_LOG" ]]; then
    if grep -q '"event":"runtime_error"' "$EVENT_LOG"; then
      echo "runtime_error observed; event log: $EVENT_LOG" >&2
      cat "$EVENT_LOG" >&2
      exit 1
    fi
    final_answer_count="$(grep -c '"event":"final_answer"' "$EVENT_LOG" || true)"
    if [[ "$final_answer_count" -ge "$EXPECTED_FINAL_ANSWERS" ]]; then
      break
    fi
  fi
  sleep 2
done

if [[ ! -f "$EVENT_LOG" ]]; then
  echo "event log was not created: $EVENT_LOG" >&2
  exit 1
fi

if ! grep -q '"event":"model_request_built"' "$EVENT_LOG"; then
  echo "model_request_built was not observed" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

final_answer_count="$(grep -c '"event":"final_answer"' "$EVENT_LOG" || true)"
if [[ "$final_answer_count" -lt "$EXPECTED_FINAL_ANSWERS" ]]; then
  echo "expected $EXPECTED_FINAL_ANSWERS final_answer events before timeout; observed $final_answer_count" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if ! grep -q '"event":"final_answer_delta"' "$EVENT_LOG"; then
  echo "streaming final_answer_delta was not observed" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if [[ "$EXPECT_TOOL" == "1" ]]; then
  if ! grep -q '"event":"tool_started"' "$EVENT_LOG"; then
    echo "tool_started was not observed" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
  if ! grep -q '"event":"tool_completed"' "$EVENT_LOG"; then
    echo "tool_completed was not observed" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
  if ! grep -q '"status_text":"正在执行工作区命令"' "$EVENT_LOG"; then
    echo "workspace command status text was not observed" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
  if ! grep -q '"content_kind":"string"' "$EVENT_LOG"; then
    echo "tool result was not recorded as agent-facing plain string output" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
  if ! grep -q '"content_contains_shell_json_keys":"false"' "$EVENT_LOG"; then
    echo "tool result appears to expose structured shell JSON to the model" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
else
  if grep -q '"event":"tool_started"' "$EVENT_LOG"; then
    echo "tool_started was observed but MSP_PLAYGROUND_E2E_EXPECT_TOOL=0" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
  if grep -q '"event":"tool_completed"' "$EVENT_LOG"; then
    echo "tool_completed was observed but MSP_PLAYGROUND_E2E_EXPECT_TOOL=0" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
fi

sleep "${MSP_PLAYGROUND_E2E_PROBE_SETTLE_SECONDS:-1}"

if ! grep -q '"event":"transcript_visible_text_probe"' "$EVENT_LOG"; then
  echo "transcript visible text probe was not observed" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"contains_exec_command_outside_user_messages":"true"' "$EVENT_LOG"; then
  if [[ "$ALLOW_VISIBLE_EXEC_COMMAND" != "1" ]]; then
    echo "transcript visibly leaked exec_command outside user messages" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
elif ! grep -q '"contains_exec_command_outside_user_messages"' "$EVENT_LOG" \
  && grep -q '"contains_exec_command":"true"' "$EVENT_LOG"; then
  if [[ "$ALLOW_VISIBLE_EXEC_COMMAND" != "1" ]]; then
    echo "transcript visibly leaked exec_command" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  fi
fi

if grep -q '"contains_internal_shell_tool_name":"true"' "$EVENT_LOG"; then
  echo "transcript visibly leaked an internal shell tool name" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"contains_shell_json_keys":"true"' "$EVENT_LOG"; then
  echo "transcript visibly leaked shell JSON keys" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if xcrun simctl io "$DEVICE_ID" screenshot "$SIMCTL_SCREENSHOT" >/dev/null; then
  cp "$SIMCTL_SCREENSHOT" "$SCREENSHOT"
else
  echo "warning: failed to capture final simulator screenshot" >&2
fi

cp "$EVENT_LOG" "$OUT_DIR/events.jsonl"

echo "MSPPlaygroundApp real-model E2E passed"
echo "device=$DEVICE_ID"
echo "final_answers=$final_answer_count"
echo "event_log=$OUT_DIR/events.jsonl"
echo "screenshot=$SCREENSHOT"
echo "stdout=$STDOUT_LOG"
echo "stderr=$STDERR_LOG"
