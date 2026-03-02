#!/bin/sh
set -eu

MODE="${1:-oneshot}"

CONFIG_FILE="${NEXTCLOUD_CONFIG_FILE:-/nextcloud-config/config.php}"
BACKUP_DIR="${NEXTCLOUD_SQL_BACKUP_DIR:-/nextcloud-config/backups}"
KEEP_COUNT="${NEXTCLOUD_SQL_BACKUP_KEEP:-30}"
STATE_FILE="${NEXTCLOUD_HOOK_STATE_FILE:-/tmp/nextcloud-maintenance.state}"

DB_HOST="${DB_HOST:-postgres}"
DB_NAME="${DB_NAME:-nextcloud}"
DB_USER="${DB_USER:-nextcloud}"
DB_PASSWORD="${DB_PASSWORD:-}"

if [ -z "${DB_PASSWORD}" ]; then
  echo "DB_PASSWORD is required" >&2
  exit 1
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Nextcloud config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

current_maintenance_state() {
  state="$(sed -n "s/.*'maintenance' => \(true\|false\).*/\1/p" "${CONFIG_FILE}" | head -n1 || true)"
  if [ -z "${state}" ]; then
    state="false"
  fi
  printf '%s' "${state}"
}

set_maintenance_state() {
  target_state="$1"

  if grep -Eq "'maintenance' => (true|false)" "${CONFIG_FILE}"; then
    sed -E -i "s/'maintenance' => (true|false)/'maintenance' => ${target_state}/" "${CONFIG_FILE}"
  else
    awk -v state="${target_state}" '
      /^\);[[:space:]]*$/ {
        print "  '\''maintenance'\'' => " state ","
      }
      { print }
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
  fi

  echo "Nextcloud maintenance mode set to ${target_state}"
}

run_db_backup() {
  timestamp="$(date +%Y%m%d_%H%M%S)"
  tmp_file="${BACKUP_DIR}/nextcloud-sqlbkp_${timestamp}.bak.tmp"
  out_file="${BACKUP_DIR}/nextcloud-sqlbkp_${timestamp}.bak"

  export PGPASSWORD="${DB_PASSWORD}"
  pg_dump -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -f "${tmp_file}"
  mv "${tmp_file}" "${out_file}"
  unset PGPASSWORD

  echo "Nextcloud PostgreSQL backup created: ${out_file}"

  if [ "${KEEP_COUNT}" -gt 0 ] 2>/dev/null; then
    old_backups="$(ls -1t "${BACKUP_DIR}"/nextcloud-sqlbkp_*.bak 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) || true)"
    if [ -n "${old_backups}" ]; then
      echo "Pruning old backups (keeping ${KEEP_COUNT})"
      echo "${old_backups}" | xargs -r rm -f
    fi
  fi
}

case "${MODE}" in
  pre)
    original_state="$(current_maintenance_state)"
    printf '%s' "${original_state}" > "${STATE_FILE}"
    set_maintenance_state true
    run_db_backup
    ;;
  post)
    if [ -f "${STATE_FILE}" ]; then
      restore_state="$(cat "${STATE_FILE}")"
      rm -f "${STATE_FILE}"
      if [ "${restore_state}" != "true" ] && [ "${restore_state}" != "false" ]; then
        restore_state="false"
      fi
      set_maintenance_state "${restore_state}"
    else
      set_maintenance_state false
    fi
    ;;
  oneshot)
    original_state="$(current_maintenance_state)"
    restore_original_state() {
      set_maintenance_state "${original_state}" || true
    }
    trap restore_original_state EXIT INT TERM

    set_maintenance_state true
    run_db_backup

    set_maintenance_state "${original_state}"
    trap - EXIT INT TERM
    ;;
  *)
    echo "Usage: $0 [pre|post|oneshot]" >&2
    exit 2
    ;;
esac
