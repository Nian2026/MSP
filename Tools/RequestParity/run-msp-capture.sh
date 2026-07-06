#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Tools/RequestParity"
RUN_DIR="${MSP_REQUEST_PARITY_MSP_OUT_DIR:-${MSP_REQUEST_PARITY_OUT_DIR:-$ROOT_DIR/artifacts/request-parity}/msp}"
CAPTURE_DIR="$RUN_DIR/capture"
READY_FILE="$CAPTURE_DIR/server.json"
SERVER_LOG="$CAPTURE_DIR/server.log"
UPSTREAM_BASE_URL="${MSP_REQUEST_PARITY_UPSTREAM_BASE_URL:-${MSP_PLAYGROUND_MODEL_BASE_URL:-https://api.openai.com/v1}}"
MODEL="${MSP_REQUEST_PARITY_MODEL:-${MSP_PLAYGROUND_MODEL:-${OPENAI_MODEL:-}}}"
UPSTREAM_API_KEY="${MSP_REQUEST_PARITY_UPSTREAM_API_KEY:-${OPENAI_API_KEY:-${MSP_PLAYGROUND_MODEL_API_KEY:-}}}"
APP="${MSP_REQUEST_PARITY_MSP_APP:-playground}"
RUNNER="${MSP_REQUEST_PARITY_MSP_RUNNER:-swiftpm}"

if [[ -z "$MODEL" ]]; then
  echo "missing model; set MSP_REQUEST_PARITY_MODEL, MSP_PLAYGROUND_MODEL, or OPENAI_MODEL" >&2
  exit 2
fi
if [[ -z "$UPSTREAM_API_KEY" ]]; then
  echo "missing upstream auth; set MSP_REQUEST_PARITY_UPSTREAM_API_KEY, OPENAI_API_KEY, or MSP_PLAYGROUND_MODEL_API_KEY" >&2
  exit 2
fi

mkdir -p "$CAPTURE_DIR"
rm -rf "$CAPTURE_DIR/requests"
rm -f "$READY_FILE" "$SERVER_LOG"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

MSP_REQUEST_PARITY_UPSTREAM_API_KEY="$UPSTREAM_API_KEY" \
python3 "$TOOLS_DIR/capture_proxy.py" \
  --label msp \
  --out-dir "$CAPTURE_DIR" \
  --ready-file "$READY_FILE" \
  --upstream-base-url "$UPSTREAM_BASE_URL" \
  --upstream-api-key-env MSP_REQUEST_PARITY_UPSTREAM_API_KEY \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

for _ in {1..100}; do
  [[ -s "$READY_FILE" ]] && break
  sleep 0.1
done
if [[ ! -s "$READY_FILE" ]]; then
  echo "capture proxy did not become ready; log: $SERVER_LOG" >&2
  exit 1
fi

PROXY_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_url"])' "$READY_FILE")"
PROMPT_SEQUENCE_JSON="${MSP_REQUEST_PARITY_PROMPT_SEQUENCE_JSON:-$(python3 - <<'PY'
import json
prompts = [
    "请先用工作区命令执行 `pwd`，再执行 `printf 'alpha\\nbeta\\n'`，然后只用两句话说明结果。",
    "继续。请先用工作区命令执行 `ls -la | sed -n '1,5p'`，并在回答里引用上一轮看到的一行输出。",
    "再继续。请先用工作区命令执行 `printf 'turn3-a\\nturn3-b\\n'`，然后总结前三轮工具结果是否按顺序可见。",
]
print(json.dumps(prompts, ensure_ascii=False))
PY
)}"

case "$RUNNER" in
  swiftpm)
    MSP_REQUEST_PARITY_RUNNER_OUT_DIR="$RUN_DIR/e2e" \
    MSP_REQUEST_PARITY_MODEL_BASE_URL="$PROXY_URL/v1" \
    MSP_REQUEST_PARITY_API_KEY="${MSP_REQUEST_PARITY_CLIENT_API_KEY:-capture-proxy-client}" \
    MSP_REQUEST_PARITY_MODEL="$MODEL" \
    MSP_REQUEST_PARITY_PROMPT_SEQUENCE_JSON="$PROMPT_SEQUENCE_JSON" \
    swift run msp-request-parity-runner
    ;;
  ios)
    case "$APP" in
      playground)
        E2E_SCRIPT="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-real-model-e2e.sh"
        ;;
      photosorter)
        E2E_SCRIPT="$ROOT_DIR/Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-e2e.sh"
        ;;
      *)
        echo "invalid MSP_REQUEST_PARITY_MSP_APP=$APP; expected playground or photosorter" >&2
        exit 2
        ;;
    esac

    MSP_PLAYGROUND_E2E_OUT_DIR="$RUN_DIR/e2e" \
    MSP_PLAYGROUND_MODEL_BASE_URL="$PROXY_URL/v1" \
    MSP_PLAYGROUND_MODEL_API_KEY="${MSP_REQUEST_PARITY_CLIENT_API_KEY:-capture-proxy-client}" \
    MSP_PLAYGROUND_MODEL="$MODEL" \
    MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON="$PROMPT_SEQUENCE_JSON" \
    MSP_PLAYGROUND_E2E_EXPECT_FINAL_ANSWERS="${MSP_REQUEST_PARITY_EXPECT_FINAL_ANSWERS:-3}" \
    MSP_PLAYGROUND_E2E_TIMEOUT_SECONDS="${MSP_REQUEST_PARITY_MSP_TIMEOUT_SECONDS:-360}" \
    "$E2E_SCRIPT"
    ;;
  *)
    echo "invalid MSP_REQUEST_PARITY_MSP_RUNNER=$RUNNER; expected swiftpm or ios" >&2
    exit 2
    ;;
esac

echo "msp_capture_dir=$CAPTURE_DIR"
