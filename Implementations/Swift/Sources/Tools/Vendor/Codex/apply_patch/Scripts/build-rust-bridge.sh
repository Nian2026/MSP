#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY_PATCH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_MANIFEST="${APPLY_PATCH_DIR}/Source/msp-codex-apply-patch-bridge/Cargo.toml"
CODEX_RS_SOURCE="${APPLY_PATCH_DIR}/Source/codex-rs"
TARGET_DIR="${MSP_CODEX_APPLY_PATCH_TARGET_DIR:-${APPLY_PATCH_DIR}/.build/target}"
PROFILE="${MSP_CODEX_APPLY_PATCH_PROFILE:-release}"
TARGET="${MSP_CODEX_APPLY_PATCH_TARGET:-}"
IOS_DEPLOYMENT_TARGET="${MSP_CODEX_APPLY_PATCH_IOS_DEPLOYMENT_TARGET:-15.0}"

remap_flags=(
  "--remap-path-prefix=${APPLY_PATCH_DIR}=msp-vendor/codex/apply_patch"
  "--remap-path-prefix=${HOME}/.cargo/registry/src=cargo-registry"
  "--remap-path-prefix=${HOME}/.cargo/git/checkouts=cargo-git"
)
encoded_rustflags="${CARGO_ENCODED_RUSTFLAGS:-}"
for flag in "${remap_flags[@]}"; do
  if [[ -n "${encoded_rustflags}" ]]; then
    encoded_rustflags+=$'\x1f'
  fi
  encoded_rustflags+="${flag}"
done
export CARGO_ENCODED_RUSTFLAGS="${encoded_rustflags}"

if [[ ! -f "${CODEX_RS_SOURCE}/apply-patch/src/lib.rs" ]]; then
  echo "Codex source is not synced. Run Scripts/sync-codex-source.sh or set MSP_CODEX_RS_SOURCE." >&2
  exit 1
fi

MSP_CODEX_RS_SOURCE="${CODEX_RS_SOURCE}" "${SCRIPT_DIR}/verify-codex-source.sh"

args=(build --manifest-path "${BRIDGE_MANIFEST}" --locked)
if [[ "${PROFILE}" == "release" ]]; then
  args+=(--release)
fi
if [[ -n "${TARGET}" ]]; then
  args+=(--target "${TARGET}")
fi

if [[ "${TARGET}" == *"apple-ios"* ]]; then
  export IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
fi

CARGO_TARGET_DIR="${TARGET_DIR}" cargo "${args[@]}"

echo "Built MSP Codex apply_patch bridge in ${TARGET_DIR}"
