#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${APP_ROOT}/../../.." && pwd)"

missing=()

require_package() {
  local label="$1"
  local package_dir="$2"
  local manifest="${package_dir}/Package.swift"

  if [[ ! -d "$package_dir" ]]; then
    missing+=("${label}: missing directory: ${package_dir}")
    return
  fi

  if [[ ! -f "$manifest" ]]; then
    missing+=("${label}: missing Package.swift: ${manifest}")
  fi
}

require_directory() {
  local label="$1"
  local directory="$2"

  if [[ ! -d "$directory" ]]; then
    missing+=("${label}: missing directory: ${directory}")
  fi
}

require_file() {
  local label="$1"
  local file="$2"

  if [[ ! -f "$file" ]]; then
    missing+=("${label}: missing file: ${file}")
  fi
}

reject_path() {
  local label="$1"
  local path="$2"

  if [[ -e "$path" || -L "$path" ]]; then
    missing+=("${label}: obsolete local MLX path must be removed: ${path}")
  fi
}

require_package "ModelShellProxy local package" "${REPO_ROOT}/Implementations/Swift"
require_directory "example chat transcript renderer assets" "${APP_ROOT}/Vendor/ExampleChatTranscriptRenderer"
reject_path "MLX SwiftPM dependency is remote" "${APP_ROOT}/Vendor/mlx-swift"
reject_path "MLX examples SwiftPM dependency is remote" "${APP_ROOT}/Vendor/mlx-swift-examples"

if [[ "${PHOTOSORTER_ENABLE_LOCAL_FASTVLM:-}" == "1" ]]; then
  require_directory "local FastVLM copied source" "${APP_ROOT}/Local/FastVLM"
  require_file "local FastVLM copied source" "${APP_ROOT}/Local/FastVLM/FastVLM.swift"
  require_file "local FastVLM media extensions" "${APP_ROOT}/Local/FastVLM/MediaProcessingExtensions.swift"
fi

if (( ${#missing[@]} > 0 )); then
  echo "PhotoSorter package/vendor preflight failed." >&2
  echo >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo >&2
  echo "Do not move PhotoSorter package/vendor boundaries without updating:" >&2
  echo "  - ${APP_ROOT}/Package.swift" >&2
  echo "  - ${APP_ROOT}/Project/PhotoSorter.xcodeproj/project.pbxproj" >&2
  echo "  - ${APP_ROOT}/Vendor/README.md" >&2
  echo >&2
  echo "Default PhotoSorter builds do not require MLX or copied FastVLM source." >&2
  echo "Set PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1 only when the ignored local" >&2
  echo "FastVLM source exists under Local/FastVLM." >&2
  echo >&2
  echo "MLX and swift-transformers are resolved through public SwiftPM package" >&2
  echo "URLs only for that optional local FastVLM path; stale local MLX" >&2
  echo "Vendor paths remain open-source hygiene blockers." >&2
  echo >&2
  echo "When the package graph is broken, Xcode often reports cascading diagnostics like:" >&2
  echo "  Missing package product 'MSPAgentBridge'" >&2
  echo "  Missing package product 'ModelShellProxy'" >&2
  echo "  Missing package product 'MLX'" >&2
  echo "  Missing package product 'MLXVLM'" >&2
  exit 1
fi

echo "PhotoSorter package/vendor preflight passed."
