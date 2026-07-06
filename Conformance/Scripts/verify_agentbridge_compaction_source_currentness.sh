#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

manifest="${MSP_AGENTBRIDGE_COMPACTION_CURRENTNESS_MANIFEST:-${repo_root}/Conformance/AgentBridge/CompactionSourceCurrentness/CURRENTNESS_MANIFEST.txt}"
git_cache="${MSP_CODEX_CURRENTNESS_GIT_CACHE:-${repo_root}/.build/msp-conformance/codex-currentness/openai-codex-original}"

if [[ ! -f "${manifest}" ]]; then
  echo "missing AgentBridge compaction currentness manifest: ${manifest}" >&2
  exit 1
fi

codex_paths="$(mktemp)"
storage_paths="$(mktemp)"
trap 'rm -f "${codex_paths}" "${storage_paths}"' EXIT

manifest_format=""
remote_url=""
pinned_commit=""
source_snapshot_root=""
storage_snapshot_root=""
section=""

while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
  line="${raw_line#"${raw_line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "${line}" || "${line}" == \#* ]] && continue
  case "${line}" in
    codex_paths_begin)
      section="codex"
      continue
      ;;
    codex_paths_end)
      section=""
      continue
      ;;
    storage_evidence_paths_begin)
      section="storage"
      continue
      ;;
    storage_evidence_paths_end)
      section=""
      continue
      ;;
  esac

  if [[ "${section}" == "codex" ]]; then
    echo "${line}" >>"${codex_paths}"
    continue
  fi
  if [[ "${section}" == "storage" ]]; then
    echo "${line}" >>"${storage_paths}"
    continue
  fi

  key="${line%%=*}"
  value="${line#*=}"
  if [[ "${key}" == "${line}" ]]; then
    echo "invalid manifest line outside a path section: ${line}" >&2
    exit 1
  fi
  case "${key}" in
    format)
      manifest_format="${value}"
      ;;
    remote_url)
      remote_url="${value}"
      ;;
    reviewed_upstream_commit)
      pinned_commit="${value}"
      ;;
    source_snapshot_root)
      source_snapshot_root="${value}"
      ;;
    storage_snapshot_root)
      storage_snapshot_root="${value}"
      ;;
    *)
      echo "unknown currentness manifest key: ${key}" >&2
      exit 1
      ;;
  esac
done <"${manifest}"

if [[ "${manifest_format}" != "msp-agentbridge-compaction-source-currentness-v1" ]]; then
  echo "unsupported AgentBridge compaction currentness manifest format: ${manifest_format}" >&2
  exit 1
fi
if [[ ! "${pinned_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "reviewed_upstream_commit must be a 40-character commit hash" >&2
  exit 1
fi
if [[ -z "${source_snapshot_root}" || -z "${storage_snapshot_root}" ]]; then
  echo "currentness manifest must declare source and storage snapshot roots" >&2
  exit 1
fi

remote_url="${MSP_CODEX_CURRENTNESS_REMOTE_URL:-${remote_url:-https://github.com/openai/codex.git}}"
source_root="${repo_root}/${source_snapshot_root}"
storage_root="${repo_root}/${storage_snapshot_root}"

sort -u "${codex_paths}" -o "${codex_paths}"
sort -u "${storage_paths}" -o "${storage_paths}"

codex_count="$(wc -l < "${codex_paths}" | tr -d ' ')"
storage_count="$(wc -l < "${storage_paths}" | tr -d ' ')"
if [[ "${codex_count}" -le 0 || "${storage_count}" -le 0 ]]; then
  echo "currentness manifest must contain Codex and storage evidence paths" >&2
  exit 1
fi

if [[ ! -d "${source_root}" ]]; then
  echo "missing Codex source snapshot: ${source_root}" >&2
  exit 1
fi

if [[ ! -d "${git_cache}/.git" ]]; then
  mkdir -p "$(dirname "${git_cache}")"
  git clone --filter=blob:none --no-checkout "${remote_url}" "${git_cache}" >&2
else
  git -C "${git_cache}" remote set-url origin "${remote_url}" >&2
fi

remote_head_ref="$(
  git -C "${git_cache}" ls-remote --symref origin HEAD \
    | awk '/^ref:/ { print $2; exit }'
)"
if [[ -z "${remote_head_ref}" ]]; then
  echo "could not resolve origin HEAD ref for Codex remote" >&2
  exit 1
fi

currentness_ref="refs/msp-currentness/origin-head"
git -C "${git_cache}" fetch --filter=blob:none --refmap= origin \
  "+${remote_head_ref}:${currentness_ref}" >&2

remote_head="$(
  git -C "${git_cache}" rev-parse "${currentness_ref}"
)"

if [[ -z "${remote_head}" ]]; then
  echo "could not resolve origin/HEAD for vendored Codex remote" >&2
  exit 1
fi

if ! git -C "${git_cache}" cat-file -e "${pinned_commit}^{commit}"; then
  echo "reviewed Codex currentness commit is not present locally: ${pinned_commit}" >&2
  exit 1
fi

if ! git -C "${git_cache}" cat-file -e "${remote_head}^{commit}"; then
  echo "remote HEAD commit is not present locally: ${remote_head}" >&2
  echo "fetch the vendored Codex tree before running the currentness gate" >&2
  exit 1
fi

validate_relative_path() {
  local rel_path="$1"
  if [[ -z "${rel_path}" || "${rel_path}" == /* || "${rel_path}" == ../* || "${rel_path}" == *"/../"* ]]; then
    echo "currentness manifest path is not safe relative path: ${rel_path}" >&2
    exit 1
  fi
}

missing=0
while IFS= read -r rel_path; do
  [[ -z "${rel_path}" ]] && continue
  validate_relative_path "${rel_path}"
  if [[ ! -f "${source_root}/${rel_path}" ]]; then
    echo "missing Codex source path from currentness manifest: ${rel_path}" >&2
    missing=1
  fi
done < "${codex_paths}"

while IFS= read -r rel_path; do
  [[ -z "${rel_path}" ]] && continue
  validate_relative_path "${rel_path}"
  if [[ "${rel_path}" == Conformance/Chat/CodexCliValidation/* ]]; then
    full_path="${repo_root}/${rel_path}"
  else
    full_path="${storage_root}/${rel_path}"
  fi
  if [[ ! -f "${full_path}" ]]; then
    echo "missing storage evidence path from currentness manifest: ${rel_path}" >&2
    missing=1
  fi
done < "${storage_paths}"

if [[ "${missing}" -ne 0 ]]; then
  exit 1
fi

diff_output="$(
  git -C "${git_cache}" diff --name-only \
    "${pinned_commit}" \
    "${remote_head}" \
    -- $(cat "${codex_paths}")
)"

if [[ -n "${diff_output}" ]]; then
  echo "Codex compaction source paths changed between reviewed currentness commit and origin/HEAD:" >&2
  echo "${diff_output}" >&2
  exit 1
fi

echo "OK Codex compaction currentness"
echo "pinned_commit=${pinned_commit}"
echo "origin_head=${remote_head}"
echo "codex_paths=${codex_count}"
echo "storage_evidence_paths=${storage_count}"
