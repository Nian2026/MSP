#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
REQUIRED_MODEL="gpt-5.5"
PROMPTS_FILE="${MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE:-$SCRIPT_DIR/pressure/photosorter-virtual-workspace-prompts.json}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_PHOTOSORTER_PRESSURE_OUT_DIR:-/tmp/photosorter-real-model-pressure/$STAMP}"
BUILD_ROOT="${MSP_PHOTOSORTER_PRESSURE_BUILD_ROOT:-/tmp/photosorter-real-model-pressure-builds/$STAMP}"

absolute_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve())
PY
}

OUT_DIR="$(absolute_path "$OUT_DIR")"
BUILD_ROOT="$(absolute_path "$BUILD_ROOT")"
RESET_APP="${MSP_PHOTOSORTER_PRESSURE_RESET_APP:-${MSP_PLAYGROUND_E2E_RESET_APP:-1}}"
REQUIRE_CPYTHON="${MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON:-1}"
REQUIRE_EXEC_SESSION_CONTRACT="${MSP_PHOTOSORTER_PRESSURE_REQUIRE_EXEC_SESSION_CONTRACT:-0}"
VERIFIER="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp/Tools/E2E/verify-real-model-pressure-log.py"
LOCK_DIRS=("")

usage() {
  cat <<USAGE
Usage: MSP_PLAYGROUND_MODEL_BASE_URL=... MSP_PLAYGROUND_MODEL_API_KEY=... MSP_PLAYGROUND_MODEL=$REQUIRED_MODEL \\
  $0

Runs the PhotoSorter virtual-workspace real-model pressure scenario with a real
OpenAI-compatible provider. The run fails if model-visible output leaks sandbox,
broker, materialized, launcher, or runtime paths, or if the model says it can
distinguish the workspace from a regular Linux workspace with the same files.

Environment:
  MSP_PLAYGROUND_MODEL_BASE_URL          required provider base URL
  MSP_PLAYGROUND_MODEL_API_KEY           required provider API key
  MSP_PLAYGROUND_MODEL                   must equal $REQUIRED_MODEL
  MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH preferred CPython packaging input
  MSP_PHOTOSORTER_PYTHON_XCFRAMEWORK_PATH alternate CPython packaging input
  MSP_PHOTOSORTER_PRESSURE_OUT_DIR       output directory
  MSP_PHOTOSORTER_PRESSURE_BUILD_ROOT    xcodebuild product/DerivedData root,
                                         default /tmp/photosorter-real-model-pressure-builds/<stamp>
  MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE  prompt JSON array
  MSP_PHOTOSORTER_PRESSURE_RESET_APP      must remain 1
  MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON must remain 1
  MSP_PHOTOSORTER_PRESSURE_REQUIRE_EXEC_SESSION_CONTRACT=1 to require
                                      yield/poll/PTY/stdin/interrupt evidence
  MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is rejected
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
    echo "$name=1 is not allowed in the real-model pressure suite" >&2
    exit 2
  fi
}

reject_nonempty_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    echo "$name is not allowed in the real-model pressure suite" >&2
    exit 2
  fi
}

require_enabled_setting() {
  local name="$1"
  local value="$2"
  case "$value" in
    1) ;;
    0)
      echo "$name=0 is not allowed in the real-model pressure suite" >&2
      exit 2
      ;;
    *)
      echo "invalid $name; expected 1" >&2
      exit 2
      ;;
  esac
}

release_locks() {
  local lock_dir
  for lock_dir in "${LOCK_DIRS[@]}"; do
    [[ -n "$lock_dir" ]] && rm -rf "$lock_dir"
  done
  return 0
}

trap release_locks EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_real_model_ui_pressure_lock() {
  if [[ "${MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD:-0}" == "1" ]]; then
    return
  fi

  local lock_dir="$ROOT_DIR/.build/msp-conformance/locks/real-model-ui-pressure.lock"
  local lock_parent
  lock_parent="$(dirname "$lock_dir")"
  mkdir -p "$lock_parent"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_dir/pid"
    printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
    LOCK_DIRS+=("$lock_dir")
    export MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD=1
    echo "real-model UI pressure lock: $lock_dir"
    return
  fi

  local existing_pid=""
  if [[ -f "$lock_dir/pid" ]]; then
    existing_pid="$(head -n 1 "$lock_dir/pid" 2>/dev/null || true)"
  fi
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "real-model UI pressure is already running under pid $existing_pid; refusing to run concurrently" >&2
    if [[ -f "$lock_dir/context" ]]; then
      cat "$lock_dir/context" >&2
    fi
    exit 2
  fi

  echo "removing stale real-model UI pressure lock: $lock_dir" >&2
  rm -rf "$lock_dir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "failed to acquire real-model UI pressure lock: $lock_dir" >&2
    exit 2
  fi
  printf '%s\n' "$$" >"$lock_dir/pid"
  printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
  LOCK_DIRS+=("$lock_dir")
  export MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD=1
  echo "real-model UI pressure lock: $lock_dir"
}

require_env MSP_PLAYGROUND_MODEL_BASE_URL
require_env MSP_PLAYGROUND_MODEL_API_KEY
require_env MSP_PLAYGROUND_MODEL
if [[ "$MSP_PLAYGROUND_MODEL" != "$REQUIRED_MODEL" ]]; then
  echo "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the real-model pressure suite; got $MSP_PLAYGROUND_MODEL" >&2
  exit 2
fi
reject_true_env MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE
reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_NONCE
reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT
reject_nonempty_env MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT
require_enabled_setting MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON "$REQUIRE_CPYTHON"
require_enabled_setting MSP_PHOTOSORTER_PRESSURE_RESET_APP/MSP_PLAYGROUND_E2E_RESET_APP "$RESET_APP"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  echo "PhotoSorter pressure prompts file not found: $PROMPTS_FILE" >&2
  exit 2
fi
prompt_payload="$(python3 "$ROOT_DIR/Conformance/Scripts/msp_pressure_prompt_contract.py" "$PROMPTS_FILE")"
PROMPT_SEQUENCE_JSON="$(printf '%s\n' "$prompt_payload" | sed -n '1p')"
EXPECTED_FINAL_ANSWERS="$(printf '%s\n' "$prompt_payload" | sed -n '2p')"
REQUIRED_FINAL_SENTINELS_JSON="$(printf '%s\n' "$prompt_payload" | sed -n '3p')"
REQUIRED_FINAL_SENTINELS=()
while IFS= read -r sentinel; do
  if [[ -n "$sentinel" ]]; then
    REQUIRED_FINAL_SENTINELS+=("$sentinel")
  fi
done < <(python3 - "$REQUIRED_FINAL_SENTINELS_JSON" <<'PY'
import json
import sys

for sentinel in json.loads(sys.argv[1]):
    print(sentinel)
PY
)

acquire_real_model_ui_pressure_lock

if [[ ! -f "$VERIFIER" ]]; then
  echo "pressure verifier not found: $VERIFIER" >&2
  exit 2
fi

case "$RESET_APP" in
  0|1) ;;
  *)
    echo "invalid MSP_PHOTOSORTER_PRESSURE_RESET_APP; expected 0 or 1" >&2
    exit 2
    ;;
esac

if [[ "$REQUIRE_CPYTHON" == "1" \
  && -z "${MSP_PHOTOSORTER_PYTHON_XCFRAMEWORK_PATH:-}" \
  && -z "${MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH:-}" ]]; then
  shopt -s nullglob
  cached_xcframeworks=("$ROOT_DIR"/.build/msp-cpython-ios-cache/Python-*-iOS-support.*/Python.xcframework)
  shopt -u nullglob
  if (( ${#cached_xcframeworks[@]} == 0 )); then
    echo "PhotoSorter pressure requires CPython by default" >&2
    echo "set MSP_PHOTOSORTER_PYTHON_XCFRAMEWORK_PATH or MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH" >&2
    echo "set MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0 only for non-Python diagnostics" >&2
    exit 2
  fi
fi

mkdir -p "$OUT_DIR"

if [[ "${MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE:-0}" != "1" ]]; then
  MSP_PLAYGROUND_PROVIDER_CHECK_OUT_DIR="$OUT_DIR/provider-smoke" \
    "$SCRIPT_DIR/check-openai-responses-provider.sh"
fi

MSP_PLAYGROUND_E2E_OUT_DIR="$OUT_DIR/e2e" \
MSP_PHOTOSORTER_E2E_BUILD_DIR="${MSP_PHOTOSORTER_E2E_BUILD_DIR:-$BUILD_ROOT/e2e/build}" \
MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH="${MSP_PHOTOSORTER_E2E_DERIVED_DATA_PATH:-$BUILD_ROOT/e2e/DerivedData}" \
MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON="$PROMPT_SEQUENCE_JSON" \
MSP_PLAYGROUND_E2E_EXPECT_FINAL_ANSWERS="$EXPECTED_FINAL_ANSWERS" \
MSP_PLAYGROUND_E2E_EXPECT_TOOL=1 \
MSP_PLAYGROUND_E2E_RESET_APP="$RESET_APP" \
MSP_PHOTOSORTER_REQUIRE_CPYTHON="$REQUIRE_CPYTHON" \
MSP_PLAYGROUND_E2E_ALLOW_VISIBLE_EXEC_COMMAND="${MSP_PLAYGROUND_E2E_ALLOW_VISIBLE_EXEC_COMMAND:-$([[ "$REQUIRE_EXEC_SESSION_CONTRACT" == "1" ]] && printf 1 || printf 0)}" \
MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS="${MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS:-600}" \
  "$SCRIPT_DIR/run-real-model-e2e.sh"

cp "$OUT_DIR/e2e/events.jsonl" "$OUT_DIR/events.jsonl"

verifier_args=(
  "$OUT_DIR/events.jsonl"
  --expected-final-answers "$EXPECTED_FINAL_ANSWERS"
  --report "$OUT_DIR/pressure-report.json"
  --required-model "$REQUIRED_MODEL"
  --model "$MSP_PLAYGROUND_MODEL"
  --prompt-file "$PROMPTS_FILE"
  --require-provider-smoke
)
if [[ -f "$OUT_DIR/provider-smoke/provider-smoke-request.redacted.json" \
  && -f "$OUT_DIR/provider-smoke/provider-smoke-response.json" ]]; then
  verifier_args+=(
    --provider-smoke-request "$OUT_DIR/provider-smoke/provider-smoke-request.redacted.json"
    --provider-smoke-response "$OUT_DIR/provider-smoke/provider-smoke-response.json"
  )
fi
for sentinel in "${REQUIRED_FINAL_SENTINELS[@]}"; do
  verifier_args+=(--required-final-sentinel "$sentinel")
done
if [[ "$REQUIRE_EXEC_SESSION_CONTRACT" == "1" ]]; then
  verifier_args+=(--require-exec-session-contract)
fi

"$VERIFIER" "${verifier_args[@]}"

echo "PhotoSorter real-model pressure passed"
echo "root=$ROOT_DIR"
echo "out_dir=$OUT_DIR"
