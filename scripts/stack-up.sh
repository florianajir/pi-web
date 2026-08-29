#!/bin/sh
# Bring the stack to the state the repository describes: the pre-start hooks,
# `docker compose up -d`, then the post-start bootstraps.
#
# The single source of truth for that sequence. pi-pcloud.service calls it as
# its ExecStart, and so do `make update` / `make update-images` — which is the
# point: an update can re-run exactly what boot runs *without stopping
# anything first*, and the hook list cannot drift between the unit and the
# Makefile. Compose then recreates only the containers whose image or
# configuration actually moved; everything else keeps running.
#
# Takes no arguments: everything it does must be identical whether systemd or
# the Makefile calls it, so nothing here is left for the caller to pass — or to
# forget.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || die "takes no arguments (got: $*)"

# systemd hands us COMPOSE_PROFILES through EnvironmentFile=.env, falling back
# to its own Environment=all for installs whose .env predates per-service
# profiles. Run from make there is no such wrapper, so reproduce both rules
# here and export the result: compose reads it for the selection, and
# run-if-enabled.sh reads it to gate the per-service hooks. A defined-but-empty
# value is kept as-is — that means core-only, not "everything".
if [ -z "${COMPOSE_PROFILES+x}" ]; then
    if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
        # get_env_value reads the file verbatim, so it hands back the quotes
        # and any CRLF that Compose, systemd's EnvironmentFile= and
        # run-if-enabled.sh all strip. Left in, `"stremio"` would match no
        # profile at all — and --remove-orphans below would then delete every
        # optional container as an orphan.
        COMPOSE_PROFILES="$(get_env_value COMPOSE_PROFILES | tr -d '\r')"
        case "$COMPOSE_PROFILES" in
            \"*\") COMPOSE_PROFILES="${COMPOSE_PROFILES#\"}"; COMPOSE_PROFILES="${COMPOSE_PROFILES%\"}" ;;
            \'*\') COMPOSE_PROFILES="${COMPOSE_PROFILES#\'}"; COMPOSE_PROFILES="${COMPOSE_PROFILES%\'}" ;;
        esac
    else
        COMPOSE_PROFILES=all
    fi
    export COMPOSE_PROFILES
fi

# --- The sequence ---
#
# An entry is "script.sh", or "service:script.sh" for a hook that belongs to an
# optional service — the latter goes through run-if-enabled.sh, so it is
# skipped when COMPOSE_PROFILES does not select that service.

# Rendered configuration and generated secrets. Blocking, like an ExecStartPre
# without a `-`: nothing should start against a half-written configuration.
PRE_START_HOOKS='
authelia-pre-start.sh
headscale-pre-start.sh
backrest-pre-start.sh
ntfy-pre-start.sh
vaultwarden:vaultwarden-pre-start.sh
qbittorrent:qbittorrent-pre-start.sh
prowlarr:prowlarr-pre-start.sh
kapowarr:kapowarr-pre-start.sh
llama-cpp:llama-cpp-pre-start.sh
'

# Bootstraps that need their service answering. Best-effort, like the unit's
# `-` prefix: a service slow to come up must not fail the whole start, and
# every one of them is idempotent, so the next run picks up what was missed.
POST_START_HOOKS='
headscale-init.sh
beszel-agent:beszel-agent-bootstrap.sh
dockhand:dockhand-oidc-bootstrap.sh
nextcloud:nextcloud-oidc-bootstrap.sh
pihole-bootstrap.sh
qbittorrent:qbittorrent-bootstrap.sh
prowlarr:prowlarr-bootstrap.sh
kapowarr:kapowarr-bootstrap.sh
uptime-kuma:uptime-kuma-bootstrap.sh
kavita:kavita-oidc-bootstrap.sh
open-webui:open-webui-bootstrap.sh
homepage-widgets-bootstrap.sh
'

# run_hooks <blocking|tolerant> <list>
run_hooks() {
    _mode="$1"
    _list="$2"

    # Word splitting on the list is the parse; no entry contains whitespace.
    # shellcheck disable=SC2086
    for _entry in $_list; do
        _service=""
        _script="$_entry"
        case "$_entry" in
            *:*)
                _service="${_entry%%:*}"
                _script="${_entry#*:}"
                ;;
        esac

        # The gate comes first, and decides on its own (run-if-enabled.sh in
        # test mode) rather than by wrapping the call. A disabled service is
        # then skipped without its script being looked at, which is what the
        # unit's `run-if-enabled.sh <svc> <cmd>` lines did: they returned 0
        # long before anything could notice the script was missing.
        if [ -n "$_service" ] && ! /bin/sh "$SCRIPT_DIR/run-if-enabled.sh" "$_service"; then
            log "$_script skipped ($_service disabled)"
            continue
        fi

        if [ ! -f "$SCRIPT_DIR/$_script" ]; then
            hook_problem "$_script is missing"
            continue
        fi

        run_hook /bin/sh "$SCRIPT_DIR/$_script"
    done
}

# Both apply the mode of the enclosing run_hooks call — the `-` prefix the
# unit's Exec* lines used to carry, now carried by which list a hook is in.
hook_problem() {
    [ "$_mode" = tolerant ] || die "$1"
    log "warning: $1 (continuing)"
}

run_hook() {
    "$@" || hook_problem "$_script failed"
}

# `up -d` recreates only the containers whose image or configuration moved,
# which is what makes running this on a live stack cheap. It refuses, though,
# when a network or volume *definition* changed: compose can only apply that by
# removing the object, and that means taking the stack down first. Rare — an
# upstream subnet or driver option moving — but without this an update would
# abort right here, with the new images pulled and the host files already
# applied, leaving every container on the old ones.
start_containers() {
    _out="$(mktemp)"
    _rc="$(mktemp)"
    # shellcheck disable=SC2064 # expand the paths now, not at trap time
    trap "rm -f '$_out' '$_rc'" EXIT INT TERM

    # dash has no pipefail and the pipeline's status is tee's, so carry
    # compose's own out through a file. tee keeps its progress on screen.
    # `|| _status=$?` is also what keeps set -e from killing the subshell
    # before the status is written.
    {
        _status=0
        compose up -d --remove-orphans 2>&1 || _status=$?
        echo "$_status" >"$_rc"
    } | tee "$_out"

    if [ "$(cat "$_rc")" = 0 ]; then
        return 0
    fi

    case "$(cat "$_out")" in
        *"has incorrect"* | *"needs to be recreated"*) ;;
        *) die "docker compose up failed" ;;
    esac

    log "A network or volume definition changed; that one needs the stack down"
    compose down --remove-orphans
    compose up -d --remove-orphans
}

# --- Run ---

log "Preparing configuration..."
run_hooks blocking "$PRE_START_HOOKS"

log "Starting containers (only what changed is recreated)..."
start_containers

log "Running bootstraps..."
run_hooks tolerant "$POST_START_HOOKS"

log "Stack is up"
