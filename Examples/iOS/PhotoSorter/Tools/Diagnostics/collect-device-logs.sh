#!/usr/bin/env bash
set -euo pipefail

SUBSYSTEM="${PHOTOSORTER_LOG_SUBSYSTEM:-com.modelshellproxy.photosorter}"
LAST="${PHOTOSORTER_LOG_LAST:-30m}"
OUT_DIR="${1:-artifacts/photosorter-diagnostics}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${OUT_DIR}/photosorter-device-${STAMP}.logarchive"
NDJSON="${OUT_DIR}/photosorter-device-${STAMP}.ndjson"
PREDICATE="subsystem == \"${SUBSYSTEM}\""

mkdir -p "${OUT_DIR}"

/usr/bin/log collect \
  --device \
  --last "${LAST}" \
  --predicate "${PREDICATE}" \
  --output "${ARCHIVE}"

/usr/bin/log show \
  --style ndjson \
  --info \
  --debug \
  --signpost \
  --predicate "${PREDICATE}" \
  "${ARCHIVE}" > "${NDJSON}"

printf 'logarchive: %s\n' "${ARCHIVE}"
printf 'ndjson: %s\n' "${NDJSON}"
