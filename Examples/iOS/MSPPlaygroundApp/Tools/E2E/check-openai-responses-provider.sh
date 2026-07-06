#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${MSP_PLAYGROUND_PROVIDER_CHECK_OUT_DIR:-/tmp/msp-playground-provider-check}"
TIMEOUT_SECONDS="${MSP_PLAYGROUND_PROVIDER_CHECK_TIMEOUT_SECONDS:-45}"
NONCE="${MSP_PLAYGROUND_PROVIDER_CHECK_NONCE:-$(python3 - <<'PY'
import secrets

print(secrets.token_hex(8))
PY
)}"
EXPECTED_OUTPUT="${MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT:-MSP_PROVIDER_OK_${NONCE}}"
PROMPT="${MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT:-Return exactly and only this string, with no quotes or markdown: $EXPECTED_OUTPUT}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env: $name" >&2
    exit 2
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

responses_endpoint_for_base_url() {
  local base
  base="$(trim_trailing_slash "$1")"
  if [[ "$base" == */responses ]]; then
    printf '%s\n' "$base"
  else
    printf '%s/responses\n' "$base"
  fi
}

require_env MSP_PLAYGROUND_MODEL_BASE_URL
require_env MSP_PLAYGROUND_MODEL_API_KEY
require_env MSP_PLAYGROUND_MODEL

mkdir -p "$OUT_DIR"

ENDPOINT="$(responses_endpoint_for_base_url "$MSP_PLAYGROUND_MODEL_BASE_URL")"
REQUEST_JSON="$OUT_DIR/provider-smoke-request.redacted.json"
RESPONSE_JSON="$OUT_DIR/provider-smoke-response.json"
RESPONSE_HEADERS="$OUT_DIR/provider-smoke-response.headers"
PROMPT_JSON="$(printf '%s' "$PROMPT" | json_escape)"
MODEL_JSON="$(printf '%s' "$MSP_PLAYGROUND_MODEL" | json_escape)"

cat >"$REQUEST_JSON" <<JSON
{
  "model": $MODEL_JSON,
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": $PROMPT_JSON
        }
      ]
    }
  ],
  "store": false,
  "stream": false
}
JSON

HTTP_STATUS="$(
  curl \
    --silent \
    --show-error \
    --connect-timeout "$TIMEOUT_SECONDS" \
    --max-time "$TIMEOUT_SECONDS" \
    --output "$RESPONSE_JSON" \
    --dump-header "$RESPONSE_HEADERS" \
    --write-out "%{http_code}" \
    --request POST "$ENDPOINT" \
    --header "Authorization: Bearer $MSP_PLAYGROUND_MODEL_API_KEY" \
    --header "Content-Type: application/json" \
    --data-binary "@$REQUEST_JSON"
)"

if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
  echo "provider smoke failed: HTTP $HTTP_STATUS" >&2
  echo "endpoint=$ENDPOINT" >&2
  echo "request=$REQUEST_JSON" >&2
  echo "response=$RESPONSE_JSON" >&2
  if command -v jq >/dev/null 2>&1; then
    jq 'if type == "object" then .error // . else . end' "$RESPONSE_JSON" >&2 || true
  else
    sed -n '1,80p' "$RESPONSE_JSON" >&2 || true
  fi
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  if jq -e 'type == "object" and (.error? | not) and .object == "response" and (.id | type == "string" and length > 0)' "$RESPONSE_JSON" >/dev/null; then
    :
  else
    echo "provider smoke response was not a successful Responses object" >&2
    echo "response=$RESPONSE_JSON" >&2
    jq '.' "$RESPONSE_JSON" >&2 || true
    exit 1
  fi
fi

ACTUAL_OUTPUT="$(
  python3 - "$RESPONSE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    response = json.load(handle)

texts = []
output_text = response.get("output_text")
if isinstance(output_text, str) and output_text.strip():
    print(output_text.strip())
    sys.exit(0)

for item in response.get("output", []) or []:
    if not isinstance(item, dict):
        continue
    for content in item.get("content", []) or []:
        if not isinstance(content, dict):
            continue
        if content.get("type") in {"output_text", "text"} and isinstance(content.get("text"), str):
            texts.append(content["text"])

print("\n".join(texts).strip())
PY
)"

if [[ "$ACTUAL_OUTPUT" != "$EXPECTED_OUTPUT" ]]; then
  echo "provider smoke response text mismatch" >&2
  echo "expected=$EXPECTED_OUTPUT" >&2
  echo "actual=$ACTUAL_OUTPUT" >&2
  echo "response=$RESPONSE_JSON" >&2
  exit 1
fi

echo "MSPPlaygroundApp provider smoke passed"
echo "endpoint=$ENDPOINT"
echo "model=$MSP_PLAYGROUND_MODEL"
echo "nonce=$NONCE"
echo "request=$REQUEST_JSON"
echo "response=$RESPONSE_JSON"
