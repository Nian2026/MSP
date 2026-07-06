#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_BASE_IMAGE="python:3.12-slim-bookworm"
DEFAULT_IMAGE="msp-debian12-pty-oracle:python3.12-nodejs-bookworm"
BASE_IMAGE="${MSP_DEBIAN12_PTY_ORACLE_BASE_IMAGE:-$DEFAULT_BASE_IMAGE}"
IMAGE="${MSP_DEBIAN12_PTY_ORACLE_IMAGE:-$DEFAULT_IMAGE}"
REPORT="${MSP_DEBIAN12_PTY_ORACLE_REPORT:-$ROOT_DIR/.build/msp-conformance/debian12-pty-linux-report.json}"

usage() {
  cat <<'EOF'
Usage: run_debian12_pty_oracle_container.sh [runner args...]

Runs Conformance/Scripts/run_debian12_pty_oracle.py inside a Debian 12 based
Python container. This is the required PTY oracle path for Debian/Linux byte
stream parity; macOS native PTY runs are smoke tests only.

Environment:
  MSP_DEBIAN12_PTY_ORACLE_BASE_IMAGE
                                      base image used for the cached oracle image,
                                      default python:3.12-slim-bookworm
  MSP_DEBIAN12_PTY_ORACLE_IMAGE     container image, default msp-debian12-pty-oracle:python3.12-nodejs-bookworm
  MSP_DEBIAN12_PTY_ORACLE_AUTO_BUILD
                                      build msp-debian12-pty-oracle:python3.12-nodejs-bookworm
                                      when selected and missing, default 1
  MSP_DEBIAN12_PTY_ORACLE_INSTALL_NODE
                                      install Debian nodejs in the container
                                      when node is missing, default 1
  MSP_DEBIAN12_PTY_ORACLE_APT_HTTP_TIMEOUT_SECONDS
                                      apt HTTP timeout used while building/installing
                                      node, default 30
  MSP_DEBIAN12_PTY_ORACLE_APT_RETRIES
                                      apt retry count used while building/installing
                                      node, default 2
  MSP_DEBIAN12_PTY_ORACLE_PLATFORM  optional docker --platform value
  MSP_DEBIAN12_PTY_ORACLE_REPORT    report path, default .build/msp-conformance/debian12-pty-linux-report.json
  MSP_DEBIAN12_PTY_ORACLE_CASE      optional single case id
  MSP_DEBIAN12_PTY_ORACLE_CASES     optional comma-separated case ids
  MSP_DEBIAN12_PTY_ORACLE_LIMIT     optional case limit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for the Debian PTY oracle container runner" >&2
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not available; start Docker/Colima and rerun this PTY oracle gate" >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT")"

full_gate=1
if [[ -n "${MSP_DEBIAN12_PTY_ORACLE_CASE:-}" || -n "${MSP_DEBIAN12_PTY_ORACLE_CASES:-}" || -n "${MSP_DEBIAN12_PTY_ORACLE_LIMIT:-}" ]]; then
  full_gate=0
fi
for arg in "$@"; do
  case "$arg" in
    --case|--cases|--limit|--case=*|--cases=*|--limit=*)
      full_gate=0
      ;;
  esac
done

platform_args=()
if [[ -n "${MSP_DEBIAN12_PTY_ORACLE_PLATFORM:-}" ]]; then
  platform_args=(--platform "$MSP_DEBIAN12_PTY_ORACLE_PLATFORM")
fi

if [[ "${MSP_DEBIAN12_PTY_ORACLE_AUTO_BUILD:-1}" == "1" && "$IMAGE" == "$DEFAULT_IMAGE" ]]; then
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    build_context="$(mktemp -d)"
    cleanup_build_context() {
      rm -rf "$build_context"
    }
    trap cleanup_build_context EXIT
    docker_build_args=(
      build
      -t "$IMAGE"
      --build-arg "BASE_IMAGE=$BASE_IMAGE"
      --build-arg "APT_HTTP_TIMEOUT_SECONDS=${MSP_DEBIAN12_PTY_ORACLE_APT_HTTP_TIMEOUT_SECONDS:-30}"
      --build-arg "APT_RETRIES=${MSP_DEBIAN12_PTY_ORACLE_APT_RETRIES:-2}"
    )
    if (( ${#platform_args[@]} > 0 )); then
      docker_build_args+=("${platform_args[@]}")
    fi
    docker "${docker_build_args[@]}" -f - "$build_context" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
ARG APT_HTTP_TIMEOUT_SECONDS=30
ARG APT_RETRIES=2
RUN apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=${APT_HTTP_TIMEOUT_SECONDS} -o Acquire::Retries=${APT_RETRIES} update \
  && apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=${APT_HTTP_TIMEOUT_SECONDS} -o Acquire::Retries=${APT_RETRIES} install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*
EOF
  fi
fi

docker_run_args=(run --rm)
if (( ${#platform_args[@]} > 0 )); then
  docker_run_args+=("${platform_args[@]}")
fi

docker "${docker_run_args[@]}" \
  -e HOME=/tmp \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e MSP_DEBIAN12_PTY_ORACLE_INSTALL_NODE="${MSP_DEBIAN12_PTY_ORACLE_INSTALL_NODE:-1}" \
  -e MSP_DEBIAN12_PTY_ORACLE_CONTAINER_REPORT="/workspace/${REPORT#$ROOT_DIR/}" \
  -e MSP_DEBIAN12_PTY_ORACLE_APT_HTTP_TIMEOUT_SECONDS="${MSP_DEBIAN12_PTY_ORACLE_APT_HTTP_TIMEOUT_SECONDS:-30}" \
  -e MSP_DEBIAN12_PTY_ORACLE_APT_RETRIES="${MSP_DEBIAN12_PTY_ORACLE_APT_RETRIES:-2}" \
  -e MSP_DEBIAN12_PTY_ORACLE_CASE="${MSP_DEBIAN12_PTY_ORACLE_CASE:-}" \
  -e MSP_DEBIAN12_PTY_ORACLE_CASES="${MSP_DEBIAN12_PTY_ORACLE_CASES:-}" \
  -e MSP_DEBIAN12_PTY_ORACLE_LIMIT="${MSP_DEBIAN12_PTY_ORACLE_LIMIT:-}" \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  "$IMAGE" \
  bash -lc '
    set -euo pipefail
    if [[ "${MSP_DEBIAN12_PTY_ORACLE_INSTALL_NODE:-1}" == "1" ]] && ! command -v node >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt_flags=(
        -o Acquire::ForceIPv4=true
        -o Acquire::http::Timeout="${MSP_DEBIAN12_PTY_ORACLE_APT_HTTP_TIMEOUT_SECONDS:-30}"
        -o Acquire::Retries="${MSP_DEBIAN12_PTY_ORACLE_APT_RETRIES:-2}"
      )
      apt-get "${apt_flags[@]}" update
      apt-get "${apt_flags[@]}" install -y --no-install-recommends nodejs
      rm -rf /var/lib/apt/lists/*
    fi
    set +e
    "$@"
    status=$?
    set -e
    chown "${HOST_UID}:${HOST_GID}" "${MSP_DEBIAN12_PTY_ORACLE_CONTAINER_REPORT}" 2>/dev/null || true
    exit "$status"
  ' bash \
  python3 Conformance/Scripts/run_debian12_pty_oracle.py \
    --fixture Conformance/ReferenceOutputs/MSPV1Debian12Oracle/pty-cases.json \
    --report "/workspace/${REPORT#$ROOT_DIR/}" \
    --require-linux \
    "$@"

if [[ "${MSP_DEBIAN12_PTY_ORACLE_SKIP_REPORT_VERIFY:-0}" != "1" ]]; then
  verifier_args=(
    --report "$REPORT"
    --fixture "$ROOT_DIR/Conformance/ReferenceOutputs/MSPV1Debian12Oracle/pty-cases.json"
    --require-zero-failures
    --require-linux-runner
  )
  if [[ "$full_gate" == "1" ]]; then
    verifier_args+=(
      --require-all-fixture-cases
      --require-python-pty-cases
      --expected-case-count 157
      --python-coverage "$ROOT_DIR/Conformance/Fixtures/MSPV1PythonRuntimeCoverage.json"
      --summary-report "$ROOT_DIR/.build/msp-conformance/debian12-pty-linux-summary.json"
    )
  fi
  python3 "$ROOT_DIR/Conformance/Scripts/verify_debian12_pty_oracle_report.py" "${verifier_args[@]}"
fi
