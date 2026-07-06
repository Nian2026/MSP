#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY_PATCH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CODEX_RS_SOURCE="${MSP_CODEX_RS_SOURCE:-${APPLY_PATCH_DIR}/Source/codex-rs}"

required_files=(
  "core/src/tools/handlers/apply_patch_spec.rs"
  "core/src/tools/handlers/apply_patch.lark"
  "tools/src/tool_spec.rs"
  "tools/src/responses_api.rs"
  "apply-patch/src/lib.rs"
  "apply-patch/src/parser.rs"
  "apply-patch/src/seek_sequence.rs"
  "apply-patch/src/standalone_executable.rs"
  "apply-patch/src/streaming_parser.rs"
  "apply-patch/src/invocation.rs"
  "utils/absolute-path/src/lib.rs"
  "utils/absolute-path/src/absolutize.rs"
  "core/src/tools/runtimes/apply_patch.rs"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "${CODEX_RS_SOURCE}/${file}" ]]; then
    echo "Missing Codex source file: ${CODEX_RS_SOURCE}/${file}" >&2
    exit 1
  fi
done

grep -F 'name: "apply_patch".to_string()' \
  "${CODEX_RS_SOURCE}/core/src/tools/handlers/apply_patch_spec.rs" >/dev/null
grep -F 'Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.' \
  "${CODEX_RS_SOURCE}/core/src/tools/handlers/apply_patch_spec.rs" >/dev/null
grep -F 'start: begin_patch hunk+ end_patch' \
  "${CODEX_RS_SOURCE}/core/src/tools/handlers/apply_patch.lark" >/dev/null
grep -F '#[serde(rename = "custom")]' \
  "${CODEX_RS_SOURCE}/tools/src/tool_spec.rs" >/dev/null
grep -F 'codex_apply_patch::apply_patch' \
  "${CODEX_RS_SOURCE}/core/src/tools/runtimes/apply_patch.rs" >/dev/null

echo "Codex apply_patch source verification passed: ${CODEX_RS_SOURCE}"
