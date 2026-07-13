#!/bin/sh
set -eu

log() {
  echo "[backrest-unlock] $*" >&2
}

repo_id="${1:-}"
config_file="${BACKREST_CONFIG:-/config/config.json}"

if [ -z "${repo_id}" ]; then
  log "usage: $0 <repo-id>"
  exit 0
fi

if [ ! -f "${config_file}" ]; then
  log "config file not found: ${config_file}"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  log "jq not available in container; skipping stale lock cleanup"
  exit 0
fi

repo_json="$(jq -cer --arg rid "${repo_id}" '.repos[] | select(.id == $rid)' "${config_file}" 2>/dev/null || true)"
if [ -z "${repo_json}" ]; then
  log "repo '${repo_id}' not found in ${config_file}; skipping"
  exit 0
fi

repo_uri="$(printf '%s' "${repo_json}" | jq -r '.uri // empty')"
repo_password="$(printf '%s' "${repo_json}" | jq -r '.password // empty')"

if [ -z "${repo_uri}" ] || [ -z "${repo_password}" ]; then
  log "repo '${repo_id}' missing uri/password; skipping"
  exit 0
fi

# Export repo-specific env vars (e.g. AWS credentials)
for kv in $(printf '%s' "${repo_json}" | jq -r '.env[]? // empty'); do
  case "${kv}" in
    *=*) export "${kv}" ;;
  esac
done

export RESTIC_PASSWORD="${repo_password}"

if ! command -v restic >/dev/null 2>&1; then
  log "restic binary not found; skipping"
  exit 0
fi

# Removing stale locks requires reading each lock's content, which can hang
# for the full RESTIC_RETRY_LOCK duration (45m) if a lock object is corrupt
# and can't be read back from the backend. Bound it so this hook can't stall
# the snapshot, and fall back to a forced removal (which only deletes lock
# keys, never reads them) if the bounded attempt fails.
if unlock_output="$(timeout 30 restic -r "${repo_uri}" --retry-lock=10s unlock 2>&1)"; then
  log "stale lock cleanup checked for repo '${repo_id}'"
else
  log "unlock for repo '${repo_id}' failed or timed out, forcing removal: ${unlock_output}"
  if remove_all_output="$(timeout 30 restic -r "${repo_uri}" unlock --remove-all 2>&1)"; then
    log "forced lock removal succeeded for repo '${repo_id}': ${remove_all_output}"
  else
    log "forced lock removal also failed for repo '${repo_id}' (continuing): ${remove_all_output}"
  fi
fi

exit 0
