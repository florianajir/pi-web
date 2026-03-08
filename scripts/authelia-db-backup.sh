#!/bin/sh
# Dump the Authelia PostgreSQL database for Backrest backup.
# Mirrors nextcloud-db-backup.sh but for the authelia database.
set -eu

BACKUP_DIR="${AUTHELIA_SQL_BACKUP_DIR:-/userdata/authelia-config/backups}"
KEEP_COUNT="${AUTHELIA_SQL_BACKUP_KEEP:-7}"

DB_HOST="${DB_HOST:-postgres}"
DB_NAME="${AUTHELIA_DB_NAME:-authelia}"
DB_USER="${AUTHELIA_DB_USER:-authelia}"
DB_PASSWORD="${AUTHELIA_DB_PASSWORD:-}"

if [ -z "${DB_PASSWORD}" ]; then
    echo "AUTHELIA_DB_PASSWORD is required" >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

timestamp="$(date +%Y%m%d_%H%M%S)"
tmp_file="${BACKUP_DIR}/authelia-sqlbkp_${timestamp}.bak.tmp"
out_file="${BACKUP_DIR}/authelia-sqlbkp_${timestamp}.bak"

export PGPASSWORD="${DB_PASSWORD}"
pg_dump -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -f "${tmp_file}"
mv "${tmp_file}" "${out_file}"
unset PGPASSWORD

echo "Authelia PostgreSQL backup created: ${out_file}"

case "${KEEP_COUNT}" in
    ''|*[!0-9]*) KEEP_COUNT=7 ;;
esac

if [ "${KEEP_COUNT}" -gt 0 ]; then
    old_backups="$(ls -1t "${BACKUP_DIR}"/authelia-sqlbkp_*.bak 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) || true)"
    if [ -n "${old_backups}" ]; then
        echo "Pruning old Authelia backups (keeping ${KEEP_COUNT})"
        echo "${old_backups}" | xargs -r rm -f
    fi
fi
