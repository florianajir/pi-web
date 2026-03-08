#!/bin/sh
set -eu

CONFIG_DIR="${BACKREST_CONFIG_DIR:-./config/backrest}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TEMPLATE_FILE="${BACKREST_TEMPLATE:-./config/backrest/config.json.template}"
ENV_FILE="${BACKREST_ENV_FILE:-./.env}"

# For manual runs (e.g. `sh scripts/backrest-pre-start.sh`), load .env if present
# and if required variables are not already exported by the current environment.
if [ -f "${ENV_FILE}" ]; then
  if [ -z "${BACKREST_S3_URI:-}" ] || [ -z "${BACKREST_S3_REPO_PASSWORD:-}" ] || \
     [ -z "${BACKREST_S3_ACCESS_KEY_ID:-}" ] || [ -z "${BACKREST_S3_SECRET_ACCESS_KEY:-}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
  fi
fi

# Defaults from .env.dist
BACKREST_S3_URI="${BACKREST_S3_URI:-}"
BACKREST_S3_REPO_PASSWORD="${BACKREST_S3_REPO_PASSWORD:-}"
BACKREST_S3_ACCESS_KEY_ID="${BACKREST_S3_ACCESS_KEY_ID:-}"
BACKREST_S3_SECRET_ACCESS_KEY="${BACKREST_S3_SECRET_ACCESS_KEY:-}"
BACKREST_S3_REGION="${BACKREST_S3_REGION:-fr-par}"
BACKREST_INSTANCE="${BACKREST_INSTANCE:-${HOST_NAME:-$(hostname 2>/dev/null || echo pi-web)}}"

# Fix ownership of a path to match the project directory owner.
# When the script runs as root (via systemd), files are created owned by root.
# Chowning to the project directory owner restores IDE/user access.
_fix_ownership() {
  _owner=$(stat -c '%u:%g' "." 2>/dev/null || echo "")
  if [ -n "$_owner" ] && [ "$_owner" != "0:0" ]; then
    chown -R "$_owner" "$1"
  fi
}

if [ ! -f "${TEMPLATE_FILE}" ]; then
  echo "[backrest-pre-start] template not found at ${TEMPLATE_FILE}" >&2
  exit 1
fi

# Idempotent: if config already exists and has content, skip
if [ -f "${CONFIG_FILE}" ]; then
  if [ -s "${CONFIG_FILE}" ]; then
    if jq -e 'has("instance") and (.instance | type == "string") and (.instance | length > 0)' "${CONFIG_FILE}" >/dev/null 2>&1; then
      echo "[backrest-pre-start] config already exists at ${CONFIG_FILE}; skipping initialization"
      _fix_ownership "${CONFIG_DIR}"
      exit 0
    fi

    tmp_patch="$(mktemp)"
    trap 'rm -f "${tmp_file:-}" "${tmp_patch:-}"' EXIT INT TERM
    if ! jq --arg instance "${BACKREST_INSTANCE}" '.instance = $instance' "${CONFIG_FILE}" > "${tmp_patch}"; then
      echo "[backrest-pre-start] ❌ failed to patch missing instance in existing config" >&2
      exit 1
    fi
    mv "${tmp_patch}" "${CONFIG_FILE}"
    _fix_ownership "${CONFIG_DIR}"
    echo "[backrest-pre-start] ✅ patched existing config with instance=${BACKREST_INSTANCE}"
    exit 0
  fi
fi

# Ensure directory exists
mkdir -p "${CONFIG_DIR}"

# Check for required S3 credentials if we're going to initialize
if [ -z "${BACKREST_S3_URI}" ] || [ -z "${BACKREST_S3_REPO_PASSWORD}" ] || \
   [ -z "${BACKREST_S3_ACCESS_KEY_ID}" ] || [ -z "${BACKREST_S3_SECRET_ACCESS_KEY}" ]; then
  echo "[backrest-pre-start] ⚠️  S3 credentials incomplete; Backrest will start but S3 repo may not be available" >&2
  echo "[backrest-pre-start] Set: BACKREST_S3_URI, BACKREST_S3_REPO_PASSWORD, BACKREST_S3_ACCESS_KEY_ID, BACKREST_S3_SECRET_ACCESS_KEY" >&2
fi

# Render template with sed
tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}" "${tmp_patch:-}"' EXIT INT TERM

sed \
  -e "s|__BACKREST_INSTANCE__|${BACKREST_INSTANCE}|g" \
  -e "s|__BACKREST_S3_URI__|${BACKREST_S3_URI}|g" \
  -e "s|__BACKREST_S3_REPO_PASSWORD__|${BACKREST_S3_REPO_PASSWORD}|g" \
  -e "s|__BACKREST_S3_ACCESS_KEY_ID__|${BACKREST_S3_ACCESS_KEY_ID}|g" \
  -e "s|__BACKREST_S3_SECRET_ACCESS_KEY__|${BACKREST_S3_SECRET_ACCESS_KEY}|g" \
  -e "s|__BACKREST_S3_REGION__|${BACKREST_S3_REGION}|g" \
  "${TEMPLATE_FILE}" > "${tmp_file}"

# Validate JSON
if ! jq empty "${tmp_file}" 2>/dev/null; then
  echo "[backrest-pre-start] ❌ generated config is not valid JSON" >&2
  exit 1
fi

mv "${tmp_file}" "${CONFIG_FILE}"
_fix_ownership "${CONFIG_DIR}"
echo "[backrest-pre-start] ✅ Backrest config initialized at ${CONFIG_FILE}"
