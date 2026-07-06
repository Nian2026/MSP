#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin"

SUBSYSTEM="com.modelshellproxy.photosorter"
DEVICE_NAME="iPhone Air"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOTO_SORTER_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_ROOT="${PHOTOSORTER_LOG_OUTPUT_ROOT:-${PHOTO_SORTER_ROOT}/artifacts/photosorter-live-device-logs}"

usage() {
  cat <<'EOF'
usage: photosorter-collect-device-logs [last]

Collect PhotoSorter Apple Unified Logging from the paired iPhone Air.

Arguments:
  last    Time window like 30m, 2h, or 1d. Defaults to 30m.

Output:
  artifacts/photosorter-live-device-logs/photosorter-device-<timestamp>.logarchive
  artifacts/photosorter-live-device-logs/photosorter-device-<timestamp>.ndjson
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi

LAST="${1:-30m}"
if [[ ! "${LAST}" =~ ^[1-9][0-9]{0,3}[mhd]$ ]]; then
  printf 'photosorter-collect-device-logs: invalid time window: %s\n' "${LAST}" >&2
  printf 'Use a value like 30m, 2h, or 1d.\n' >&2
  exit 64
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${OUTPUT_ROOT}/photosorter-device-${STAMP}.logarchive"
NDJSON="${OUTPUT_ROOT}/photosorter-device-${STAMP}.ndjson"
PREDICATE="subsystem == \"${SUBSYSTEM}\""

mkdir -p "${OUTPUT_ROOT}"

/usr/bin/log collect \
  --device-name "${DEVICE_NAME}" \
  --last "${LAST}" \
  --output "${ARCHIVE}" 2>"${OUTPUT_ROOT}/photosorter-device-${STAMP}.collect.stderr" || {
    status=$?
    cat "${OUTPUT_ROOT}/photosorter-device-${STAMP}.collect.stderr" >&2 || true
    if grep -q "Device not configured" "${OUTPUT_ROOT}/photosorter-device-${STAMP}.collect.stderr" 2>/dev/null; then
      cat >&2 <<'EOF'

photosorter-collect-device-logs: Apple log collect could not read this device.
If the iPhone is connected over localNetwork/Wi-Fi, connect it by USB, trust the Mac,
then run this command again. CoreDevice may still list the phone over Wi-Fi, but
/usr/bin/log collect --device requires an attached/configured device connection.
EOF
    fi
    exit "${status}"
  }

/usr/bin/log show \
  --style ndjson \
  --info \
  --debug \
  --signpost \
  --predicate "${PREDICATE}" \
  "${ARCHIVE}" > "${NDJSON}"

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_GROUP="$(id -gn "${TARGET_USER}" 2>/dev/null || printf 'staff')"
chown -R "${TARGET_USER}:${TARGET_GROUP}" "${ARCHIVE}" "${NDJSON}" "${OUTPUT_ROOT}" 2>/dev/null || true

printf 'logarchive: %s\n' "${ARCHIVE}"
printf 'ndjson: %s\n' "${NDJSON}"
