#!/bin/sh
# Dump the LLDAP PostgreSQL database for Backrest backup.
# Mirrors authelia-db-backup.sh but for the lldap database.
set -eu

BACKUP_DIR="${LLDAP_SQL_BACKUP_DIR:-/userdata/lldap/backups}"
KEEP_COUNT="${LLDAP_SQL_BACKUP_KEEP:-7}"

DB_HOST="${DB_HOST:-postgres}"
DB_NAME="${LLDAP_DB_NAME:-lldap}"
DB_USER="${LLDAP_DB_USER:-lldap}"
DB_PASSWORD="${LLDAP_DB_PASSWORD:-}"

if [ -z "${DB_PASSWORD}" ]; then
    echo "LLDAP_DB_PASSWORD is required" >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

timestamp="$(date +%Y%m%d_%H%M%S)"
tmp_file="${BACKUP_DIR}/lldap-sqlbkp_${timestamp}.bak.tmp"
out_file="${BACKUP_DIR}/lldap-sqlbkp_${timestamp}.bak"

export PGPASSWORD="${DB_PASSWORD}"
pg_dump -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -f "${tmp_file}"
mv "${tmp_file}" "${out_file}"
unset PGPASSWORD

echo "LLDAP PostgreSQL backup created: ${out_file}"

case "${KEEP_COUNT}" in
    ''|*[!0-9]*) KEEP_COUNT=7 ;;
esac

if [ "${KEEP_COUNT}" -gt 0 ]; then
    old_backups="$(ls -1t "${BACKUP_DIR}"/lldap-sqlbkp_*.bak 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) || true)"
    if [ -n "${old_backups}" ]; then
        echo "Pruning old LLDAP backups (keeping ${KEEP_COUNT})"
        echo "${old_backups}" | xargs -r rm -f
    fi
fi
