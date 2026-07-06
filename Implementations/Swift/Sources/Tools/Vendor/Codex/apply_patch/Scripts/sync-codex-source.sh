#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY_PATCH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${APPLY_PATCH_DIR}/Source"
CODEX_REPOSITORY_PROVENANCE="${MSP_CODEX_REPOSITORY_PROVENANCE:-https://github.com/openai/codex}"
CODEX_RS_SOURCE="${MSP_CODEX_RS_SOURCE:-}"
CODEX_RS_DEST="${SOURCE_DIR}/codex-rs"
PROVENANCE_FILE="${SOURCE_DIR}/CODEX_SOURCE_PROVENANCE.txt"
PROVENANCE_SCOPE="codex-apply-patch-runtime-surface"

collect_provenance_paths() {
  (
    cd -- "${CODEX_RS_SOURCE}"
    find apply-patch utils/absolute-path \
      -type f \
      ! -path '*/target/*' \
      ! -name '.DS_Store'
    cat <<'FILES'
core/src/tools/handlers/apply_patch_spec.rs
core/src/tools/handlers/apply_patch.lark
core/src/tools/runtimes/apply_patch.rs
tools/src/responses_api.rs
tools/src/tool_spec.rs
FILES
  ) | LC_ALL=C sort -u
}

if [[ -z "${CODEX_RS_SOURCE}" ]]; then
  echo "Set MSP_CODEX_RS_SOURCE to codex-rs inside a clean upstream Codex checkout before syncing." >&2
  exit 1
fi

if [[ ! -f "${CODEX_RS_SOURCE}/core/src/tools/handlers/apply_patch_spec.rs" ]]; then
  echo "Codex source is missing apply_patch_spec.rs: ${CODEX_RS_SOURCE}" >&2
  exit 1
fi

provenance_paths=()
while IFS= read -r file; do
  provenance_paths+=("${file}")
done < <(collect_provenance_paths)

SOURCE_GIT_TOP="$(git -C "${CODEX_RS_SOURCE}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${SOURCE_GIT_TOP}" ]]; then
  echo "Codex source must be a Git checkout with a resolved upstream commit: ${CODEX_RS_SOURCE}" >&2
  exit 1
fi

CODEX_RS_SOURCE_REAL="$(cd -- "${CODEX_RS_SOURCE}" && pwd -P)"
EXPECTED_CODEX_RS_SOURCE="$(cd -- "${SOURCE_GIT_TOP}/codex-rs" 2>/dev/null && pwd -P || true)"
if [[ "${CODEX_RS_SOURCE_REAL}" != "${EXPECTED_CODEX_RS_SOURCE}" ]]; then
  echo "MSP_CODEX_RS_SOURCE must point at codex-rs inside an upstream Codex checkout: ${CODEX_RS_SOURCE}" >&2
  exit 1
fi

SOURCE_GIT_HEAD="$(git -C "${CODEX_RS_SOURCE}" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "${CODEX_RS_SOURCE}" status --short -- "${provenance_paths[@]}")"
STATUS_COUNT="$(printf '%s\n' "${SOURCE_STATUS}" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "${STATUS_COUNT}" != "0" ]]; then
  echo "Codex apply_patch provenance source files are dirty; refusing to generate publishable provenance." >&2
  printf '%s\n' "${SOURCE_STATUS}" | sed -n '1,200p' >&2
  exit 1
fi
for file in "${provenance_paths[@]}"; do
  if [[ ! -f "${CODEX_RS_SOURCE}/${file}" ]]; then
    echo "Missing Codex provenance source file: ${CODEX_RS_SOURCE}/${file}" >&2
    exit 1
  fi
done

rm -rf "${CODEX_RS_DEST}"
mkdir -p "${CODEX_RS_DEST}"
for file in "${provenance_paths[@]}"; do
  mkdir -p "${CODEX_RS_DEST}/$(dirname -- "${file}")"
  cp -p "${CODEX_RS_SOURCE}/${file}" "${CODEX_RS_DEST}/${file}"
done

{
  echo "source_repository=${CODEX_REPOSITORY_PROVENANCE}"
  echo "source_subdirectory=codex-rs"
  echo "source_git_head=${SOURCE_GIT_HEAD}"
  echo "source_scope=${PROVENANCE_SCOPE}"
  echo "source_scope_note=Source/codex-rs is intentionally limited to the source_files entries below."
  echo "source_status_scope=source_files"
  echo "source_status_count=${STATUS_COUNT}"
  echo "source_files_begin"
  for file in "${provenance_paths[@]}"; do
    blob_hash="$(git -C "${CODEX_RS_SOURCE}" hash-object -- "${file}")"
    echo "git_blob_sha1=${blob_hash} path=${file}"
  done
  echo "source_files_end"
} > "${PROVENANCE_FILE}"

echo "Synced scoped Codex apply_patch source to ${CODEX_RS_DEST}"
echo "Wrote provenance to ${PROVENANCE_FILE}"
