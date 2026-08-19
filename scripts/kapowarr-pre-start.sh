#!/bin/sh
# Pre-start: ensure Kapowarr's data directories exist with the right ownership.
# The image entrypoint chowns /app/db and /app/temp_downloads to PUID:PGID, but NOT
# the /comics library root. Docker would otherwise create /comics as root:root and
# Kapowarr (PUID 1000) could not write imported comics into it. Create it up front
# and hand it (plus the config dirs) to the project owner. Idempotent.
# Runs as ExecStartPre before docker compose up.

set -eu

. "$(dirname "$0")/lib.sh"

main() {
    local data_location

    data_location="$(resolve_data_location_path)"

    mkdir -p \
        "$data_location/comics" \
        "$data_location/kapowarr/db" \
        "$data_location/kapowarr/downloads"

    fix_ownership "$data_location/comics"
    fix_ownership "$data_location/kapowarr"

    log "Ensured Kapowarr data directories"
}

main "$@"
