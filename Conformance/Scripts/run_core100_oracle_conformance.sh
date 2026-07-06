#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

CORE100_ORACLE_TMPDIR_ALIAS=""

cleanup() {
  if [[ -n "${CORE100_ORACLE_TMPDIR_ALIAS:-}" ]]; then
    rm -f "$CORE100_ORACLE_TMPDIR_ALIAS"
  fi
}
trap cleanup EXIT

CORE100_ORACLE_TMPDIR="${MSP_CONFORMANCE_TMPDIR:-$PWD/.build/msp-conformance/core100-oracle/tmp}"
mkdir -p "$CORE100_ORACLE_TMPDIR"
if [[ "$CORE100_ORACLE_TMPDIR" =~ [[:space:]] ]]; then
  CORE100_ORACLE_TMPDIR_ALIAS="/tmp/msp-core100-oracle-tmp-$(date +%Y%m%d%H%M%S)-$$"
  rm -f "$CORE100_ORACLE_TMPDIR_ALIAS"
  ln -s "$CORE100_ORACLE_TMPDIR" "$CORE100_ORACLE_TMPDIR_ALIAS"
  export MSP_CONFORMANCE_TMPDIR="$CORE100_ORACLE_TMPDIR_ALIAS"
else
  export MSP_CONFORMANCE_TMPDIR="$CORE100_ORACLE_TMPDIR"
fi
export TMPDIR="${MSP_CONFORMANCE_TMPDIR%/}/"

export MSP_RUN_CORE100_ORACLE="${MSP_RUN_CORE100_ORACLE:-1}"
CORE100_ORACLE_SCRATCH_ROOT="${MSP_CORE100_ORACLE_SCRATCH_ROOT:-$PWD/.build/msp-conformance/core100-oracle/scratch}"
mkdir -p "$CORE100_ORACLE_SCRATCH_ROOT"

printf 'command: swift test --scratch-path %q --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner\n\n' "$CORE100_ORACLE_SCRATCH_ROOT"
swift test \
  --scratch-path "$CORE100_ORACLE_SCRATCH_ROOT" \
  --filter ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner
