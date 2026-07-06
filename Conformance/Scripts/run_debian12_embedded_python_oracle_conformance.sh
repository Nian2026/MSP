#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

cd "$(dirname "$0")/../.."

export MSP_RUN_DEBIAN12_ORACLE="${MSP_RUN_DEBIAN12_ORACLE:-1}"
export MSP_DEBIAN12_ORACLE_PYTHON_BACKEND="${MSP_DEBIAN12_ORACLE_PYTHON_BACKEND:-embedded-cpython}"

if [[ -z "${MSP_DEBIAN12_ORACLE_COMMANDS+x}" ]]; then
  export MSP_DEBIAN12_ORACLE_COMMANDS="python3"
fi

if [[ -z "${MSP_DEBIAN12_ORACLE_EXCLUDE_COMMANDS+x}" ]]; then
  export MSP_DEBIAN12_ORACLE_EXCLUDE_COMMANDS="node"
fi

if [[ -z "${MSP_CPYTHON_LIBRARY_PATH:-}" ]]; then
  echo "MSP_CPYTHON_LIBRARY_PATH is required for embedded CPython oracle runs." >&2
  echo "MSP_CPYTHON_HOME is optional, but usually required by framework-based CPython builds." >&2
  exit 64
fi

swift test \
  --filter ModelShellProxyDebian12OracleConformanceTests/testMSPV1Debian12OracleNoninteractiveConformanceRunner
