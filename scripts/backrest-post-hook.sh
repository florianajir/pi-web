#!/bin/sh
set -eu

NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.${HOST_NAME:-pi.lan}}"
NTFY_TOPIC="${BACKREST_NTFY_TOPIC:-monitoring}"
BACKREST_EVENT_KIND="${1:-}"
NTFY_USER="backrest"
NTFY_PASSWORD="${NTFY_BACKREST_PASSWORD:-}"

log() {
  echo "[backrest-post-hook] $*" >&2
}

set_ntfy_metadata() {
  case "${BACKREST_EVENT_KIND}" in
    errors)
      NTFY_TITLE="${BACKREST_NTFY_ERROR_TITLE:-Backrest backup error}"
      NTFY_PRIORITY="high"
      NTFY_TAGS="${BACKREST_NTFY_ERROR_TAGS:-backup_failed}"
      ;;
    info)
      log "backup succeeded; notification disabled by default"
      exit 0
      ;;
    *)
      log "invalid event kind '${BACKREST_EVENT_KIND}'. Valid values: info, errors"
      exit 2
      ;;
  esac
}

if [ "$#" -lt 2 ]; then
  log "usage: $0 <info|errors> <summary>"
  exit 2
fi

set_ntfy_metadata

if [ -z "${NTFY_PASSWORD}" ]; then
  log "NTFY_BACKREST_PASSWORD is empty; skipping ntfy notification"
  exit 0
fi

shift
message="$*"

if [ -z "${message}" ]; then
  log "empty summary message; skipping ntfy notification"
  exit 0
fi

ntfy_url="${NTFY_BASE_URL%/}/${NTFY_TOPIC}"

# The credential goes in through a 0600 config file, not `-u user:pass`, which is
# visible in the container's process table for the length of the call. The body
# goes in on stdin because curl reads `--data-binary @foo` as a *filename*: a
# summary that happens to start with "@" would post a file, or fail.
curl_config="$(mktemp)"
trap 'rm -f "${curl_config}"' EXIT INT TERM
chmod 600 "${curl_config}"
printf 'user = "%s:%s"\n' "${NTFY_USER}" "${NTFY_PASSWORD}" > "${curl_config}"

if ! printf '%s' "${message}" | curl -fsS --retry 3 --max-time 15 \
  --config "${curl_config}" \
  -H "Title: ${NTFY_TITLE}" \
  -H "Priority: ${NTFY_PRIORITY}" \
  -H "Tags: ${NTFY_TAGS}" \
  --data-binary @- \
  "${ntfy_url}" >/dev/null; then
  log "failed to publish ntfy message to ${ntfy_url}"
fi

exit 0
