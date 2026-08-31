#!/bin/sh
# Bring the immich database's extensions up to the versions the running
# postgres image ships. A post-start hook (scripts/stack-up.sh). Idempotent.
#
# Exists because the immich role is deliberately not a superuser (it shares
# this Postgres with the vaultwarden, authelia and lldap databases — see
# config/postgres/init-databases.sh): immich-server's bootstrap aborts when it
# sees a newer vchord available but cannot run ALTER EXTENSION itself. Running
# the update here as postgres, before immich-server's first health-checked
# start completes, keeps image bumps hands-off.

set -eu

. "$(dirname "$0")/lib.sh"

PG_CONTAINER="${PG_CONTAINER:-pi-postgres}"

if ! container_is_running "$PG_CONTAINER"; then
    log "$PG_CONTAINER is not running, skipping extension updates"
    exit 0
fi

# \gexec runs the generated ALTER for every installed-but-outdated extension
# and is a no-op otherwise. quote_ident guards the identifier.
updated=$(docker exec -i "$PG_CONTAINER" psql -U postgres -d immich -v ON_ERROR_STOP=1 -At << 'EOF'
SELECT format('ALTER EXTENSION %I UPDATE', name)
FROM pg_available_extensions
WHERE installed_version IS NOT NULL
  AND installed_version IS DISTINCT FROM default_version
\gexec
SELECT count(*) FROM pg_available_extensions
WHERE installed_version IS NOT NULL
  AND installed_version IS DISTINCT FROM default_version;
EOF
)

# The ALTERs' command tags precede the count; only the last line matters.
remaining=$(printf '%s' "$updated" | tail -n1)
if [ "$remaining" = "0" ]; then
    log "immich extensions are current"
else
    log "WARNING: $remaining immich extension(s) still outdated after the update pass"
fi
