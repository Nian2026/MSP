#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Tools/RequestParity"
CODEX_RS="${MSP_REQUEST_PARITY_CODEX_RS:-$ROOT_DIR/Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs}"
RUN_DIR="${MSP_REQUEST_PARITY_CODEX_OUT_DIR:-${MSP_REQUEST_PARITY_OUT_DIR:-$ROOT_DIR/artifacts/request-parity}/codex}"
CAPTURE_DIR="$RUN_DIR/capture"
READY_FILE="$CAPTURE_DIR/server.json"
SERVER_LOG="$CAPTURE_DIR/server.log"
UPSTREAM_BASE_URL="${MSP_REQUEST_PARITY_UPSTREAM_BASE_URL:-${MSP_PLAYGROUND_MODEL_BASE_URL:-https://api.openai.com/v1}}"
MODEL="${MSP_REQUEST_PARITY_MODEL:-${OPENAI_MODEL:-${MSP_PLAYGROUND_MODEL:-}}}"
UPSTREAM_API_KEY="${MSP_REQUEST_PARITY_UPSTREAM_API_KEY:-${OPENAI_API_KEY:-${MSP_PLAYGROUND_MODEL_API_KEY:-}}}"

if [[ -z "$MODEL" ]]; then
  echo "missing model; set MSP_REQUEST_PARITY_MODEL or OPENAI_MODEL" >&2
  exit 2
fi
if [[ -z "$UPSTREAM_API_KEY" ]]; then
  echo "missing upstream auth; set MSP_REQUEST_PARITY_UPSTREAM_API_KEY, OPENAI_API_KEY, or MSP_PLAYGROUND_MODEL_API_KEY" >&2
  exit 2
fi
if [[ ! -f "$CODEX_RS/Cargo.toml" && -z "${MSP_REQUEST_PARITY_CODEX_BIN:-}" ]]; then
  echo "missing vendored codex-rs checkout: $CODEX_RS" >&2
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
  --label codex \
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
CODEX_HOME="$RUN_DIR/codex-home"
WORKSPACE="$RUN_DIR/workspace"
mkdir -p "$CODEX_HOME" "$WORKSPACE"

printf 'alpha file\nbeta file\n' > "$WORKSPACE/sample.txt"
export MSP_REQUEST_PARITY_CLIENT_API_KEY="${MSP_REQUEST_PARITY_CLIENT_API_KEY:-capture-proxy-client}"

python3 - "$CODEX_HOME/config.toml" "$PROXY_URL/v1" "$MODEL" <<'PY'
from pathlib import Path
import sys

config, base_url, model = sys.argv[1:]
Path(config).write_text(f'''model = "{model}"
model_provider = "capture"
approval_policy = "never"

[model_providers.capture]
name = "Request Parity Capture"
base_url = "{base_url}"
env_key = "MSP_REQUEST_PARITY_CLIENT_API_KEY"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
''', encoding='utf-8')
PY

codex_cmd() {
  if [[ -n "${MSP_REQUEST_PARITY_CODEX_BIN:-}" ]]; then
    "$MSP_REQUEST_PARITY_CODEX_BIN" "$@"
  else
    cargo run --manifest-path "$CODEX_RS/Cargo.toml" -p codex-cli -- "$@"
  fi
}

PROMPT1="${MSP_REQUEST_PARITY_CODEX_PROMPT1:-请先用工作区命令执行 \`pwd\`，再执行 \`printf 'alpha\\nbeta\\n'\`，然后只用两句话说明结果。}"
PROMPT2="${MSP_REQUEST_PARITY_CODEX_PROMPT2:-继续。请先用工作区命令执行 \`ls -la | sed -n '1,5p'\`，并在回答里引用上一轮看到的一行输出。}"
PROMPT3="${MSP_REQUEST_PARITY_CODEX_PROMPT3:-再继续。请先用工作区命令执行 \`printf 'turn3-a\\nturn3-b\\n'\`，然后总结前三轮工具结果是否按顺序可见。}"

COMMON_ARGS=(
  exec
  --json
  --skip-git-repo-check
  --ignore-rules
  --dangerously-bypass-approvals-and-sandbox
)

(
  cd "$WORKSPACE"
  CODEX_HOME="$CODEX_HOME" codex_cmd "${COMMON_ARGS[@]}" "$PROMPT1" > "$RUN_DIR/codex-turn1.jsonl" 2> "$RUN_DIR/codex-turn1.stderr.log"
  CODEX_HOME="$CODEX_HOME" codex_cmd "${COMMON_ARGS[@]}" resume --last "$PROMPT2" > "$RUN_DIR/codex-turn2.jsonl" 2> "$RUN_DIR/codex-turn2.stderr.log"
  CODEX_HOME="$CODEX_HOME" codex_cmd "${COMMON_ARGS[@]}" resume --last "$PROMPT3" > "$RUN_DIR/codex-turn3.jsonl" 2> "$RUN_DIR/codex-turn3.stderr.log"
)

echo "codex_capture_dir=$CAPTURE_DIR"
