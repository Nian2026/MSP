#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

cd "$(dirname "$0")/../.."

DEBIAN12_ORACLE_TMPDIR_ALIAS=""

cleanup() {
  if [[ -n "${DEBIAN12_ORACLE_TMPDIR_ALIAS:-}" ]]; then
    rm -f "$DEBIAN12_ORACLE_TMPDIR_ALIAS"
  fi
}
trap cleanup EXIT

DEBIAN12_ORACLE_TMPDIR="${MSP_CONFORMANCE_TMPDIR:-$PWD/.build/msp-conformance/debian12-oracle/tmp}"
mkdir -p "$DEBIAN12_ORACLE_TMPDIR"
if [[ "$DEBIAN12_ORACLE_TMPDIR" =~ [[:space:]] ]]; then
  DEBIAN12_ORACLE_TMPDIR_ALIAS="/tmp/msp-debian12-oracle-tmp-$(date +%Y%m%d%H%M%S)-$$"
  rm -f "$DEBIAN12_ORACLE_TMPDIR_ALIAS"
  ln -s "$DEBIAN12_ORACLE_TMPDIR" "$DEBIAN12_ORACLE_TMPDIR_ALIAS"
  export MSP_CONFORMANCE_TMPDIR="$DEBIAN12_ORACLE_TMPDIR_ALIAS"
else
  export MSP_CONFORMANCE_TMPDIR="$DEBIAN12_ORACLE_TMPDIR"
fi
export TMPDIR="${MSP_CONFORMANCE_TMPDIR%/}/"

export MSP_RUN_DEBIAN12_ORACLE="${MSP_RUN_DEBIAN12_ORACLE:-1}"
export MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON="${MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON:-1}"

if [[ -z "${MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE:-}" ]]; then
  python_executable="$(command -v python3 || true)"
  if [[ -z "$python_executable" ]]; then
    echo "python3 executable not found; set MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE" >&2
    exit 127
  fi
  export MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE="$python_executable"
fi

if [[ -z "${MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE:-}" ]]; then
  node_executable="$(command -v node || true)"
  if [[ -z "$node_executable" ]]; then
    echo "node executable not found; set MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE" >&2
    exit 127
  fi
  export MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE="$node_executable"
fi

DEBIAN12_ORACLE_SCRATCH_ROOT="${MSP_DEBIAN12_ORACLE_SCRATCH_ROOT:-$PWD/.build/msp-conformance/debian12-oracle/scratch}"
mkdir -p "$DEBIAN12_ORACLE_SCRATCH_ROOT"

printf 'command: swift test --scratch-path %q --filter ModelShellProxyDebian12OracleConformanceTests/testMSPV1Debian12OracleNoninteractiveConformanceRunner\n\n' "$DEBIAN12_ORACLE_SCRATCH_ROOT"
swift test \
  --scratch-path "$DEBIAN12_ORACLE_SCRATCH_ROOT" \
  --filter ModelShellProxyDebian12OracleConformanceTests/testMSPV1Debian12OracleNoninteractiveConformanceRunner
