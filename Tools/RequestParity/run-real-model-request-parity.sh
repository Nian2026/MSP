#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Tools/RequestParity"
STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_ROOT="${MSP_REQUEST_PARITY_OUT_DIR:-$ROOT_DIR/artifacts/request-parity/$STAMP}"
mkdir -p "$RUN_ROOT"

if [[ -z "${MSP_REQUEST_PARITY_UPSTREAM_API_KEY:-${OPENAI_API_KEY:-}}" && -z "${MSP_PLAYGROUND_MODEL_API_KEY:-}" ]]; then
  echo "missing upstream auth; set MSP_REQUEST_PARITY_UPSTREAM_API_KEY, OPENAI_API_KEY, or MSP_PLAYGROUND_MODEL_API_KEY" >&2
  exit 2
fi

if [[ -z "${MSP_REQUEST_PARITY_MODEL:-${OPENAI_MODEL:-${MSP_PLAYGROUND_MODEL:-}}}" ]]; then
  echo "missing model; set MSP_REQUEST_PARITY_MODEL, OPENAI_MODEL, or MSP_PLAYGROUND_MODEL" >&2
  exit 2
fi

if [[ "${MSP_REQUEST_PARITY_SKIP_MSP:-0}" != "1" ]]; then
  MSP_REQUEST_PARITY_OUT_DIR="$RUN_ROOT" "$TOOLS_DIR/run-msp-capture.sh" | tee "$RUN_ROOT/msp-run.log"
fi

if [[ "${MSP_REQUEST_PARITY_SKIP_CODEX:-0}" != "1" ]]; then
  MSP_REQUEST_PARITY_OUT_DIR="$RUN_ROOT" "$TOOLS_DIR/run-codex-capture.sh" | tee "$RUN_ROOT/codex-run.log"
fi

if [[ "${MSP_REQUEST_PARITY_SKIP_MSP:-0}" != "1" && "${MSP_REQUEST_PARITY_SKIP_CODEX:-0}" != "1" ]]; then
  python3 "$TOOLS_DIR/compare_requests.py" \
    --msp-dir "$RUN_ROOT/msp/capture" \
    --codex-dir "$RUN_ROOT/codex/capture" \
    --out-dir "$RUN_ROOT/compare" \
    ${MSP_REQUEST_PARITY_FAIL_ON_DIFF:+--fail-on-diff}
fi

echo "request_parity_run=$RUN_ROOT"
