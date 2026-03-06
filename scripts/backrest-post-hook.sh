#!/bin/sh
set -eu

NTFY_BASE_URL="https://ntfy.${HOST_NAME:-pi.lan}"
NTFY_TOPIC="backup"
NTFY_USER="backrest"
NTFY_PASSWORD="${NTFY_BACKREST_PASSWORD:-}"
NTFY_TITLE="${BACKREST_NTFY_TITLE:-Backrest backup}"
NTFY_PRIORITY="${BACKREST_NTFY_PRIORITY:-default}"

if [ -z "${NTFY_PASSWORD}" ]; then
  echo "[backrest-post-hook] NTFY_BACKREST_PASSWORD is empty; skipping ntfy notification" >&2
  exit 0
fi

host_name="$(hostname 2>/dev/null || echo pi-web)"
default_message="Backrest backup finished on ${host_name} at $(date '+%Y-%m-%d %H:%M:%S %Z')"
message="${1:-${default_message}}"

ntfy_url="${NTFY_BASE_URL%/}/${NTFY_TOPIC}"

if ! curl -fsS --retry 3 --max-time 15 \
  -u "${NTFY_USER}:${NTFY_PASSWORD}" \
  -H "Title: ${NTFY_TITLE}" \
  -H "Priority: ${NTFY_PRIORITY}" \
  -H "Tags: backup_finished" \
  -d "${message}" \
  "${ntfy_url}" >/dev/null; then
  echo "[backrest-post-hook] failed to publish ntfy message to ${ntfy_url}" >&2
fi

exit 0
