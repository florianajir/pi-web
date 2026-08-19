#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"

CONFIG_DIR="${BACKREST_CONFIG_DIR:-$PROJECT_DIR/config/backrest}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TEMPLATE_FILE="${BACKREST_TEMPLATE:-$PROJECT_DIR/config/backrest/config.json.template}"
ENV_FILE="${BACKREST_ENV_FILE:-$PROJECT_DIR/.env}"

# For manual runs (e.g. `sh scripts/backrest-pre-start.sh`), fall back to .env for
# any value the environment does not already provide — key by key via
# get_env_value, never by dot-sourcing: .env is not shell, so an unquoted `;` or
# `#` in a value (PIHOLE_DNS_UPSTREAMS has both) executes as a command under `.`.
# systemd's EnvironmentFile parses it without a shell, which hid this on boot.
env_value() {
  local var="$1" val
  eval "val=\"\${$var:-}\""
  [ -n "$val" ] || val="$(get_env_value "$var")"
  printf '%s' "$val"
}

# Shared S3 credentials (fall back to legacy BACKREST_S3_* for backward compat)
S3_ENDPOINT="$(env_value S3_ENDPOINT)"
S3_BUCKET="$(env_value S3_BUCKET)"
S3_ACCESS_KEY_ID="$(env_value S3_ACCESS_KEY_ID)"
[ -n "$S3_ACCESS_KEY_ID" ] || S3_ACCESS_KEY_ID="$(env_value BACKREST_S3_ACCESS_KEY_ID)"
S3_SECRET_ACCESS_KEY="$(env_value S3_SECRET_ACCESS_KEY)"
[ -n "$S3_SECRET_ACCESS_KEY" ] || S3_SECRET_ACCESS_KEY="$(env_value BACKREST_S3_SECRET_ACCESS_KEY)"
S3_REGION="$(env_value S3_REGION)"
[ -n "$S3_REGION" ] || S3_REGION="$(env_value BACKREST_S3_REGION)"
[ -n "$S3_REGION" ] || S3_REGION="fr-par"

# Backrest-specific (derive URI from shared S3 vars if not set explicitly)
BACKREST_S3_URI="$(env_value BACKREST_S3_URI)"
if [ -z "${BACKREST_S3_URI}" ] && [ -n "${S3_ENDPOINT}" ] && [ -n "${S3_BUCKET}" ]; then
  BACKREST_S3_URI="s3:${S3_ENDPOINT}/${S3_BUCKET}/restic"
fi
BACKREST_S3_REPO_PASSWORD="$(env_value BACKREST_S3_REPO_PASSWORD)"
BACKREST_INSTANCE="$(env_value BACKREST_INSTANCE)"
[ -n "$BACKREST_INSTANCE" ] || BACKREST_INSTANCE="$(env_value HOST_NAME)"
[ -n "$BACKREST_INSTANCE" ] || BACKREST_INSTANCE="$(hostname 2>/dev/null || echo pi-pcloud)"

if [ ! -f "${TEMPLATE_FILE}" ]; then
  die "template not found at ${TEMPLATE_FILE}"
fi

if [ -f "${CONFIG_FILE}" ]; then
  if [ -s "${CONFIG_FILE}" ]; then
    if jq -e 'has("instance") and (.instance | type == "string") and (.instance | length > 0)' "${CONFIG_FILE}" >/dev/null 2>&1; then
      log "config already exists at ${CONFIG_FILE}; skipping initialization"
      fix_ownership "${CONFIG_DIR}"
      exit 0
    fi

    tmp_patch="$(mktemp)"
    trap 'rm -f "${tmp_file:-}" "${tmp_patch:-}"' EXIT INT TERM
    if ! jq --arg instance "${BACKREST_INSTANCE}" '.instance = $instance' "${CONFIG_FILE}" > "${tmp_patch}"; then
      die "failed to patch missing instance in existing config"
    fi
    mv "${tmp_patch}" "${CONFIG_FILE}"
    fix_ownership "${CONFIG_DIR}"
    log "patched existing config with instance=${BACKREST_INSTANCE}"
    exit 0
  fi
fi

mkdir -p "${CONFIG_DIR}"

if [ -z "${BACKREST_S3_URI}" ] || [ -z "${BACKREST_S3_REPO_PASSWORD}" ] || \
   [ -z "${S3_ACCESS_KEY_ID}" ] || [ -z "${S3_SECRET_ACCESS_KEY}" ]; then
  log "WARNING: S3 credentials incomplete; Backrest will start but S3 repo may not be available"
  log "Set: BACKREST_S3_URI, BACKREST_S3_REPO_PASSWORD, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY"
fi

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}" "${tmp_patch:-}"' EXIT INT TERM

# jq --arg rather than sed: the values are user-supplied secrets going into
# JSON that defines shell hook commands, so a " or \ in a password must become
# a JSON escape, never a structure change.
jq \
  --arg instance "${BACKREST_INSTANCE}" \
  --arg uri "${BACKREST_S3_URI}" \
  --arg password "${BACKREST_S3_REPO_PASSWORD}" \
  --arg access_key "${S3_ACCESS_KEY_ID}" \
  --arg secret_key "${S3_SECRET_ACCESS_KEY}" \
  --arg region "${S3_REGION}" \
  'walk(if type == "string" then
      gsub("__BACKREST_INSTANCE__"; $instance)
    | gsub("__BACKREST_S3_URI__"; $uri)
    | gsub("__BACKREST_S3_REPO_PASSWORD__"; $password)
    | gsub("__BACKREST_S3_ACCESS_KEY_ID__"; $access_key)
    | gsub("__BACKREST_S3_SECRET_ACCESS_KEY__"; $secret_key)
    | gsub("__BACKREST_S3_REGION__"; $region)
    else . end)' \
  "${TEMPLATE_FILE}" > "${tmp_file}" || die "failed to render config from template"

mv "${tmp_file}" "${CONFIG_FILE}"
fix_ownership "${CONFIG_DIR}"
log "Backrest config initialized at ${CONFIG_FILE}"
