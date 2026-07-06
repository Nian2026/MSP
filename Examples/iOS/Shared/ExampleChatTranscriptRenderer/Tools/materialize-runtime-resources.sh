#!/usr/bin/env bash
set -euo pipefail

source_dir="${MSP_EXAMPLE_CHAT_RENDERER_RUNTIME_RESOURCES_SOURCE:-${PROJECT_DIR:?}/../Vendor/ExampleChatTranscriptRenderer/RuntimeResources}"
destination_dir="${CODESIGNING_FOLDER_PATH:?}/RuntimeResources"

if [[ ! -d "$source_dir" ]]; then
  echo "renderer RuntimeResources source not found: $source_dir" >&2
  exit 2
fi

if [[ -z "${CODESIGNING_FOLDER_PATH:-}" || ! -d "$CODESIGNING_FOLDER_PATH" ]]; then
  echo "CODESIGNING_FOLDER_PATH does not point at an app bundle." >&2
  exit 2
fi

mkdir -p "$destination_dir"

# Xcode preserves example-local symlinks when copying folder references into an
# app bundle, but iOS installation rejects bundle symlinks that point outside
# the payload. Keep source symlinks for repo hygiene; materialize real files in
# the built app.
rsync -aL --delete "$source_dir/" "$destination_dir/"

remaining_symlink="$(find "$destination_dir" -type l -print -quit)"
if [[ -n "$remaining_symlink" ]]; then
  echo "RuntimeResources still contains a symlink after materialization: $remaining_symlink" >&2
  exit 2
fi

echo "Materialized renderer RuntimeResources into $destination_dir"
