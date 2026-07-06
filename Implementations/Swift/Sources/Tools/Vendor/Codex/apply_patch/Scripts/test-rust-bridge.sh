#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY_PATCH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_MANIFEST="${APPLY_PATCH_DIR}/Source/msp-codex-apply-patch-bridge/Cargo.toml"
CODEX_RS_SOURCE="${APPLY_PATCH_DIR}/Source/codex-rs"
TARGET_DIR="${MSP_CODEX_APPLY_PATCH_TARGET_DIR:-${APPLY_PATCH_DIR}/.build/target}"

if [[ ! -f "${CODEX_RS_SOURCE}/apply-patch/src/lib.rs" ]]; then
  echo "Codex source is not synced. Run Scripts/sync-codex-source.sh or set MSP_CODEX_RS_SOURCE." >&2
  exit 1
fi

MSP_CODEX_RS_SOURCE="${CODEX_RS_SOURCE}" "${SCRIPT_DIR}/verify-codex-source.sh"

CARGO_TARGET_DIR="${TARGET_DIR}" cargo test \
  --manifest-path "${BRIDGE_MANIFEST}" \
  --locked \
  "$@"
