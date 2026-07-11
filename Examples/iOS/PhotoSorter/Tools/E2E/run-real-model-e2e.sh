#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
APP_DIR="$ROOT_DIR/Examples/iOS/PhotoSorter"
PROJECT="$APP_DIR/Project/PhotoSorter.xcodeproj"
OUT_DIR="${MSP_PLAYGROUND_E2E_OUT_DIR:-/tmp/msp-playground-e2e}"
BUILD_DIR="${MSP_PHOTOSORTER_E2E_BUILD_DIR:-${MSP_PLAYGROUND_E2E_BUILD_DIR:-$OUT_DIR/build}}"
DERIVED_DATA_PATH="${MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH:-${MSP_PLAYGROUND_E2E_DERIVED_DATA_PATH:-$OUT_DIR/DerivedData}}"

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
APP_BUNDLE="$BUILD_DIR/Debug-iphonesimulator/PhotoSorter.app"
BUNDLE_ID="${MSP_PHOTOSORTER_E2E_BUNDLE_ID:-${MSP_EXAMPLE_BUNDLE_ID_PREFIX:-com.modelshellproxy.examples}.photosorter}"
PROMPT="${MSP_PLAYGROUND_E2E_PROMPT:-帮我看看工作区}"
PROMPT_SEQUENCE_JSON="${MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON:-}"
EXPECT_TOOL="${MSP_PLAYGROUND_E2E_EXPECT_TOOL:-1}"
TIMEOUT_SECONDS="${MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS:-180}"
RESET_APP="${MSP_PLAYGROUND_E2E_RESET_APP:-0}"
GRANT_PHOTOS="${MSP_PHOTOSORTER_E2E_GRANT_PHOTOS:-1}"
SKIP_PHOTO_AUTH_REQUEST="${MSP_PHOTOSORTER_E2E_SKIP_PHOTO_AUTH_REQUEST:-$GRANT_PHOTOS}"
SKIP_BUILD="${MSP_PLAYGROUND_E2E_SKIP_BUILD:-0}"
ALLOW_VISIBLE_EXEC_COMMAND="${MSP_PLAYGROUND_E2E_ALLOW_VISIBLE_EXEC_COMMAND:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"

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

mkdir -p "$OUT_DIR"

is_owned_e2e_build_path() {
  local path="$1"
  local root
  for root in \
    "$OUT_DIR" \
    "$ROOT_DIR/.codex-tmp" \
    "$ROOT_DIR/.build/msp-conformance" \
    "${MSP_PHOTOSORTER_PRESSURE_BUILD_ROOT:-}"
  do
    root="${root%/}"
    [[ -z "$root" || "$root" == "/" ]] && continue
    if [[ "$path" == "$root/"* ]]; then
      return 0
    fi
  done
  [[ "$path" == /tmp/msp-playground-* || "$path" == /tmp/photosorter-* ]]
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
  xcrun simctl boot "$DEVICE_ID" >/dev/null
fi

if [[ -z "${MSP_PLAYGROUND_MODEL_BASE_URL:-}" || -z "${MSP_PLAYGROUND_MODEL_API_KEY:-}" || -z "${MSP_PLAYGROUND_MODEL:-}" ]]; then
  EXISTING_APP_DATA="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data 2>/dev/null || true)"
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

case "$SKIP_BUILD" in
  0|1) ;;
  *)
    echo "invalid MSP_PLAYGROUND_E2E_SKIP_BUILD; expected 0 or 1" >&2
    exit 2
    ;;
esac
case "$SKIP_PHOTO_AUTH_REQUEST" in
  0|1) ;;
  *)
    echo "invalid MSP_PHOTOSORTER_E2E_SKIP_PHOTO_AUTH_REQUEST; expected 0 or 1" >&2
    exit 2
    ;;
esac

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
    -scheme PhotoSorter \
    -sdk iphonesimulator \
    -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Debug-iphonesimulator" \
    build >"$OUT_DIR/xcodebuild.log"
fi

if [[ ! -f "$APP_BUNDLE/Frameworks/Python.framework/Python" || ! -d "$APP_BUNDLE/python" ]]; then
  echo "PhotoSorter app bundle is missing embedded CPython; python3 would be unavailable." >&2
  echo "run MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=iOS Conformance/Scripts/cache_beeware_cpython_apple_support.sh" >&2
  echo "or set MSP_PHOTOSORTER_PYTHON_XCFRAMEWORK_PATH/MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH before building." >&2
  exit 2
fi

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$RESET_APP" == "1" ]]; then
  xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl install "$DEVICE_ID" "$APP_BUNDLE"

case "$GRANT_PHOTOS" in
  0|1) ;;
  *)
    echo "invalid MSP_PHOTOSORTER_E2E_GRANT_PHOTOS; expected 0 or 1" >&2
    exit 2
    ;;
esac

if [[ "$GRANT_PHOTOS" == "1" ]]; then
  xcrun simctl privacy "$DEVICE_ID" grant photos "$BUNDLE_ID"
  xcrun simctl privacy "$DEVICE_ID" grant photos-add "$BUNDLE_ID"
fi

APP_DATA="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"
INSTALLED_APP_BUNDLE="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" app)"
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
SIMCTL_LOG_DIR="$(mktemp -d "$SIMCTL_LOCAL_TMP_ROOT/photosorter-simctl-logs.XXXXXX")"
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
if [[ -z "$PROMPT_SEQUENCE_JSON" ]]; then
  launch_args+=("--msp-auto-submit=$PROMPT")
fi
if [[ "$SKIP_PHOTO_AUTH_REQUEST" == "1" ]]; then
  launch_args+=("--msp-skip-photo-library-authorization-request")
fi

SCREENSHOT="$OUT_DIR/screenshot.png"
LAUNCH_LOG="$OUT_DIR/launch.log"
: >"$LAUNCH_LOG"

launch_app() {
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_PROVIDER="${MSP_PLAYGROUND_MODEL_PROVIDER:-OpenAI-compatible}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_BASE_URL="$MSP_PLAYGROUND_MODEL_BASE_URL" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_API_KEY="$MSP_PLAYGROUND_MODEL_API_KEY" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL="$MSP_PLAYGROUND_MODEL" \
  SIMCTL_CHILD_MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON="$PROMPT_SEQUENCE_JSON" \
  SIMCTL_CHILD_MSP_PLAYGROUND_MODEL_CREDENTIAL_MODE="${MSP_PLAYGROUND_MODEL_CREDENTIAL_MODE:-}" \
  SIMCTL_CHILD_MSP_PHOTOSORTER_SKIP_PHOTO_LIBRARY_AUTHORIZATION_REQUEST="$SKIP_PHOTO_AUTH_REQUEST" \
  SIMCTL_CHILD_MSP_PLAYGROUND_REASONING_EFFORT="${MSP_PLAYGROUND_REASONING_EFFORT:-medium}" \
  SIMCTL_CHILD_MSP_PLAYGROUND_VERBOSITY="${MSP_PLAYGROUND_VERBOSITY:-medium}" \
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

if ! launch_app; then
  {
    echo "initial simctl launch failed; retrying after terminate"
    echo "installed_app_bundle=$INSTALLED_APP_BUNDLE"
  } >>"$LAUNCH_LOG"
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 2
  if ! launch_app; then
    echo "simctl launch failed after retry; launch log: $LAUNCH_LOG" >&2
    cat "$LAUNCH_LOG" >&2
    exit 1
  fi
fi

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

echo "PhotoSorter real-model E2E passed"
echo "device=$DEVICE_ID"
echo "final_answers=$final_answer_count"
echo "event_log=$OUT_DIR/events.jsonl"
echo "screenshot=$SCREENSHOT"
echo "stdout=$STDOUT_LOG"
echo "stderr=$STDERR_LOG"
