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
# Usage: stack-up.sh [extra `docker compose up` arguments]
#   e.g. stack-up.sh --remove-orphans   (what the Makefile passes: an update
#   should drop containers the pull or a profile change removed, the way the
#   old down/up did)
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

# systemd hands us COMPOSE_PROFILES through EnvironmentFile=.env, falling back
# to its own Environment=all for installs whose .env predates per-service
# profiles. Run from make there is no such wrapper, so reproduce both rules
# here and export the result: compose reads it for the selection, and
# run-if-enabled.sh reads it to gate the per-service hooks. A defined-but-empty
# value is kept as-is — that means core-only, not "everything".
if [ -z "${COMPOSE_PROFILES+x}" ]; then
    if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
        COMPOSE_PROFILES="$(get_env_value COMPOSE_PROFILES)"
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

        if [ ! -f "$SCRIPT_DIR/$_script" ]; then
            hook_problem "$_script is missing"
            continue
        fi

        if [ -n "$_service" ]; then
            run_hook /bin/sh "$SCRIPT_DIR/run-if-enabled.sh" "$_service" \
                /bin/sh "$SCRIPT_DIR/$_script"
        else
            run_hook /bin/sh "$SCRIPT_DIR/$_script"
        fi
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

# --- Run ---

log "Preparing configuration..."
run_hooks blocking "$PRE_START_HOOKS"

log "Starting containers (only what changed is recreated)..."
(cd "$PROJECT_DIR" && docker compose up -d "$@")

log "Running bootstraps..."
run_hooks tolerant "$POST_START_HOOKS"

log "Stack is up"
