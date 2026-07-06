#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

cd "$(dirname "$0")/../.."

export MSP_RUN_DEBIAN12_ORACLE="${MSP_RUN_DEBIAN12_ORACLE:-1}"
export MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON="${MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON:-1}"

if [[ -z "${MSP_DEBIAN12_ORACLE_COMMANDS+x}" ]]; then
  export MSP_DEBIAN12_ORACLE_COMMANDS="python3"
fi

if [[ -z "${MSP_DEBIAN12_ORACLE_EXCLUDE_COMMANDS+x}" ]]; then
  export MSP_DEBIAN12_ORACLE_EXCLUDE_COMMANDS="node"
fi

if [[ -z "${MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE:-}" ]]; then
  python_executable="$(command -v python3 || true)"
  if [[ -z "$python_executable" ]]; then
    echo "python3 executable not found; set MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE" >&2
    exit 127
  fi
  export MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE="$python_executable"
fi

swift test \
  --filter ModelShellProxyDebian12OracleConformanceTests/testMSPV1Debian12OracleNoninteractiveConformanceRunner
