#!/bin/sh
# Migrate the shared Postgres cluster to a new major version, by dump/restore.
#
# Usage: pg-major-upgrade.sh --to <image> [--apply] [--keep-dumps]
#   --to <image>   target image, e.g.
#                  ghcr.io/immich-app/postgres:18-vectorchord1.1.1@sha256:...
#   --apply        rewrite compose.yaml's postgres image and data mount on
#                  success (otherwise the two edits are printed for review)
#   --keep-dumps   do not delete the dump directory afterwards
#
# Why dump/restore rather than pg_upgrade: the immich-app/postgres image ships
# exactly one major's binaries, so pg_upgrade (which needs both) would require
# a custom image carrying two Postgres builds plus VectorChord. A dump/restore
# also rebuilds the vchord indexes at the new extension version, which is what
# Immich's docs otherwise ask you to do by hand after any vchord change.
#
# The old data directory is never touched: the new major initialises a fresh
# one, so rollback is reverting the two compose lines. From Postgres 18 the
# upstream image stores data under /var/lib/postgresql/<major>/docker instead
# of /var/lib/postgresql/data and refuses to start with anything mounted at
# the latter, so the mount point moves with the version.

set -eu

. "$(dirname "$0")/lib.sh"

PG_CONTAINER="${PG_CONTAINER:-pi-postgres}"
TARGET_IMAGE=""
APPLY=0
KEEP_DUMPS=0

# Every database in the cluster, and the role that owns it (same name here).
DATABASES="immich nextcloud authelia lldap open-webui vaultwarden"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --to) TARGET_IMAGE="${2:-}"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --keep-dumps) KEEP_DUMPS=1; shift ;;
        *) die "unknown argument: $1 (see the header for usage)" ;;
    esac
done

[ -n "$TARGET_IMAGE" ] || die "--to <image> is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

major_of() {
    # 18 out of ".../postgres:18-vectorchord1.1.1@sha256:..."
    printf '%s' "$1" | sed -n 's|.*:\([0-9][0-9]*\)[-@].*|\1|p;s|.*:\([0-9][0-9]*\)$|\1|p' | head -n1
}

TARGET_MAJOR="$(major_of "$TARGET_IMAGE")"
[ -n "$TARGET_MAJOR" ] || die "could not read a major version out of '$TARGET_IMAGE'"

container_is_running "$PG_CONTAINER" \
    || die "$PG_CONTAINER is not running; the dump has to come from the live cluster"

CURRENT_MAJOR="$(docker exec "$PG_CONTAINER" psql -U postgres -Atc 'SHOW server_version;' | cut -d. -f1)"
log "cluster is on Postgres $CURRENT_MAJOR, target is $TARGET_MAJOR"
[ "$CURRENT_MAJOR" != "$TARGET_MAJOR" ] || { log "already on $TARGET_MAJOR, nothing to do"; exit 0; }
[ "$TARGET_MAJOR" -gt "$CURRENT_MAJOR" ] || die "refusing to move backwards ($CURRENT_MAJOR -> $TARGET_MAJOR)"

DATA_LOCATION="$(resolve_data_location_path)"
OLD_DIR="$DATA_LOCATION/postgres"
NEW_DIR="$DATA_LOCATION/postgres$TARGET_MAJOR"
DUMP_DIR="$DATA_LOCATION/postgres-upgrade-$CURRENT_MAJOR-to-$TARGET_MAJOR"

[ ! -d "$NEW_DIR" ] || die "$NEW_DIR already exists; move it aside or finish the previous attempt"

PASSWORD="$(get_env_value PASSWORD)"
[ -n "$PASSWORD" ] || die "PASSWORD is not set in .env"

# Space: the dumps are roughly the cluster size, and the new cluster another
# copy, so ask for 3x before starting.
cluster_kb="$(docker exec "$PG_CONTAINER" psql -U postgres -Atc \
    "SELECT ceil(sum(pg_database_size(datname))/1024) FROM pg_database WHERE NOT datistemplate;")"
free_kb="$(df -Pk "$DATA_LOCATION" | awk 'NR==2 {print $4}')"
need_kb=$((cluster_kb * 3))
log "cluster $((cluster_kb / 1024))MB, free $((free_kb / 1024))MB, want $((need_kb / 1024))MB"
[ "$free_kb" -gt "$need_kb" ] || die "not enough free space at $DATA_LOCATION"

log "pulling $TARGET_IMAGE"
docker pull -q "$TARGET_IMAGE" >/dev/null || die "could not pull $TARGET_IMAGE"

mkdir -p "$DUMP_DIR"
safe_chmod 700 "$DUMP_DIR"

# --- Dump, from the live cluster -----------------------------------------
log "dumping roles"
docker exec "$PG_CONTAINER" pg_dumpall -U postgres --roles-only > "$DUMP_DIR/roles.sql"
[ -s "$DUMP_DIR/roles.sql" ] || die "role dump is empty"

for db in $DATABASES; do
    log "dumping $db"
    docker exec -e PGPASSWORD="$PASSWORD" "$PG_CONTAINER" \
        pg_dump -U "$db" -d "$db" > "$DUMP_DIR/$db.sql" \
        || die "pg_dump of $db failed"
    [ -s "$DUMP_DIR/$db.sql" ] || die "dump of $db is empty"
done

# Row counts to compare after the restore. The largest table per database is
# enough of a canary and costs one query each.
log "recording row counts"
: > "$DUMP_DIR/counts.before"
for db in $DATABASES; do
    docker exec "$PG_CONTAINER" psql -U postgres -d "$db" -Atc "
        SELECT '$db|' || relname || '|' || n_live_tup
        FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5;
    " >> "$DUMP_DIR/counts.before"
done
log "$(wc -l < "$DUMP_DIR/counts.before") counters recorded"

# --- Swap ----------------------------------------------------------------
log "stopping the stack"
compose down --remove-orphans >/dev/null 2>&1 || true

log "starting Postgres $TARGET_MAJOR on $NEW_DIR"
mkdir -p "$NEW_DIR"
docker rm -f pg-upgrade-target >/dev/null 2>&1 || true
docker run -d --name pg-upgrade-target \
    -e POSTGRES_PASSWORD="$PASSWORD" \
    -e POSTGRES_INITDB_ARGS=--data-checksums \
    -v "$NEW_DIR:/var/lib/postgresql" \
    --shm-size 256mb "$TARGET_IMAGE" >/dev/null

cleanup_target() { docker rm -f pg-upgrade-target >/dev/null 2>&1 || true; }
trap cleanup_target EXIT INT TERM

wait_for_cmd 60 2 docker exec pg-upgrade-target pg_isready -U postgres \
    || die "Postgres $TARGET_MAJOR did not come up; see: docker logs pg-upgrade-target"

target_psql() { docker exec -i pg-upgrade-target psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }

# --- Restore -------------------------------------------------------------
# The bootstrap superuser already exists in a fresh cluster, and its CREATE
# ROLE line would abort the script under ON_ERROR_STOP, silently skipping
# every role sorted after it.
log "restoring roles"
grep -vE '^(CREATE|ALTER) ROLE postgres[; ]' "$DUMP_DIR/roles.sql" | target_psql \
    || die "role restore failed"

for db in $DATABASES; do
    log "restoring $db"
    target_psql -c "CREATE DATABASE \"$db\" OWNER \"$db\";" || die "could not create $db"
    docker exec -i pg-upgrade-target psql -U postgres -d "$db" -q -v ON_ERROR_STOP=1 \
        < "$DUMP_DIR/$db.sql" || die "restore of $db failed"
done

# pgvecto.rs is gone from the 18+ images; the immich database carries it in a
# per-database search_path that would now point at a missing schema.
docker exec pg-upgrade-target psql -U postgres -q \
    -c "ALTER DATABASE immich RESET search_path;" >/dev/null 2>&1 || true

# --- Verify --------------------------------------------------------------
log "verifying row counts"
docker exec pg-upgrade-target psql -U postgres -q -c 'ANALYZE;' >/dev/null 2>&1 || true
: > "$DUMP_DIR/counts.after"
for db in $DATABASES; do
    docker exec pg-upgrade-target psql -U postgres -d "$db" -Atc "
        SELECT '$db|' || relname || '|' || n_live_tup
        FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5;
    " >> "$DUMP_DIR/counts.after"
done

mismatch=0
while IFS='|' read -r db tbl before; do
    [ -n "${tbl:-}" ] || continue
    after="$(awk -F'|' -v d="$db" -v t="$tbl" '$1==d && $2==t {print $3}' "$DUMP_DIR/counts.after")"
    if [ -z "$after" ]; then
        log "MISMATCH $db.$tbl: $before rows before, table absent after"
        mismatch=1
    elif [ "$after" != "$before" ]; then
        log "MISMATCH $db.$tbl: $before -> $after"
        mismatch=1
    fi
done < "$DUMP_DIR/counts.before"

if [ "$mismatch" != "0" ]; then
    die "row counts differ; $NEW_DIR is suspect. The old cluster at $OLD_DIR is untouched: leave compose.yaml as it is and 'make start' to roll back."
fi
log "row counts match across all $(printf '%s' "$DATABASES" | wc -w) databases"

docker stop pg-upgrade-target >/dev/null
cleanup_target
trap - EXIT INT TERM

# --- Compose ------------------------------------------------------------
old_image_line="$(grep -n 'image: ghcr.io/immich-app/postgres:' compose.yaml | head -n1)"
[ -n "$old_image_line" ] || die "could not find the postgres image line in compose.yaml"

if [ "$APPLY" = "1" ]; then
    log "rewriting compose.yaml"
    sed -i \
        -e "s|image: ghcr.io/immich-app/postgres:.*|image: $(sed_escape "$TARGET_IMAGE")|" \
        -e "s|\(\${DATA_LOCATION:-./data}/postgres\)[0-9]*:/var/lib/postgresql\(/data\)\{0,1\}|\1$TARGET_MAJOR:/var/lib/postgresql|" \
        compose.yaml
    git --no-pager diff --stat compose.yaml 2>/dev/null || true
    log "compose.yaml updated; run 'make start' to bring the stack up on Postgres $TARGET_MAJOR"
else
    cat <<EOF

Data is migrated. Two edits remain in compose.yaml (postgres service):

  image: $TARGET_IMAGE
  volumes:
    - \${DATA_LOCATION:-./data}/postgres$TARGET_MAJOR:/var/lib/postgresql

Then: make start
Re-run with --apply to have this script make both edits.
EOF
fi

cat <<EOF

Also update, in the same change:
  config/backrest/Dockerfile   postgresql${CURRENT_MAJOR}-client -> postgresql${TARGET_MAJOR}-client
                               (a newer client emits SET parameters an older
                               server rejects, and vice versa: db-backup.sh's
                               dumps must restore into this server)
  compose.test.yaml            postgres_ci_data:/var/lib/postgresql

Rollback: revert those edits and 'make start'. The Postgres $CURRENT_MAJOR
cluster at $OLD_DIR was never modified.
EOF

if [ "$KEEP_DUMPS" = "1" ]; then
    log "dumps kept at $DUMP_DIR"
else
    log "removing $DUMP_DIR (pass --keep-dumps to retain it)"
    rm -rf "$DUMP_DIR"
fi

log "Postgres $CURRENT_MAJOR -> $TARGET_MAJOR migration complete"
