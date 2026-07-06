#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
REQUIRED_MODEL="gpt-5.5"
PROMPTS_FILE="${MSP_PLAYGROUND_GIT_PRESSURE_PROMPTS_FILE:-$SCRIPT_DIR/pressure/git-ios-parity-prompts.json}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_PLAYGROUND_GIT_PRESSURE_OUT_DIR:-/tmp/msp-playground-real-model-git-pressure/$STAMP}"
BUILD_ROOT="${MSP_PLAYGROUND_GIT_PRESSURE_BUILD_ROOT:-/tmp/msp-playground-real-model-git-pressure-builds/$STAMP}"

absolute_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve())
PY
}

OUT_DIR="$(absolute_path "$OUT_DIR")"
BUILD_ROOT="$(absolute_path "$BUILD_ROOT")"
LOCK_DIRS=("")

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
  return 0
}

trap release_locks EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_ui_e2e_lock() {
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
    echo "MSP UI E2E lock: $lock_dir"
    return
  fi

  local existing_pid=""
  if [[ -f "$lock_dir/pid" ]]; then
    existing_pid="$(head -n 1 "$lock_dir/pid" 2>/dev/null || true)"
  fi
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "MSP UI E2E is already running under pid $existing_pid; refusing to run concurrently" >&2
    if [[ -f "$lock_dir/context" ]]; then
      cat "$lock_dir/context" >&2
    fi
    exit 2
  fi

  echo "removing stale MSP UI E2E lock: $lock_dir" >&2
  rm -rf "$lock_dir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "failed to acquire MSP UI E2E lock: $lock_dir" >&2
    exit 2
  fi
  printf '%s\n' "$$" >"$lock_dir/pid"
  printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
  LOCK_DIRS+=("$lock_dir")
  export MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD=1
  echo "MSP UI E2E lock: $lock_dir"
}

usage() {
  cat <<USAGE
Usage: MSP_PLAYGROUND_MODEL_BASE_URL=... MSP_PLAYGROUND_MODEL_API_KEY=... MSP_PLAYGROUND_MODEL=$REQUIRED_MODEL \\
  $0

Runs a real-model MSPPlaygroundApp Git pressure scenario with the libgit2-backed
git command enabled. The run fails if model-visible output leaks implementation
paths or if the model says it can distinguish the workspace from regular Linux.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_env MSP_PLAYGROUND_MODEL_BASE_URL
require_env MSP_PLAYGROUND_MODEL_API_KEY
require_env MSP_PLAYGROUND_MODEL
if [[ "$MSP_PLAYGROUND_MODEL" != "$REQUIRED_MODEL" ]]; then
  echo "MSP_PLAYGROUND_MODEL must be exactly $REQUIRED_MODEL for the Git pressure suite; got $MSP_PLAYGROUND_MODEL" >&2
  exit 2
fi
if [[ ! -f "$PROMPTS_FILE" ]]; then
  echo "Git pressure prompts file not found: $PROMPTS_FILE" >&2
  exit 2
fi

acquire_ui_e2e_lock

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

mkdir -p "$OUT_DIR"

if [[ "${MSP_PLAYGROUND_GIT_PRESSURE_SKIP_PROVIDER_SMOKE:-0}" != "1" ]]; then
  MSP_PLAYGROUND_PROVIDER_CHECK_OUT_DIR="$OUT_DIR/provider-smoke" \
    "$SCRIPT_DIR/check-openai-responses-provider.sh"
fi

MSP_PLAYGROUND_E2E_OUT_DIR="$OUT_DIR/e2e" \
MSP_PLAYGROUND_E2E_BUILD_DIR="${MSP_PLAYGROUND_E2E_BUILD_DIR:-$BUILD_ROOT/e2e/build}" \
MSP_PLAYGROUND_E2E_DERIVED_DATA_PATH="${MSP_PLAYGROUND_E2E_DERIVED_DATA_PATH:-$BUILD_ROOT/e2e/DerivedData}" \
MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON="$PROMPT_SEQUENCE_JSON" \
MSP_PLAYGROUND_E2E_EXPECT_FINAL_ANSWERS="$EXPECTED_FINAL_ANSWERS" \
MSP_PLAYGROUND_E2E_EXPECT_TOOL=1 \
MSP_PLAYGROUND_E2E_RESET_APP="${MSP_PLAYGROUND_E2E_RESET_APP:-1}" \
MSP_PLAYGROUND_E2E_ENABLE_GIT=1 \
MSP_PLAYGROUND_E2E_ENABLE_PYTHON=0 \
MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS="${MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS:-600}" \
  "$SCRIPT_DIR/run-real-model-e2e.sh"

cp "$OUT_DIR/e2e/events.jsonl" "$OUT_DIR/events.jsonl"

verifier_args=(
  "$OUT_DIR/events.jsonl"
  --expected-final-answers "$EXPECTED_FINAL_ANSWERS"
  --report "$OUT_DIR/git-pressure-report.json"
  --required-model "$REQUIRED_MODEL"
  --model "$MSP_PLAYGROUND_MODEL"
  --prompt-file "$PROMPTS_FILE"
)
if [[ "${MSP_PLAYGROUND_GIT_PRESSURE_SKIP_PROVIDER_SMOKE:-0}" != "1" ]]; then
  verifier_args+=(--require-provider-smoke)
fi
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

"$SCRIPT_DIR/verify-real-model-pressure-log.py" "${verifier_args[@]}"

echo "MSPPlaygroundApp real-model Git pressure passed"
echo "root=$ROOT_DIR"
echo "out_dir=$OUT_DIR"
echo "event_log=$OUT_DIR/events.jsonl"
echo "report=$OUT_DIR/git-pressure-report.json"
