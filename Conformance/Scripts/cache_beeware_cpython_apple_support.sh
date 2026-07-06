#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TAG="${MSP_CPYTHON_APPLE_SUPPORT_TAG:-3.13-b13}"
PLATFORMS_RAW="${MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS:-iOS,macOS}"
IOS_CACHE_DIR="${MSP_CPYTHON_IOS_SUPPORT_CACHE_DIR:-$ROOT_DIR/.build/msp-cpython-ios-cache}"
MACOS_CACHE_DIR="${MSP_CPYTHON_MACOS_SUPPORT_CACHE_DIR:-$ROOT_DIR/.build/msp-cpython-macos-cache}"

usage() {
  cat <<USAGE
Usage:
  MSP_CPYTHON_APPLE_SUPPORT_TAG=3.13-b13 \\
  MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=iOS,macOS \\
    $0

Downloads BeeWare Python-Apple-support release assets into MSP-local caches and
prints shell assignments for the cached CPython paths.

Environment:
  MSP_CPYTHON_APPLE_SUPPORT_TAG       release tag, default 3.13-b13; use "latest" to resolve GitHub latest
  MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS comma/space list: iOS,macOS; default both
  MSP_CPYTHON_IOS_SUPPORT_CACHE_DIR   default .build/msp-cpython-ios-cache
  MSP_CPYTHON_MACOS_SUPPORT_CACHE_DIR default .build/msp-cpython-macos-cache
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 2
  fi
}

release_asset_for_platform() {
  local platform="$1"
  python3 - "$TAG" "$platform" <<'PY'
import json
import re
import sys
import urllib.request

tag, platform = sys.argv[1:3]
base = "https://api.github.com/repos/beeware/Python-Apple-support/releases"
url = base + ("/latest" if tag == "latest" else "/tags/" + tag)
with urllib.request.urlopen(url, timeout=30) as response:
    release = json.load(response)

pattern = re.compile(rf"^Python-[0-9][^-]*-{re.escape(platform)}-support\..*\.tar\.gz$")
matches = [
    asset
    for asset in release.get("assets", [])
    if pattern.match(asset.get("name", ""))
]
if len(matches) != 1:
    names = ", ".join(asset.get("name", "") for asset in release.get("assets", []))
    raise SystemExit(f"expected exactly one {platform} CPython asset in {release.get('tag_name')}; assets: {names}")

asset = matches[0]
print(release.get("tag_name") or tag)
print(asset["name"])
print(asset["browser_download_url"])
PY
}

cache_dir_for_platform() {
  case "$1" in
    iOS) printf '%s\n' "$IOS_CACHE_DIR" ;;
    macOS) printf '%s\n' "$MACOS_CACHE_DIR" ;;
    *)
      echo "unsupported platform: $1" >&2
      exit 2
      ;;
  esac
}

cache_platform_asset() {
  local platform="$1"
  local cache_dir
  cache_dir="$(cache_dir_for_platform "$platform")"
  mkdir -p "$cache_dir"

  local asset_info release_tag asset_name asset_url
  asset_info="$(release_asset_for_platform "$platform")"
  release_tag="$(printf '%s\n' "$asset_info" | sed -n '1p')"
  asset_name="$(printf '%s\n' "$asset_info" | sed -n '2p')"
  asset_url="$(printf '%s\n' "$asset_info" | sed -n '3p')"

  local target_name="${asset_name%.tar.gz}"
  local target_dir="$cache_dir/$target_name"
  local archive="$cache_dir/$asset_name"

  if [[ ! -d "$target_dir/Python.xcframework" ]]; then
    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/msp-cpython-apple-support.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' RETURN
    echo "downloading BeeWare CPython $platform support $release_tag: $asset_name" >&2
    curl --location --fail --silent --show-error "$asset_url" --output "$archive"
    tar -xzf "$archive" -C "$tmp_dir"
    if [[ ! -d "$tmp_dir/Python.xcframework" ]]; then
      echo "downloaded asset did not contain Python.xcframework: $asset_name" >&2
      exit 2
    fi
    rm -rf "$target_dir.tmp" "$target_dir"
    mkdir -p "$target_dir.tmp"
    mv "$tmp_dir/Python.xcframework" "$target_dir.tmp/Python.xcframework"
    mv "$target_dir.tmp" "$target_dir"
    rm -rf "$tmp_dir"
    trap - RETURN
  fi

  local xcframework="$target_dir/Python.xcframework"
  case "$platform" in
    iOS)
      printf 'MSP_PLAYGROUND_PYTHON_XCFRAMEWORK_PATH=%q\n' "$xcframework"
      ;;
    macOS)
      local framework library home
      framework="$(python3 - "$xcframework" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
matches = sorted(path for path in root.rglob("Python.framework") if path.is_dir())
print(matches[0] if matches else "")
PY
)"
      library="$(python3 - "$framework" <<'PY'
from pathlib import Path
import sys

framework = Path(sys.argv[1])
candidate = framework / "Python"
print(candidate if candidate.is_file() else "")
PY
)"
      home="$(python3 - "$framework" <<'PY'
from pathlib import Path
import sys

framework = Path(sys.argv[1])
matches = sorted(path for path in framework.glob("Versions/*/lib/python*") if path.is_dir())
print(matches[0] if matches else "")
PY
)"
      if [[ -z "$library" || -z "$home" ]]; then
        echo "cached macOS CPython asset is missing library or stdlib: $xcframework" >&2
        exit 2
      fi
      home="$(cd "$home/../.." && pwd)"
      printf 'MSP_CPYTHON_LIBRARY_PATH=%q\n' "$library"
      printf 'MSP_CPYTHON_HOME=%q\n' "$home"
      ;;
  esac
}

need_tool curl
need_tool tar
need_tool python3

IFS=$' ,\n\t' read -r -a platforms <<<"$PLATFORMS_RAW"
if (( ${#platforms[@]} == 0 )); then
  echo "MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS did not contain any platform" >&2
  exit 2
fi

for platform in "${platforms[@]}"; do
  [[ -z "$platform" ]] && continue
  cache_platform_asset "$platform"
done
